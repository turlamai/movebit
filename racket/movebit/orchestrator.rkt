#lang racket/base

;; App-level orchestration around the scheduler: the same-tick merge rule and
;; the v1 cue lifecycle. The orchestrator is pure domain logic — no UI, no
;; rivet — so the same rules run identically on every host shell.
;;
;; Every tick's due reminders merge into ONE cue (kinds preserved, priority
;; ordered; snoozing a merged cue defers all of its kinds). Each cue then
;; moves through the explicit lifecycle pinned by issue #55:
;;
;;   due → pending → displayed → acknowledged | snoozed | dismissed | expired
;;
;; `pending` = created, not yet confirmed on screen; `displayed` = the host
;; reported the cue visible. Done (acknowledge) is SELF-REPORTED — it never
;; proves water was drunk or a break taken, and it does not advance stats
;; (stats count fired reminders). Later (snooze) defers every merged kind by
;; the configured snooze via the scheduler's active-time semantics. Hide
;; (dismiss) and the ten-minute timeout both end the cue without claiming
;; completion — the reminder's cycle already restarted at fire time, so the
;; next reminder arrives on the normal schedule and nothing is silently lost.
;;
;; Focus/presentation silence changes PRESENTATION, not completion. It
;; retracts an already-displayed open cue (the host now hides Mubi immediately)
;; back into 'pending, and queues new cues without emitting them. Pending cues
;; do NOT age out during Focus, even in a long meeting; leaving Focus emits one
;; bounded merged invitation. No interrupted/hidden cue becomes "Done".
;; Superseded cues (replaced by the post-Focus merged invitation) end as
;; 'superseded — a bookkeeping status with no outcome event, because their
;; kinds were already presented and the invitation carries them forward.
;;
;; Outcome events (issue #88): every meaningful transition reports one
;; (kind status) pair per merged kind through `on-outcome`, so history can
;; persist presented / self-reported-done / snoozed / dismissed / expired /
;; not-delivered per kind per day instead of conflating them with fired
;; reminders. 'presented is a DELIVERY record, 'self-reported-done a claim —
;; neither is proof of a completed break.

(require "companion-cue.rkt"
         "config.rkt"
         "history.rkt"
         "scheduler.rkt"
         "timeutil.rkt")

(provide (struct-out cue-record)
         (struct-out movebit-orchestrator)
         make-orchestrator
         orchestrator-tick!
         orchestrator-acknowledge-cue!
         orchestrator-snooze-cue!
         orchestrator-dismiss-cue!
         orchestrator-abandon-cue!
         orchestrator-cue-displayed!
         orchestrator-set-quiet!
         orchestrator-set-host-capability!
         orchestrator-pause-1h!
         orchestrator-resume!
         orchestrator-restore-today!
         orchestrator-flush!
         orchestrator-open-cues
         orchestrator-find-cue
         orchestrator-sit-acks-today
         should-celebrate?)

;; id (monotone), all due kinds, the planned presentation, creation time and
;; lifecycle status. `planned` is frozen at creation: the delivery decision
;; shown to the user never mutates retroactively.
(struct cue-record (id kinds planned created-ms status) #:transparent)

(struct movebit-orchestrator
  (scheduler
   now                    ; (-> integer-ms), same clock as the scheduler
   cues                   ; ledger, newest first (cue-record)
   next-cue-id            ; monotone integer payload id
   quiet?                 ; focus/presentation silence
   surface-supported?     ; host-reported character-surface capability
   reduce-motion?         ; host-reported OS Reduce Motion
   sit-acks-today         ; acknowledged sit cues today (celebrations only)
   ack-day-key            ; the date-key the ack counter belongs to
   pending                ; reversed list of (kind count active-ms) this tick
   flush-counter          ; stats flush roughly every 10 ticks (~5 minutes)
   on-cue                 ; #f or (cue-record) -> any — show this cue NOW
   on-stats-changed       ; #f or (-> any) after each stateful tick
   on-flush               ; #f or (-> any): persist today's stats now
   on-outcome)            ; #f or (kind status) -> any — cue outcome event
  #:transparent
  #:mutable)

(define ticks-per-flush 10)          ; ~5 minutes at the 30 s tick
(define hour-ms (* 60 60 1000))
(define ledger-cap 100)              ; keep diagnostics bounded

(define (make-orchestrator scheduler now
                            #:on-cue [on-cue #f]
                            #:on-stats-changed [on-stats-changed #f]
                            #:on-flush [on-flush #f]
                            #:on-outcome [on-outcome #f])
  ;; Wire the scheduler's reminder events into the per-tick batch once, the
  ;; same way the old app subscribed ReminderFired at startup. Any previously
  ;; installed callback (tests, diagnostics) stays in the chain.
  (define previous-on-reminder (movebit-scheduler-on-reminder scheduler))
  (define o
    (movebit-orchestrator scheduler now '() 1 #f #t #f 0
                          (ms->date-key (now)) '() 0
                          on-cue on-stats-changed on-flush on-outcome))
  (set-movebit-scheduler-on-reminder!
   scheduler
   (lambda (kind count active-ms)
     (when previous-on-reminder (previous-on-reminder kind count active-ms))
     (collect-reminder! o kind count active-ms)))
  o)

(define (orch-config o)
  (scheduler-config (movebit-orchestrator-scheduler o)))

;; Effective static-motion input: the OS Reduce Motion report OR the user's
;; in-app motion preference both force a static cue.
(define (effective-reduce-motion? o)
  (or (movebit-orchestrator-reduce-motion? o)
      (not (reminder-config-motion-enabled (orch-config o)))))

(define (plan-for o kinds)
  (plan-companion-cue
   kinds
   #:quiet? (movebit-orchestrator-quiet? o)
   #:surface-supported? (movebit-orchestrator-surface-supported? o)
   #:reduce-motion? (effective-reduce-motion? o)))

;; --- cue ledger -------------------------------------------------------------

(define (find-cue o id)
  (findf (lambda (c) (= (cue-record-id c) id)) (movebit-orchestrator-cues o)))

(define (open? c) (memq (cue-record-status c) '(pending displayed)))

(define (orchestrator-open-cues o)
  ;; Oldest first, open only — the "what is on screen right now" view.
  (reverse (filter open? (movebit-orchestrator-cues o))))

(define (orchestrator-find-cue o id)
  (find-cue o id))

(define (orchestrator-sit-acks-today o)
  (movebit-orchestrator-sit-acks-today o))

(define (add-to-ledger! o planned now)
  (define id (movebit-orchestrator-next-cue-id o))
  (set-movebit-orchestrator-next-cue-id! o (add1 id))
  (define record (cue-record id (companion-cue-kinds planned) planned now 'pending))
  (set-movebit-orchestrator-cues! o (cons record (movebit-orchestrator-cues o)))
  ;; Bound the ledger: once the cap is exceeded drop the oldest entries.
  (let loop ([cs (movebit-orchestrator-cues o)])
    (when (> (length cs) ledger-cap)
      (set-movebit-orchestrator-cues! o (reverse (cdr (reverse cs))))
      (loop (movebit-orchestrator-cues o))))
  record)

;; The outcome event a transition represents, per issue #88's taxonomy.
;; Retractions (→ pending) and the internal 'superseded terminal report
;; nothing: they change presentation or bookkeeping, never the delivery
;; record. A pending cue that dies unseen is 'not-delivered, NOT 'expired —
;; only something actually shown can time out.
(define (outcome-for from to)
  (case to
    [(displayed) (and (eq? from 'pending) 'presented)]
    [(acknowledged) 'self-reported-done]
    [(snoozed) 'snoozed]
    [(dismissed) 'dismissed]
    [(abandoned) 'abandoned]
    [(expired)
     (case from
       [(pending) 'not-delivered]
       [(displayed) 'expired]
       [else #f])]
    [else #f]))

(define (set-status! o record status)
  (define from (cue-record-status record))
  (set-movebit-orchestrator-cues!
   o
   (for/list ([c (in-list (movebit-orchestrator-cues o))])
     (if (eq? c record) (struct-copy cue-record c [status status]) c)))
  (define event (and (not (eq? from status)) (outcome-for from status)))
  (when event
    (define cb (movebit-orchestrator-on-outcome o))
    (when cb
      (for ([kind (in-list (cue-record-kinds record))])
        (cb kind event)))))

;; --- same-tick merge rule ---------------------------------------------------

;; Collect scheduler reminder callbacks into the per-tick batch.
(define (collect-reminder! o kind count active-ms)
  (set-movebit-orchestrator-pending!
   o (cons (list kind count active-ms) (movebit-orchestrator-pending o))))

(define (take-pending! o)
  (define events (reverse (movebit-orchestrator-pending o)))
  (set-movebit-orchestrator-pending! o '())
  events)

;; First occurrence of each kind, in sit/water/micro priority order.
(define (dedupe-kinds events)
  (for/fold ([acc '()])
            ([e (in-list events)])
    (define kind (car e))
    (if (memq kind acc) acc (append acc (list kind)))))

;; One cue per tick, ever: every kind due this tick merges into ONE cue with
;; all meanings preserved (each kind keeps its own Later/snooze semantics).
(define (flush-tick-reminders! o)
  (define events (take-pending! o))
  (when (pair? events)
    (define kinds (dedupe-kinds events))
    (define planned (plan-for o kinds))
    (when planned
      (define record
        (add-to-ledger! o planned ((movebit-orchestrator-now o))))
      ;; A quiet cue is queued, not shown; the host hears about it when
      ;; Focus ends (as part of the summary), never as a live interruption.
      (unless (eq? (companion-cue-delivery planned) 'quiet)
        (define cb (movebit-orchestrator-on-cue o))
        (when cb (cb record))))))

;; --- lifecycle actions ------------------------------------------------------

;; Done: self-reported acknowledgement. A sit claim ends the counted
;; continuous session (the user says they got up); water/micro claims touch
;; no timer beyond the cue itself. Never fires stats — a click is not proof.
;; Returns the acknowledged kinds, or #f when the id was unknown/settled.
(define (orchestrator-acknowledge-cue! o id)
  (define record (find-cue o id))
  (and record
       (open? record)
       (let ([kinds (cue-record-kinds record)])
         (set-status! o record 'acknowledged)
         (when (memq 'sit kinds)
           (scheduler-end-session! (movebit-orchestrator-scheduler o))
           (sync-ack-day! o)
           (set-movebit-orchestrator-sit-acks-today!
            o (add1 (movebit-orchestrator-sit-acks-today o))))
         kinds)))

;; Later: defer every merged kind by the configured snooze of ACTIVE time.
(define (orchestrator-snooze-cue! o id)
  (define record (find-cue o id))
  (when (and record (open? record))
    (for ([kind (in-list (cue-record-kinds record))])
      (scheduler-snooze! (movebit-orchestrator-scheduler o) kind))
    (set-status! o record 'snoozed)))

;; Hide: remove the cue WITHOUT claiming completion and without deferring —
;; the cycle already restarted at fire time, so the next reminder comes on
;; the normal schedule. Its own terminal status keeps Hide distinguishable
;; from a timeout in the outcome history (issue #88).
(define (orchestrator-dismiss-cue! o id)
  (define record (find-cue o id))
  (when (and record (open? record))
    (set-status! o record 'dismissed)))

;; Abandon: a guided session (eye rest / stretch) was started and then
;; stopped. Distinct from Hide ("put the reminder away") and from a timeout,
;; so the outcome ledger can keep the deliberate act separate. Never marks
;; the health action as done.
(define (orchestrator-abandon-cue! o id)
  (define record (find-cue o id))
  (when (and record (open? record))
    (set-status! o record 'abandoned)))

;; Host reports the cue actually visible: pending → displayed.
(define (orchestrator-cue-displayed! o id)
  (define record (find-cue o id))
  ;; UI delivery acknowledgments can arrive after a user has entered Focus.
  ;; The character has already been withdrawn, so a late report must not
  ;; consume the deferred invitation or mark a hidden notice as presented.
  (when (and (not (movebit-orchestrator-quiet? o))
             record (eq? (cue-record-status record) 'pending))
    (set-status! o record 'displayed)))

;; Focus is the existing single meeting/quiet action. Entering Focus cancels
;; an open, already-visible invitation in the native host; put it back into
;; the pending set so it can be recalled when the meeting ends.
;; LEAVING Focus collapses the pending types into ONE re-invitation, without
;; repeating every missed due moment or pretending anyone took a break.
(define (orchestrator-set-quiet! o enabled?)
  (unless (boolean? enabled?)
    (raise-argument-error 'orchestrator-set-quiet! "boolean?" enabled?))
  (define was (movebit-orchestrator-quiet? o))
  (set-movebit-orchestrator-quiet?! o enabled?)
  (when (and (not was) enabled?)
    (for ([c (in-list (filter open? (movebit-orchestrator-cues o)))])
      (when (eq? (cue-record-status c) 'displayed)
        (set-status! o c 'pending))))
  (when (and was (not enabled?))
    (define summary-kinds
      (summarize-open-cues
       (for/list ([c (in-list (filter open? (movebit-orchestrator-cues o)))])
         (open-cue (cue-record-id c) (cue-record-kinds c)
                   (cue-record-status c) (cue-record-created-ms c)))))
    (when summary-kinds
      ;; 'superseded: the merged re-invitation below carries these kinds
      ;; forward. No outcome event — their kinds were presented before Focus
      ;; and a fabricated not-delivered/expired entry would be a lie (the
      ;; user simply could not answer during the meeting).
      (for ([c (in-list (filter open? (movebit-orchestrator-cues o)))])
        (set-status! o c 'superseded))
      (define planned (plan-for o summary-kinds))
      (when planned
        (define record
          (add-to-ledger! o planned ((movebit-orchestrator-now o))))
        (define cb (movebit-orchestrator-on-cue o))
        (when cb (cb record))))))

;; Host capability report: can this platform render a safe character surface,
;; and does the OS currently request reduced motion? Both feed the NEXT
;; planned cue; existing cues keep their frozen presentation.
(define (orchestrator-set-host-capability! o
                                            #:surface-supported? [surface? #f]
                                            #:reduce-motion? [reduce-motion? #f])
  (when (boolean? surface?)
    (set-movebit-orchestrator-surface-supported?! o surface?))
  (when (boolean? reduce-motion?)
    (set-movebit-orchestrator-reduce-motion?! o reduce-motion?)))

;; --- tick -------------------------------------------------------------------

;; Roll the celebration counter when the scheduler's day rolled over.
(define (sync-ack-day! o)
  (define today (ms->date-key ((movebit-orchestrator-now o))))
  (unless (string=? today (movebit-orchestrator-ack-day-key o))
    (set-movebit-orchestrator-ack-day-key! o today)
    (set-movebit-orchestrator-sit-acks-today! o 0)))

;; Expire open cues past the policy window (timeout, not completion).
(define (expire-stale-cues! o)
  (define now ((movebit-orchestrator-now o)))
  (for ([c (in-list (filter open? (movebit-orchestrator-cues o)))])
    ;; A long Focus session cannot erase deferred health reminders. Only
    ;; normal visible pending/displayed cues expire after their policy window.
    (unless (and (movebit-orchestrator-quiet? o)
                 (eq? (cue-record-status c) 'pending))
      (when (>= (- now (cue-record-created-ms c)) cue-expiry-ms)
        (set-status! o c 'expired)))))

;; Advance one tick: scheduler, same-tick cue merge, expiry, stats flush.
(define (orchestrator-tick! o)
  (sync-ack-day! o)
  (scheduler-tick! (movebit-orchestrator-scheduler o))
  (flush-tick-reminders! o)
  (expire-stale-cues! o)

  ;; Flush today's stats every ~5 minutes so a crash or power loss never
  ;; costs more than a few minutes of history.
  (set-movebit-orchestrator-flush-counter!
   o (modulo (add1 (movebit-orchestrator-flush-counter o)) ticks-per-flush))
  (when (zero? (movebit-orchestrator-flush-counter o))
    (orchestrator-flush! o))

  (define cb (movebit-orchestrator-on-stats-changed o))
  (when cb (cb)))

(define (orchestrator-pause-1h! o)
  (scheduler-pause-for! (movebit-orchestrator-scheduler o) hour-ms))

(define (orchestrator-resume! o)
  (scheduler-resume! (movebit-orchestrator-scheduler o)))

;; Mid-day restart: seed today's persisted record into the fresh scheduler.
;; (The `_restoredFor` idempotence lives in the scheduler.)
(define (orchestrator-restore-today! o record)
  (scheduler-restore-today! (movebit-orchestrator-scheduler o) record))

;; Persist today's stats now (periodic flush, host exit, update restart).
(define (orchestrator-flush! o)
  (define cb (movebit-orchestrator-on-flush o))
  (when cb (cb)))

;; Milestone celebrations fire at 3/5/8 self-reported sit acknowledgments
;; per day; the host owns the copy, the orchestrator owns the decision.
(define celebrate-at '(3 5 8))

(define (should-celebrate? acknowledged-sit-today)
  (and (integer? acknowledged-sit-today)
       (memq acknowledged-sit-today celebrate-at) #t))
