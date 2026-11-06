#lang racket/base

;; MoveBit Rivet backend entry. Owns the 30-second tick thread, the scheduler
;; + orchestrator runtime, config/history persistence, and the typed RPC
;; surface the native hosts talk to. Hosts are thin shells: they render state
;; and forward user actions; all policy lives here.
;;
;; IMPORTANT (Rivet threading model): `current-event-emitter` lives on the
;; server reader thread. Threads spawned inside RPC handlers inherit it, but a
;; module-top-level thread (started before serve-fds) has NO emitter. The tick
;; thread is therefore started lazily from the `init` RPC — the host calls it
;; right after connecting, and the thread inherits the emitter from the
;; request worker. racket/tests/backend-server-test.rkt proves this at the
;; RVT1 protocol level.
;;
;; All time crosses the RPC boundary as Int64 epoch milliseconds (RVT1 has no
;; float); durations are Int64 milliseconds and stats are Int64 minutes.

(require rivet/backend
         json
         racket/bool
         racket/date
         racket/file
         racket/format
         racket/path
         racket/string
         "../racket/movebit/autostart.rkt"
         "../racket/movebit/companion-cue.rkt"
         "../racket/movebit/config.rkt"
         "../racket/movebit/history.rkt"
         "../racket/movebit/idle.rkt"
         "../racket/movebit/orchestrator.rkt"
         "../racket/movebit/paths.rkt"
         "../racket/movebit/scheduler.rkt"
         "../racket/movebit/timeutil.rkt"
         "../racket/movebit/update.rkt")

(provide start
         ;; test seams: parameters inherited by the tick thread when the host
         ;; (or a test server) parameterizes them around serve/serve-fds
         current-tick-interval-seconds
         current-now-ms
         current-idle-provider
         current-data-dir
         movebit-diagnostic-sink
         ;; RPC handlers, exported for the server-level tests
         initialize
         check-updates)

;; --- Injectable seams (defaults = the real world) ------------------------

(define current-tick-interval-seconds (make-parameter 30.0))
(define current-now-ms (make-parameter now-ms))
(define current-idle-provider
  (make-parameter
   (lambda ()
     (with-handlers ([exn:fail? (lambda (_) (make-null-idle-provider))])
       (make-platform-idle-provider)))))
(define current-data-dir (make-parameter (movebit-data-dir)))

