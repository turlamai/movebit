#lang racket/base

;; The core state machine, an exact port of Services/ReminderScheduler.cs.
;; Three independent reminder cycles advance on Tick:
;;   - sit cycle: accumulates ACTIVE time only, fires "stand up" reminders
;;   - water cycle: same accumulation (only meaningful while at the desk)
;;   - micro cycle: lightweight short-break nudges when enabled
;; When the user goes idle beyond the away threshold, all cycles freeze; when
;; they come back the cycles reset — the break already happened, no nagging
;; after it. Continuous-session time is tracked separately and resets after a
;; real away break, a self-reported stand-up (acknowledged sit cue), pause,
;; or day rollover.
;;
;; Clocks are integer milliseconds; the `now` thunk is injected so tests drive
;; a virtual clock. The idle provider returns idle SECONDS or #f (#f means
;; "cannot know" and is treated as active — never invent idle time).

(require "config.rkt"
         "history.rkt"
         "timeutil.rkt")

(provide (struct-out day-stats)
        (struct-out movebit-scheduler)
         make-scheduler
         scheduler-config
         set-scheduler-config!
         scheduler-tick!
         scheduler-pause-for!
         scheduler-resume!
         scheduler-end-session!
         scheduler-snooze!
         scheduler-restore-today!
         scheduler-stats
         scheduler-sit-cycle-elapsed-ms
         scheduler-current-session-active-time-ms
         scheduler-paused?
         scheduler-paused-until-ms
         max-tick-delta-ms)