;; --- Diagnostics: JSONL file, not stderr ----------------------------------
;;
;; Rivet's diagnostic sink defaults to current-error-port. A Windows
;; GUI-subsystem process has no console, and the embedded Chez runtime
;; lazily allocates one on the first stderr write — a black console window
;; streaming RVT1 protocol records. Diagnostics keep their value as JSONL
;; appended to <data-dir>/diagnostics.log instead (survives the process, so
;; a bug report can carry real backend records alongside the copyable
;; update-failure text); stderr is never touched, so no console is ever
;; allocated. Rivet already swallows sink exceptions, so an unwritable path
;; drops records rather than failing the backend. The data dir follows the
;; runtime's injectable parameter, so tests and custom data dirs agree.
(define diagnostics-port (box #f))
(define diagnostics-lock (make-semaphore 1))

(define (diagnostic-timestamp)
  ;; Local ISO-8601 (no zone suffix): machine-sortable, human-readable.
  (define d (seconds->date (current-seconds) #f))
  (format "~a-~a-~aT~a:~a:~a"
          (date-year d)
          (~r (date-month d) #:min-width 2 #:pad-string "0")
          (~r (date-day d) #:min-width 2 #:pad-string "0")
          (~r (date-hour d) #:min-width 2 #:pad-string "0")
          (~r (date-minute d) #:min-width 2 #:pad-string "0")
          (~r (date-second d) #:min-width 2 #:pad-string "0")))

(define (movebit-diagnostic-sink record)
  (call-with-semaphore
   diagnostics-lock
   (lambda ()
     (define out
       (or (unbox diagnostics-port)
           (let ([port
                  (begin
                    (with-handlers ([exn:fail? void])
                      (make-directory* (current-data-dir)))
                    (open-output-file (build-path (current-data-dir)
                                                  "diagnostics.log")
                                      #:exists 'append))])
             (set-box! diagnostics-port port)
             port)))
     (write-json (hash-set record 'ts (diagnostic-timestamp)) out)
     (newline out)
     (flush-output out))))

;; Module top level: runs on the boot thread that later invokes `start`, so
;; serve-fds picks this sink up as its default.
(current-rivet-diagnostic-sink movebit-diagnostic-sink)

;; --- Typed surface --------------------------------------------------------

(define-enum ReminderKind (sit water micro))

;; Semantic suggested health action of a cue, independent of appearance.
(define-enum CueAction (stand-and-stretch drink-water rest-eyes))
;; Presentation route the backend planned for the cue: the character surface,
;; a non-blocking system notification (unsupported/unsafe surface), or silent
;; queuing while Focus/presentation mode is active.
(define-enum CueDelivery (character notification quiet))

(define-record HealthCue
  ([id : Int64]
   [kinds : (List ReminderKind)]
   [action : CueAction]
   [delivery : CueDelivery]
   [animated : Bool]
   [due-at-ms : Int64]
   [expires-at-ms : Int64]))

(define-record ReminderConfig
  ([sit-reminder-minutes : Int64]
   [water-reminder-minutes : Int64]
   [away-reset-minutes : Int64]
   [snooze-minutes : Int64]
   [micro-break-enabled : Bool]
   [micro-break-interval-minutes : Int64]
   [micro-break-duration-seconds : Int64]
   [motion-enabled : Bool]
   [sound-enabled : Bool]
   [auto-check-updates : Bool]
   [welcome-shown : Bool]
   [language : String]
   [companion-size : String]
   [companion-motion : String]
   [companion-dock : String]
   [companion-labels : String]
   ;; Issue #87: named rhythm preset (the label always matches the values),
   ;; per-kind switches and a local quiet-hours window.
   [preset : String]
   [sit-enabled : Bool]
   [water-enabled : Bool]
   [quiet-hours-enabled : Bool]
   [quiet-hours-start-minutes : Int64]
   [quiet-hours-end-minutes : Int64]
   ;; Issue #104: normalized directly-placed home position (-1 = named dock).
   [companion-free-x : Int64]
   [companion-free-y : Int64]))

(define-record DayStats
  ([date : String]
   [active-mins : Int64]
   [sit-breaks : Int64]
   [water-reminders : Int64]
   [micro-breaks : Int64]
   [longest-session-mins : Int64]))

;; What actually happened to today's fired reminders, per kind (issue #88):
;; delivery and self-reported responses are kept apart from fired counts, and
;; nothing here claims a verified break. Fired counts stay in DayStats.
(define-record CueOutcomeTotals
  ([kind : ReminderKind]
   [presented : Int64]
   [self-reported-done : Int64]
   [snoozed : Int64]
   [dismissed : Int64]
   [expired : Int64]
   [not-delivered : Int64]))

(define-record PauseState
  ([paused : Bool]
   [until-ms : (Optional Int64)]))

(define-record LoopInfo
  ([kind : ReminderKind]
   [due-in-active-mins : (Optional Int64)]
   [accumulated-mins : Int64]))

;; Fired when the user acknowledges a cue claiming a sit break: hosts cheer
;; at milestone counts (3/5/8). The count is SELF-REPORTED acknowledgments,
;; never proof of actual breaks.
(define-record CueAcknowledged
  ([kind : ReminderKind]
   [count-today : Int64]))

(define-record RuntimeInfo
  ([data-dir : String]
   [device-id : String]
   [devices-today : (List String)]))

(define-record UpdateCheck
  ([status : String]
   [current-version : String]
   [available-version : (Optional String)]
   [build : (Optional Int64)]
   [size-bytes : (Optional Int64)]
   [error : (Optional String)]))

(define-record UpdateState
  ([phase : String]
   [percent : Int64]
   [message : (Optional String)]
   [available-version : (Optional String)]
   [downloaded-path : (Optional String)]))

;; --- Runtime wiring -------------------------------------------------------

(struct runtime (scheduler orchestrator history data-dir device-id idle-provider
                           outcomes-today quiet-hours-paused?)
  #:transparent
  #:mutable)

;; (box (or/c #f runtime?))
(define runtime-box (box #f))
;; (box (or/c #f thread?)) — the lazy 30 s tick thread, started by `init`.
(define tick-thread-box (box #f))
;; (box (or/c #f thread?)) — the auto-update-check thread, started by `init`.
(define auto-check-thread-box (box #f))

(define (require-runtime)
  (or (unbox runtime-box)
      (error 'movebit "backend is not initialized; call init first")))

(define minute-ms 60000)

(define (ms->mins ms)
  (quotient (max 0 ms) minute-ms))

(define (config->dto c)
  (ReminderConfig
   (reminder-config-sit-reminder-minutes c)
   (reminder-config-water-reminder-minutes c)
   (reminder-config-away-reset-minutes c)
   (reminder-config-snooze-minutes c)
   (reminder-config-micro-break-enabled c)
   (reminder-config-micro-break-interval-minutes c)
   (reminder-config-micro-break-duration-seconds c)
   (reminder-config-motion-enabled c)
   (reminder-config-sound-enabled c)
   (reminder-config-auto-check-updates c)
   (reminder-config-welcome-shown c)
   (reminder-config-language c)
   (reminder-config-companion-size c)
   (reminder-config-companion-motion c)
   (reminder-config-companion-dock c)
   (reminder-config-companion-labels c)
   (reminder-config-preset c)
   (reminder-config-sit-enabled c)
   (reminder-config-water-enabled c)
   (reminder-config-quiet-hours-enabled c)
   (reminder-config-quiet-hours-start-minutes c)
   (reminder-config-quiet-hours-end-minutes c)
   (reminder-config-companion-free-x c)
   (reminder-config-companion-free-y c)))

(define (dto->config dto)
  (clamp-config
   (reminder-config
    (record-ref dto 'sit-reminder-minutes)
    (record-ref dto 'water-reminder-minutes)
    (record-ref dto 'away-reset-minutes)
    (record-ref dto 'snooze-minutes)
    (record-ref dto 'micro-break-enabled)
    (record-ref dto 'micro-break-interval-minutes)
    (record-ref dto 'micro-break-duration-seconds)
    (record-ref dto 'motion-enabled)
    (record-ref dto 'sound-enabled)
    (record-ref dto 'auto-check-updates)
    (record-ref dto 'welcome-shown)
    (record-ref dto 'language)
    (record-ref dto 'companion-size)
    (record-ref dto 'companion-motion)
    (record-ref dto 'companion-dock)
    (record-ref dto 'companion-labels)
    (record-ref dto 'preset)
    (record-ref dto 'sit-enabled)
    (record-ref dto 'water-enabled)
    (record-ref dto 'quiet-hours-enabled)
    (record-ref dto 'quiet-hours-start-minutes)
    (record-ref dto 'quiet-hours-end-minutes)
    (record-ref dto 'companion-free-x)
    (record-ref dto 'companion-free-y))))

(define (stats->dto stats)
  (DayStats (day-stats-date-key stats)
            (ms->mins (day-stats-active-ms stats))
            (day-stats-sit-reminders stats)
            (day-stats-water-reminders stats)
            (day-stats-micro-breaks stats)
            (ms->mins (day-stats-longest-session-ms stats))))

(define (stats->record stats [outcomes (hasheq)])
  (day-record (ms->mins (day-stats-active-ms stats))
              (day-stats-sit-reminders stats)
              (day-stats-water-reminders stats)
              (day-stats-micro-breaks stats)
              (ms->mins (day-stats-longest-session-ms stats))
              outcomes))

;; Immutable snapshot of the runtime outcome accumulator (it mutates per
;; event; persistence and aggregation must see one stable value).
(define (outcomes-snapshot rt)
  (for/hasheq ([(kind per-kind) (in-hash (runtime-outcomes-today rt))])
    (values kind per-kind)))

(define (outcomes->dto outcomes)
  ;; Kind-sorted so the published list is deterministic across ticks.
  (for/list ([kind (in-list (sort (hash-keys outcomes) symbol<?))])
    (define per-kind (hash-ref outcomes kind (hasheq)))
    (CueOutcomeTotals (symbol->kind kind)
                      (hash-ref per-kind 'presented 0)
                      (hash-ref per-kind 'self-reported-done 0)
                      (hash-ref per-kind 'snoozed 0)
                      (hash-ref per-kind 'dismissed 0)
                      (hash-ref per-kind 'expired 0)
                      (hash-ref per-kind 'not-delivered 0))))

(define (publish-outcomes! rt)
  (state-set! cue-outcomes (outcomes->dto (outcomes-snapshot rt))))

(define (record->dto date-key r)
  (DayStats date-key
            (day-record-active-minutes r)
            (day-record-sit-breaks r)
            (day-record-water-reminders r)
            (day-record-micro-breaks r)
            (day-record-longest-session-minutes r)))

(define (kind->symbol kind) (enum-case kind))
(define (symbol->kind k) (ReminderKind k))

;; cue-record → wire DTO. The planned presentation travels WITH the cue so a
;; host that reconnects mid-lifecycle renders the same decision.
(define (cue->dto c)
  (define planned (cue-record-planned c))
  (HealthCue (cue-record-id c)
             (map symbol->kind (cue-record-kinds c))
             (CueAction (companion-cue-action planned))
             (CueDelivery (companion-cue-delivery planned))
             (and (companion-cue-animated? planned) #t)
             (cue-record-created-ms c)
             (+ (cue-record-created-ms c) cue-expiry-ms)))

;; --- States (kept in sync with the runtime; hosts sync via $state) --------
;; Defined after the conversion helpers; `init` publishes the real values.

(define-state today : DayStats
  (DayStats (ms->date-key (now-ms)) 0 0 0 0 0))
;; Named active-config: a state called `config` collides with the RPC
;; set-config in the native client generators (both normalize to setConfig).
(define-state active-config : ReminderConfig
  (config->dto (default-config)))
(define-state paused : PauseState
  (PauseState #f (void)))
(define-state loops : (List LoopInfo) '())
;; The cues currently on screen (pending or displayed): the reconciliation
;; view hosts read on launch and after any action.
(define-state pending-cues : (List HealthCue) '())
;; Per-kind cue lifecycle outcomes for today (issue #88): the honest history
;; counters behind the fired-reminder counts. Hosts may surface it; nothing
;; here implies a verified break.
(define-state cue-outcomes : (List CueOutcomeTotals) '())

;; --- Events ---------------------------------------------------------------

(define-event tick-stats : DayStats)
;; A due, merged reminder moment to show NOW (delivery ≠ quiet). The cue's
;; full lifecycle is visible through the pending-cues state.
(define-event health-cue : HealthCue)
(define-event day-completed : DayStats)
(define-event config-changed : ReminderConfig)
(define-event cue-acknowledged : CueAcknowledged)

;; --- State publishers -----------------------------------------------------

(define (loops->dto rt)
  (define scheduler (runtime-scheduler rt))
  (define c (scheduler-config scheduler))
  (define (loop-dto kind accum-ms interval-mins enabled?)
    (LoopInfo (symbol->kind kind)
              (if enabled?
                  (quotient (max 0 (- (* interval-mins minute-ms) accum-ms)) minute-ms)
                  (void))
              (quotient accum-ms minute-ms)))
  (list
   (loop-dto 'sit
             (movebit-scheduler-sit-accum-ms scheduler)
             (reminder-config-sit-reminder-minutes c)
             (reminder-config-sit-enabled c))
   (loop-dto 'water
             (movebit-scheduler-water-accum-ms scheduler)
             (reminder-config-water-reminder-minutes c)
             (reminder-config-water-enabled c))
   (loop-dto 'micro
             (movebit-scheduler-micro-accum-ms scheduler)
             (reminder-config-micro-break-interval-minutes c)
             (reminder-config-micro-break-enabled c))))

(define (publish-stats! rt)
  (define scheduler (runtime-scheduler rt))
  (define dto (record->dto (day-stats-date-key (scheduler-stats scheduler))
                           (aggregate-current! rt)))
  (state-set! today dto)
  (state-set! loops (loops->dto rt))
  (publish-outcomes! rt)
  (tick-stats dto))

;; The cross-device "today": every other device's synced shard plus this
;; machine's live in-memory counters (its own shard may lag by up to one
;; flush, so the in-memory stats always stand in for this device's entry).
;; Apple Screen Time semantics — additive counters sum, longest session maxes.
;; The refresh first picks up shards that arrived through the folder sync, so
;; another machine's minutes land in the totals within one 30 s tick.
(define (aggregate-current! rt)
  (define history (runtime-history rt))
  (define scheduler (runtime-scheduler rt))
  (define stats (scheduler-stats scheduler))
  (define date-key (day-stats-date-key stats))
  (history-refresh! history)
  (define per-device
    (hash-ref (history-store-days history) date-key #f))
  (define local-id (history-store-device-id history))
  (define others
    (for/list ([(device r) (in-hash (or per-device (hasheq)))]
               #:unless (string=? device local-id))
      r))
  (define local (stats->record stats (outcomes-snapshot rt)))
  (define base (aggregate-day-records others))
  (day-record (+ (day-record-active-minutes base)
                 (day-record-active-minutes local))
              (+ (day-record-sit-breaks base)
                 (day-record-sit-breaks local))
              (+ (day-record-water-reminders base)
                 (day-record-water-reminders local))
              (+ (day-record-micro-breaks base)
                 (day-record-micro-breaks local))
              (max (day-record-longest-session-minutes base)
                   (day-record-longest-session-minutes local))
              (cue-outcomes-sum (day-record-cue-outcomes base)
                                (day-record-cue-outcomes local))))

;; Quiet hours (issue #87) ride the scheduler's pause primitive: during the
;; local window nothing accumulates and nothing fires, and the pause expires
;; exactly on the window boundary. The flag distinguishes a quiet-hours pause
;; from the user's own "pause 1h" so we never resume a manual pause.
(define (apply-quiet-hours! rt)
  (define scheduler (runtime-scheduler rt))
  (define c (scheduler-config scheduler))
  (define now ((current-now-ms)))
  (cond
    [(quiet-hours-active? c now)
     (unless (or (runtime-quiet-hours-paused? rt)
                 (scheduler-paused? scheduler))
       (scheduler-pause-for! scheduler
                             (* 1000 (max 1 (quiet-hours-seconds-remaining c now))))
       (set-runtime-quiet-hours-paused?! rt #t)
       (publish-paused! rt))]
    [(runtime-quiet-hours-paused? rt)
     ;; Either the window ended (the pause expired on its own) or the user
     ;; just turned quiet hours off. Clear the marker so the next window can
     ;; pause again, and end a still-running quiet-hours pause immediately so
     ;; disabling the setting takes effect now rather than at the old boundary.
     (set-runtime-quiet-hours-paused?! rt #f)
     (when (scheduler-paused? scheduler)
       (scheduler-resume! scheduler))
     (publish-paused! rt)]))

(define (publish-paused! rt)
  (define until (scheduler-paused-until-ms (runtime-scheduler rt)))
  (state-set! paused
              (if until
                  (PauseState #t until)
                  (PauseState #f (void)))))

(define (publish-pending-cues! rt)
  (define o (runtime-orchestrator rt))
  (state-set! pending-cues (map cue->dto (orchestrator-open-cues o))))

;; Periodic flush (~every 5 minutes), exit flush, update-restart flush.
;; Best-effort end to end: a transient write failure (a second instance of
;; the same device racing the shard, a full disk) must not break the tick
;; loop or the host's shutdown path — the in-memory store stays usable and
;; the next flush retries.
(define (flush-today! rt)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (log-error 'movebit "history flush failed: ~a" e))])
    (define scheduler (runtime-scheduler rt))
    (define stats (scheduler-stats scheduler))
    (history-save-day! (runtime-history rt)
                       (day-stats-date-key stats)
                       (stats->record stats (outcomes-snapshot rt))
                       (day-stats-date-key stats))))

;; --- Init -----------------------------------------------------------------

(define-rpc (initialize : Void)
  (unless (unbox runtime-box)
    ;; One-time, idempotent rename of the retired-owner LaunchAgent (issue
    ;; #128). Best-effort: a failed migration must never block startup.
    (migrate-launch-agent!)
    (define data-dir (current-data-dir))
    (define device-id (ensure-device-id))
    (define loaded-config (load-config data-dir))
    (define idle ((current-idle-provider)))
    (define history (make-history-store data-dir device-id))
    (history-load! history)
    (define scheduler
      (make-scheduler loaded-config
                       (current-now-ms)
                       (idle-provider-get-idle-seconds idle)
                       #:on-day-completed
                       (lambda (closing)
                         ;; Archive the closing day BEFORE the reset, then
                         ;; publish the cross-device aggregate for it. The
                         ;; outcome accumulator rides the same lifecycle:
                         ;; the closing day keeps its events, the new day
                         ;; starts empty.
                         (history-save-day! history
                                            (day-stats-date-key closing)
                                            (stats->record closing (outcomes-snapshot rt))
                                            (day-stats-date-key closing))
                         (hash-clear! (runtime-outcomes-today rt))
                         (publish-outcomes! rt)
                         (day-completed
                          (record->dto
                           (day-stats-date-key closing)
                           (aggregate-current! rt))))))
    (define o
      (make-orchestrator scheduler
                         (current-now-ms)
                         #:on-cue
                         (lambda (record)
                           (health-cue (cue->dto record))
                           (publish-pending-cues! rt))
                         #:on-flush
                         (lambda () (flush-today! rt))
                         #:on-outcome
                         (lambda (kind status)
                           ;; The honest delivery/response ledger (issue #88):
                           ;; every transition lands here exactly once, so
                           ;; replay or restart cannot double-count — the
                           ;; accumulator only ever advances through these
                           ;; events, and the day shard is overwritten, not
                           ;; incremented, on flush.
                           (define h (runtime-outcomes-today rt))
                           (hash-set! h kind
                                      (hash-update (hash-ref h kind (hasheq))
                                                   status add1 0))
                           (publish-outcomes! rt))))
    (define rt (runtime scheduler o history data-dir device-id idle (make-hash) #f))
    (set-box! runtime-box rt)
    ;; A mid-day restart keeps the morning's activity: seed the persisted
    ;; same-day record into the fresh session before any flush can clobber
    ;; it. Deliberately THIS device's shard, never the cross-device aggregate
    ;; — synced minutes from other machines must not enter the local
    ;; accumulator, or the next flush would write them into this device's
    ;; shard and double-count everywhere. The cue-outcome map seeds the same
    ;; way: this morning's presented/answered counts survive the restart.
    (define today-key (day-stats-date-key (scheduler-stats scheduler)))
    (define restored (history-device-record history today-key))
    (orchestrator-restore-today! o restored)
    (for ([(kind per-kind) (in-hash (day-record-cue-outcomes restored))])
      (hash-set! (runtime-outcomes-today rt) kind per-kind))
    (publish-outcomes! rt)
    ;; Publish initial state and start the lazy tick thread (inherits the
    ;; event emitter + injection parameters from this request thread).
    (state-set! active-config (config->dto loaded-config))
    (publish-stats! rt)
    (publish-paused! rt)
    (apply-quiet-hours! rt)
    (publish-pending-cues! rt)
    (unless (unbox tick-thread-box)
      (set-box! tick-thread-box
                (thread (lambda () (tick-loop rt)))))
    (unless (unbox auto-check-thread-box)
      (set-box! auto-check-thread-box (thread auto-check-loop))))
  (void))

;; --- Tick thread ----------------------------------------------------------

(define (tick-loop rt)
  (let loop ()
    (sleep (current-tick-interval-seconds))
    ;; One bad tick (transient FFI failure, host hiccup) must never kill the
    ;; reminder thread — the tray app keeps working.
        (with-handlers ([exn:fail? (lambda (e)
                                 (log-error 'movebit "tick failed: ~a" e))])
      (apply-quiet-hours! rt)
      (orchestrator-tick! (runtime-orchestrator rt))
      (publish-stats! rt)
      (publish-paused! rt)
      (publish-pending-cues! rt))
    (loop)))

;; --- Cue actions -----------------------------------------------------------
;; The cue lifecycle (issue #55): Done acknowledges (self-reported), Later
;; snoozes every merged kind, Hide expires without claiming completion, and
;; the host confirms rendering so the ledger distinguishes pending/displayed.

(define-rpc (acknowledge-cue [id : Int64] : Void)
  (define rt (require-runtime))
  (define acked (orchestrator-acknowledge-cue! (runtime-orchestrator rt) id))
  (when (and acked (memq 'sit acked))
    (cue-acknowledged
     (CueAcknowledged (ReminderKind 'sit)
                      (orchestrator-sit-acks-today (runtime-orchestrator rt)))))
  (publish-pending-cues! rt)
  (publish-stats! rt)
  (void))

(define-rpc (snooze-cue [id : Int64] : Void)
  (define rt (require-runtime))
  (orchestrator-snooze-cue! (runtime-orchestrator rt) id)
  (publish-pending-cues! rt)
  (state-set! loops (loops->dto rt))
  (void))

(define-rpc (dismiss-cue [id : Int64] : Void)
  (define rt (require-runtime))
  (orchestrator-dismiss-cue! (runtime-orchestrator rt) id)
  (publish-pending-cues! rt)
  (void))

(define-rpc (cue-displayed [id : Int64] : Void)
  (define rt (require-runtime))
  (orchestrator-cue-displayed! (runtime-orchestrator rt) id)
  (publish-pending-cues! rt)
  (void))

;; Focus/presentation silence. When it ends, queued cues collapse into one
;; bounded summary cue that arrives via the health-cue event.
(define-rpc (set-quiet [enabled : Bool] : Void)
  (define rt (require-runtime))
  (orchestrator-set-quiet! (runtime-orchestrator rt) enabled)
  (publish-pending-cues! rt)
  (void))

;; Host capability report (character surface safety, OS Reduce Motion).
(define-rpc (set-host-capability [character-surface-supported : Bool]
                                 [reduce-motion : Bool] : Void)
  (define rt (require-runtime))
  (orchestrator-set-host-capability!
   (runtime-orchestrator rt)
   #:surface-supported? character-surface-supported
   #:reduce-motion? reduce-motion)
  (void))

(define-rpc (pause-1h : Void)
  (define rt (require-runtime))
  (orchestrator-pause-1h! (runtime-orchestrator rt))
  (publish-paused! rt)
  (void))

(define-rpc (resume : Void)
  (define rt (require-runtime))
  (orchestrator-resume! (runtime-orchestrator rt))
  (publish-paused! rt)
  (void))

;; --- Config ---------------------------------------------------------------

(define-rpc (set-config [value : ReminderConfig] : Void)
  (define rt (require-runtime))
  (define clamped (dto->config value))
  ;; All writes are immediate auto-save; failure keeps in-memory settings.
  (save-config (runtime-data-dir rt) clamped)
  (set-scheduler-config! (runtime-scheduler rt) clamped)
  (state-set! active-config (config->dto clamped))
  (apply-quiet-hours! rt)
  (state-set! loops (loops->dto rt))
  (config-changed (config->dto clamped))
  (void))

;; Rhythm presets live in the shared config module, so every host sends only
;; the preset NAME and the exact cadence values stay a single Racket source of
;; truth (issue #87).
(define-rpc (set-rhythm-preset [name : String] : Void)
  (define rt (require-runtime))
  (define which (string->symbol name))
  (unless (memq which '(balanced gentle active))
    (error 'set-rhythm-preset "unknown rhythm preset: ~a" name))
  (define applied (apply-preset (scheduler-config (runtime-scheduler rt)) which))
  (save-config (runtime-data-dir rt) applied)
  (set-scheduler-config! (runtime-scheduler rt) applied)
  (state-set! active-config (config->dto applied))
  (apply-quiet-hours! rt)
  (state-set! loops (loops->dto rt))
  (config-changed (config->dto applied))
  (void))

;; --- History --------------------------------------------------------------

(define-rpc (get-history [days : Int64] : (List DayStats))
  (define rt (require-runtime))
  (define scheduler (runtime-scheduler rt))
  ;; Pick up shards that arrived through the folder sync before aggregating.
  (history-refresh! (runtime-history rt))
  ;; Retention caps meaningful history at 370 days; keep huge requests sane.
  (define recent
    (history-get-recent (runtime-history rt)
                        (min 370 (inexact->exact days))
                        (day-stats-date-key (scheduler-stats scheduler))))
  (for/list ([entry (in-list recent)])
    (record->dto (car entry) (cdr entry))))

;; --- Data directory (bring-your-own-sync) ---------------------------------
;; Point data-dir at a Resilio/Syncthing folder and every device in that
;; folder contributes to the shared totals. The pointer lives in the
;; bootstrap file OUTSIDE the synced data (each machine keeps its own) and
;; takes effect on the next launch.

(define-rpc (get-data-dir : String)
  (path->string (runtime-data-dir (require-runtime))))

(define-rpc (set-data-dir [path : String] : Void)
  (define trimmed (string-trim path))
  (define custom?
    (not (string=? trimmed "")))
  (when custom?
    ;; Create it and actually write into it — a pointer to an unwritable
    ;; folder would only surface as a broken app after the restart.
    (define target (simple-form-path trimmed))
    (make-directory* target)
    (define probe (build-path target ".movebit-write-probe"))
    (call-with-output-file probe (lambda (out) (display "ok" out)) #:exists 'replace)
    (delete-file probe))
  (save-bootstrap
   (hash-set (load-bootstrap) 'data-dir (and custom? trimmed)))
  (void))

;; --- Online updates --------------------------------------------------------
;; The backend verifies the signed feed and downloads the artifact; the host
;; owns the install gesture (prepare-update-install writes the detached apply
;; helper the host spawns before exiting). Unpackaged dev builds carry no
;; key, so every update path degrades to an honest "unavailable".

(define (hasheq->update-check h)
  (UpdateCheck
   (hash-ref h 'status "error")
   (or (hash-ref h 'currentVersion #f) "")
   (hash-ref h 'availableVersion (void))
   (hash-ref h 'build (void))
   (hash-ref h 'sizeBytes (void))
   (hash-ref h 'message (void))))

(define-rpc (check-updates : UpdateCheck)
  (hasheq->update-check (perform-check! default-update-base-url)))

;; Doubles as the cancel gesture (the taskly toggle contract): calling it
;; while a download runs cancels that download — no extra RPC, the schema
;; stays put. The backend lands the phase back on idle, so a host's Cancel
;; button calls this same RPC and watches the state it already polls.
(define-rpc (start-update-download : Void)
  (start-download! (runtime-data-dir (require-runtime)))
  (void))

(define-rpc (get-update-state : UpdateState)
  (define snapshot (update-state-snapshot))
  ;; Optional fields must carry (void) for "none" over the wire. The state
  ;; hash uses #f for absent strings internally — #f is NOT a wire value
  ;; (it fails the UpdateState type check, which surfaced as a failing
  ;; get-update-state RPC in the packaged diagnostics).
  (define (opt v) (if (false? v) (void) v))
  (UpdateState
   (hash-ref snapshot 'phase "idle")
   (hash-ref snapshot 'percent 0)
   (opt (hash-ref snapshot 'message (void)))
   (opt (hash-ref snapshot 'availableVersion (void)))
   (opt (hash-ref snapshot 'downloadedPath (void)))))

(define-rpc (set-install-dir [path : String] : Void)
  (current-install-dir (simple-form-path (string-trim path)))
  (void))

;; Spawn the apply helper detached: no port wiring, and it must outlive both
;; the host process and the backend thread that started it. cmd /c on
;; Windows (the .cmd helper), /bin/sh elsewhere (the POSIX .sh helper).
(define (spawn-apply-helper! helper)
  (case (system-type 'os)
    [(windows)
     (subprocess #f #f #f (find-executable-path "cmd.exe") "/c" helper)]
    [else
     (subprocess #f #f #f "/bin/sh" helper)]))

(define-rpc (prepare-update-install : String)
  ;; Extraction runs on the request worker (a few seconds). The host then
  ;; exits; the helper waits for THIS process to disappear before swapping.
  (define helper
    (prepare-install! (runtime-data-dir (require-runtime))))
  (spawn-apply-helper! helper)
  helper)

(define (auto-check-loop)
  ;; The family's silent-check contract: one throttled check shortly after
  ;; init, then a six-hour wake. Every wake honors the user's auto-check
  ;; preference AND the persistent four-hour throttle stamp (update.rkt's
  ;; bootstrap-backed stamp) — a restart no longer forces a check on a
  ;; freshly checked install, and a settled stamp means the wake can never
  ;; reset the update state out from under an in-flight manual download
  ;; (downloads are bounded at 30 minutes, well inside the throttle).
  ;; Manual checks go through the check-updates RPC and never consult the
  ;; throttle; both paths refresh the stamp on a settled check.
  (let loop ()
    (sleep 3)
    (define rt (unbox runtime-box))
    (when (and rt
               (reminder-config-auto-check-updates
                (scheduler-config (runtime-scheduler rt)))
               (not (update-check-throttled?)))
      (with-handlers ([exn:fail? void])
        (perform-check! default-update-base-url)))
    (sleep (* 6 60 60))
    (loop)))

;; --- Autostart (domain-owned; port of Services/AutoStart.cs) ---------------

(define-rpc (get-autostart : Bool)
  (autostart-enabled?))

(define-rpc (set-autostart [enabled : Bool] : Void)
  (set-autostart! enabled)
  (void))

;; --- Diagnostics & lifecycle ---------------------------------------------

(define-rpc (get-diagnostics : String)
  (define rt (require-runtime))
  (define scheduler (runtime-scheduler rt))
  (define c (scheduler-config scheduler))
  (define stats (scheduler-stats scheduler))
  (define date-key (day-stats-date-key stats))
  ;; The version is the repo's single source (rivet-app-info in packaged
  ;; builds, staged from rivet.rktd = VERSION; the update parameter covers
  ;; headless runs) — never a second, hand-maintained string here.
  (string-join
   (list
    (~a "movebit " (effective-version))
    (~a "platform: " (system-type) " / " (system-type 'machine))
    (~a "data-dir: " (runtime-data-dir rt))
    (~a "device-id: " (runtime-device-id rt)
        " · devices today: "
        (string-join (history-device-ids (runtime-history rt) date-key) ", "))
    (~a "idle-provider: " (idle-provider-name (runtime-idle-provider rt)))
    (~a "today: " (day-stats-date-key stats)
        " active " (ms->mins (day-stats-active-ms stats)) "m"
        " sit " (day-stats-sit-reminders stats)
        " water " (day-stats-water-reminders stats)
        " micro " (day-stats-micro-breaks stats)
        " longest " (ms->mins (day-stats-longest-session-ms stats)) "m")
    (~a "config: sit " (reminder-config-sit-reminder-minutes c)
        "m water " (reminder-config-water-reminder-minutes c)
        "m away " (reminder-config-away-reset-minutes c)
        "m micro " (reminder-config-micro-break-enabled c)
        " motion " (reminder-config-motion-enabled c)
        " language " (reminder-config-language c)
        " mubi " (reminder-config-companion-size c)
        "/" (reminder-config-companion-motion c)
        "/" (reminder-config-companion-dock c))
    (~a "paused: " (scheduler-paused-until-ms scheduler))
    (~a "quiet: " (movebit-orchestrator-quiet? (runtime-orchestrator rt))
        " · open cues: "
        (length (orchestrator-open-cues (runtime-orchestrator rt))))
    (~a "sit-acks today: "
        (orchestrator-sit-acks-today (runtime-orchestrator rt))))
   "\n"))

;; Hosts call this on exit / before an update restart so at most a few seconds
;; of today's activity are lost (port of FlushToday-on-exit).
(define-rpc (flush-now : Void)
  (orchestrator-flush! (runtime-orchestrator (require-runtime)))
  (void))

;; --- Entry point ----------------------------------------------------------

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