;; Raise on the away -> active transition (user just sat back down).
;; Callbacks are optional and invoked synchronously inside the tick.
(struct movebit-scheduler
  (config-box           ; box of reminder-config, live-mutable
   now                  ; (-> integer-ms)
   idle                 ; (-> (or/c real? #f)) idle seconds or #f
   last-tick-ms
   was-away
   sit-accum-ms
   water-accum-ms
   micro-accum-ms
   session-accum-ms
   paused-until-ms      ; #f or integer-ms
   stats                ; day-stats (immutable, replaced on day roll)
   restored-for         ; #f or date key (RestoreToday idempotence)
   on-reminder          ; #f or (kind count-today active-ms) -> any
   on-user-returned     ; #f or (-> any)
   on-day-completed)    ; #f or (day-stats) -> any  (archive hook, fires BEFORE reset)
  #:transparent
  #:mutable)

(struct day-stats
  (date-key              ; "yyyy-MM-dd"
   active-ms
   longest-session-ms
   sit-reminders
   water-reminders
   micro-breaks)
  #:transparent)

(define (fresh-stats key)
  (day-stats key 0 0 0 0 0))

(define max-tick-delta-ms (* 10 60 1000)) ; system sleep / VM suspend clamp

(define minute-ms 60000)

(define (make-scheduler config now idle
                        #:on-reminder [on-reminder #f]
                        #:on-user-returned [on-user-returned #f]
                        #:on-day-completed [on-day-completed #f])
  (movebit-scheduler (box config)
                     now
                     idle
                     (now)
                     #f
                     0 0 0 0
                     #f
                     (fresh-stats (ms->date-key (now)))
                     #f
                     on-reminder
                     on-user-returned
                     on-day-completed))

(define (scheduler-config s) (unbox (movebit-scheduler-config-box s)))

(define (set-scheduler-config! s config)
  (set-box! (movebit-scheduler-config-box s) (clamp-config config)))

(define (interval-ms minutes) (* minutes minute-ms))

(define (sit-interval s) (interval-ms (reminder-config-sit-reminder-minutes (scheduler-config s))))
(define (water-interval s) (interval-ms (reminder-config-water-reminder-minutes (scheduler-config s))))
(define (micro-interval s) (interval-ms (reminder-config-micro-break-interval-minutes (scheduler-config s))))
(define (away-threshold-seconds s)
  (* 60 (reminder-config-away-reset-minutes (scheduler-config s))))

(define (scheduler-stats s) (movebit-scheduler-stats s))

;; Active time accumulated in the current sit cycle (UI progress display).
(define (scheduler-sit-cycle-elapsed-ms s)
  (max 0 (movebit-scheduler-sit-accum-ms s)))

;; Continuous active work since the last real break/pause/day boundary.
(define (scheduler-current-session-active-time-ms s)
  (max 0 (movebit-scheduler-session-accum-ms s)))

(define (scheduler-paused? s)
  (define until (movebit-scheduler-paused-until-ms s))
  (and until (< ((movebit-scheduler-now s)) until)))

(define (scheduler-paused-until-ms s)
  (and (scheduler-paused? s) (movebit-scheduler-paused-until-ms s)))

;; Fire a reminder callback if one is installed.
(define (fire-reminder! s kind count active-ms)
  (define cb (movebit-scheduler-on-reminder s))
  (when cb (cb kind count active-ms)))

(define (fire-user-returned! s)
  (define cb (movebit-scheduler-on-user-returned s))
  (when cb (cb)))

(define (fire-day-completed! s stats)
  (define cb (movebit-scheduler-on-day-completed s))
  (when cb (cb stats)))

(define (reset-cycles! s)
  (set-movebit-scheduler-sit-accum-ms! s 0)
  (set-movebit-scheduler-water-accum-ms! s 0)
  (set-movebit-scheduler-micro-accum-ms! s 0))

(define (stats-add-active stats ms)
  (struct-copy day-stats stats [active-ms (+ (day-stats-active-ms stats) ms)]))

(define (stats-with-longest stats session-ms)
  (if (> session-ms (day-stats-longest-session-ms stats))
      (struct-copy day-stats stats [longest-session-ms session-ms])
      stats))

(define (stats-count+ stats field)
  (case field
    [(sit) (struct-copy day-stats stats
                        [sit-reminders (add1 (day-stats-sit-reminders stats))])]
    [(water) (struct-copy day-stats stats
                         [water-reminders (add1 (day-stats-water-reminders stats))])]
    [(micro) (struct-copy day-stats stats
                          [micro-breaks (add1 (day-stats-micro-breaks stats))])]))

(define (stats-count stats field)
  (case field
    [(sit) (day-stats-sit-reminders stats)]
    [(water) (day-stats-water-reminders stats)]
    [(micro) (day-stats-micro-breaks stats)]))

;; Archive hook before the daily reset (day-completed fires first).
(define (roll-day-if-needed! s now)
  (define today (ms->date-key now))
  (unless (string=? (day-stats-date-key (movebit-scheduler-stats s)) today)
    (fire-day-completed! s (movebit-scheduler-stats s))
    (set-movebit-scheduler-stats! s (fresh-stats today))
    (set-movebit-scheduler-session-accum-ms! s 0)))

;; Advance the state machine. The backend drives this from a 30 s tick thread.
(define (scheduler-tick! s)
  (define now ((movebit-scheduler-now s)))
  (roll-day-if-needed! s now)

  ;; Pause handling: while paused nothing accumulates. A pause may expire
  ;; between ticks — count only the portion after the exact deadline.
  (define paused-until (movebit-scheduler-paused-until-ms s))
  (when paused-until
    (cond [(< now paused-until)
           (set-movebit-scheduler-last-tick-ms! s now)
           (void)]
          [else
           (when (< (movebit-scheduler-last-tick-ms s) paused-until)
             (set-movebit-scheduler-last-tick-ms! s paused-until))
           (set-movebit-scheduler-paused-until-ms! s #f)]))

  (unless (movebit-scheduler-paused-until-ms s)
    (define raw-delta (- now (movebit-scheduler-last-tick-ms s)))
    (define delta
      (cond [(< raw-delta 0) 0]            ; clock stepped backwards
            [(> raw-delta max-tick-delta-ms) max-tick-delta-ms]
            [else raw-delta]))
    (set-movebit-scheduler-last-tick-ms! s now)

    (define idle ((movebit-scheduler-idle s)))
    (define away (and idle (>= idle (away-threshold-seconds s))))
    (cond
      [away
       (unless (movebit-scheduler-was-away s)
         ;; The continuous-work session ends as soon as a real away interval
         ;; is detected. Reminder cycles reset when the user returns.
         (set-movebit-scheduler-session-accum-ms! s 0))
       (set-movebit-scheduler-was-away! s #t)]
      [else
       (when (movebit-scheduler-was-away s)
         ;; Back from a real break: restart every cycle instead of dumping a
         ;; stale reminder.
         (set-movebit-scheduler-was-away! s #f)
         (reset-cycles! s)
         (fire-user-returned! s))
       (accumulate! s delta)]) )
  (void))

(define (accumulate! s delta)
  (define c (scheduler-config s))
  (define sit-on? (reminder-config-sit-enabled c))
  (define water-on? (reminder-config-water-enabled c))
  (define micro-on? (reminder-config-micro-break-enabled c))
  ;; A disabled kind neither advances nor fires: its cycle simply stays at
  ;; zero, so re-enabling it starts a fresh interval instead of dumping a
  ;; stale reminder.
  (when sit-on?
    (set-movebit-scheduler-sit-accum-ms! s (+ (movebit-scheduler-sit-accum-ms s) delta)))
  (when water-on?
    (set-movebit-scheduler-water-accum-ms! s (+ (movebit-scheduler-water-accum-ms s) delta)))
  (when micro-on?
    (set-movebit-scheduler-micro-accum-ms! s (+ (movebit-scheduler-micro-accum-ms s) delta)))
  (set-movebit-scheduler-session-accum-ms! s (+ (movebit-scheduler-session-accum-ms s) delta))

  (let* ([stats (stats-add-active (movebit-scheduler-stats s) delta)]
         [stats (stats-with-longest stats (movebit-scheduler-session-accum-ms s))])
    (set-movebit-scheduler-stats! s stats))

  (when (and sit-on? (>= (movebit-scheduler-sit-accum-ms s) (sit-interval s)))
    (set-movebit-scheduler-sit-accum-ms! s 0)
    (set-movebit-scheduler-stats! s (stats-count+ (movebit-scheduler-stats s) 'sit))
    (fire-reminder! s 'sit
                    (stats-count (movebit-scheduler-stats s) 'sit)
                    (day-stats-active-ms (movebit-scheduler-stats s))))

  (when (and water-on? (>= (movebit-scheduler-water-accum-ms s) (water-interval s)))
    (set-movebit-scheduler-water-accum-ms! s 0)
    (set-movebit-scheduler-stats! s (stats-count+ (movebit-scheduler-stats s) 'water))
    (fire-reminder! s 'water
                    (stats-count (movebit-scheduler-stats s) 'water)
                    (day-stats-active-ms (movebit-scheduler-stats s))))

  (when (and micro-on?
             (>= (movebit-scheduler-micro-accum-ms s) (micro-interval s)))
    (set-movebit-scheduler-micro-accum-ms! s 0)
    (set-movebit-scheduler-stats! s (stats-count+ (movebit-scheduler-stats s) 'micro))
    (fire-reminder! s 'micro
                    (stats-count (movebit-scheduler-stats s) 'micro)
                    (day-stats-active-ms (movebit-scheduler-stats s)))))

;; Silence reminders for the given duration ("pause 1 hour" tray action).
(define (scheduler-pause-for! s duration-ms)
  (define now ((movebit-scheduler-now s)))
  (set-movebit-scheduler-paused-until-ms! s (+ now duration-ms))
  (set-movebit-scheduler-last-tick-ms! s now)
  (set-movebit-scheduler-session-accum-ms! s 0))

(define (scheduler-resume! s)
  (set-movebit-scheduler-paused-until-ms! s #f)
  (set-movebit-scheduler-last-tick-ms! s ((movebit-scheduler-now s)))
  (set-movebit-scheduler-session-accum-ms! s 0))

;; A SELF-REPORTED stand-up (Done on a sit cue) ends the counted continuous
;; session, exactly like going away. Reminder cycles are NOT touched here:
;; they already restarted when the reminder fired, and Done on water or
;; micro claims hydration/eye-rest, not a desk break. This is the user's
;; report, never proof — stats still count fired reminders, not acknowledgments.
(define (scheduler-end-session! s)
  ;; A SELF-REPORTED stand-up (Done on a sit cue) ends the counted continuous
  ;; session, exactly like going away. Reminder cycles are NOT touched here:
  ;; they already restarted when the reminder fired, and Done on water or
  ;; micro claims hydration/eye-rest, not a desk break. This is the user's
  ;; report, never proof — stats still count fired reminders, not acknowledgments.
  (set-movebit-scheduler-session-accum-ms! s 0)
  (set-movebit-scheduler-last-tick-ms! s ((movebit-scheduler-now s))))

;; "Remind me later": NOT a timer delay — push the cycle accumulator to
;; (interval - snooze) so the reminder re-fires after `snooze` more minutes of
;; ACTIVE time. The accumulator may go negative when snooze exceeds the
;; interval; accessors clamp it back to zero.
(define (scheduler-snooze! s kind)
  (define config (scheduler-config s))
  (define snooze-ms (interval-ms (reminder-config-snooze-minutes config)))
  ;; A disabled kind has no live cycle to defer; leaving it at zero keeps a
  ;; later re-enable from firing early.
  (case kind
    [(sit) (when (reminder-config-sit-enabled config)
             (set-movebit-scheduler-sit-accum-ms! s (- (sit-interval s) snooze-ms)))]
    [(water) (when (reminder-config-water-enabled config)
               (set-movebit-scheduler-water-accum-ms! s (- (water-interval s) snooze-ms)))]
    [(micro) (when (reminder-config-micro-break-enabled config)
               (set-movebit-scheduler-micro-accum-ms! s (- (micro-interval s) snooze-ms)))]))

;; Carries a persisted same-day record into a fresh session so a mid-day
;; restart keeps the morning's activity (a fresh session would otherwise flush
;; session-only numbers over the persisted record). Idempotent per day and a
;; no-op once the day has rolled over. `record` may be #f.
(define (scheduler-restore-today! s record)
  (define today (ms->date-key ((movebit-scheduler-now s))))
  (define stats (movebit-scheduler-stats s))
  (when (and record
             (string=? (day-stats-date-key stats) today)
             (not (string=? today (or (movebit-scheduler-restored-for s) ""))))
    (set-movebit-scheduler-restored-for! s today)
    ;; Counters ADD onto the restored morning; LongestSession REPLACES, since
    ;; the persisted value is already the day's peak (port of RestoreToday).
    (set-movebit-scheduler-stats!
     s
     (day-stats (day-stats-date-key stats)
                (+ (day-stats-active-ms stats)
                   (* (max 0 (day-record-active-minutes record)) minute-ms))
                (* (max 0 (day-record-longest-session-minutes record)) minute-ms)
                (+ (day-stats-sit-reminders stats)
                   (max 0 (day-record-sit-breaks record)))
                (+ (day-stats-water-reminders stats)
                   (max 0 (day-record-water-reminders record)))
                (+ (day-stats-micro-breaks stats)
                   (max 0 (day-record-micro-breaks record)))))))
