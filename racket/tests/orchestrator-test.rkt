#lang racket/base

;; Tests for the v1 cue lifecycle: same-tick merge rule, the explicit
;; pending → displayed → acknowledged | snoozed | expired transitions, quiet
;; queuing with its bounded summary, expiry policy and host capability
;; inputs. Pinned so every host shell gets identical reminder behavior.

(require rackunit
         "harness.rkt"
         "../movebit/companion-cue.rkt"
         "../movebit/config.rkt"
         "../movebit/orchestrator.rkt"
         "../movebit/scheduler.rkt")

(define minute-ms 60000)

(struct orch-harness (h o cues flushes outcomes) #:transparent)

;; Build a scheduler harness plus its orchestrator with a recording on-cue
;; and a recording on-outcome (issue #88). Only an explicit micro opt-in
;; patches the config (patching clamps — a sub-limit #:sit like 5 must
;; survive raw for short-cycle tests).
(define (make-oh #:sit [sit 45]
                 #:water [water 30]
                 #:micro [micro #f]
                 #:snooze [snooze 10])
  (define h (make-harness #:sit sit #:water water #:snooze snooze))
  (when micro
    (h-patch-config! h #:micro-enabled #t #:micro-interval micro))
  (define cue-box (box '()))
  (define flushes (box 0))
  (define outcomes (box '()))
  (define o
    (make-orchestrator (h-scheduler h)
                       (lambda () (h-now-ms h))
                       #:on-cue
                       (lambda (record)
                         (set-box! cue-box (cons record (unbox cue-box))))
                       #:on-flush
                       (lambda () (set-box! flushes (add1 (unbox flushes))))
                       #:on-outcome
                       (lambda (kind status)
                         (set-box! outcomes
                                   (cons (list kind status) (unbox outcomes))))))
  (orch-harness h o cue-box flushes outcomes))

(define (oh-step! oh ms)
  ;; Advance the virtual clock and drive the ORCHESTRATOR tick (the backend's
  ;; tick thread path), not the bare scheduler tick.
  (h-advance! (orch-harness-h oh) ms)
  (orchestrator-tick! (orch-harness-o oh)))

(define (oh-step-minutes! oh total [step 5])
  (let loop ([remaining (* total minute-ms)] [step-ms (* step minute-ms)])
    (unless (<= remaining 0)
      (define now (if (< remaining step-ms) remaining step-ms))
      (oh-step! oh now)
      (loop (- remaining now) step-ms))))

;; Emitted cues, oldest first.
(define (oh-cues oh) (reverse (unbox (orch-harness-cues oh))))
(define (oh-last-cue oh)
  (define cs (oh-cues oh))
  (and (pair? cs) (car (reverse cs))))
(define (oh-open oh) (orchestrator-open-cues (orch-harness-o oh)))
;; Outcome events, oldest first.
(define (oh-outcomes oh) (reverse (unbox (orch-harness-outcomes oh))))

;; --- merge rule: one cue per tick, kinds preserved --------------------------

;; Sit + water due on the same tick merge into ONE cue; the character gesture
;; carries the highest-priority kind's meaning and the delivery is the
;; default character surface.
(let ([oh (make-oh #:sit 10 #:water 10)])
  (oh-step-minutes! oh 10)
  (check-equal? (length (oh-cues oh)) 1)
  (define c (oh-last-cue oh))
  (check-equal? (cue-record-kinds c) '(sit water))
  (check-equal? (companion-cue-action (cue-record-planned c)) 'stand-and-stretch)
  (check-equal? (companion-cue-gesture (cue-record-planned c)) 'stretch)
  (check-equal? (companion-cue-delivery (cue-record-planned c)) 'character)
  (check-true (companion-cue-animated? (cue-record-planned c)))
  (check-equal? (length (oh-open oh)) 1))

;; Water + micro due together merge; a micro-only tick stays its own cue
;; with the eye-rest action.
(let ([oh (make-oh #:sit 300 #:water 30 #:micro 30)])
  (oh-step-minutes! oh 30)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(water micro))
  (check-equal? (companion-cue-action (cue-record-planned (oh-last-cue oh)))
                'drink-water))
(let ([oh (make-oh #:sit 300 #:water 300 #:micro 30)])
  (oh-step-minutes! oh 30)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(micro))
  (check-equal? (companion-cue-action (cue-record-planned (oh-last-cue oh)))
                'rest-eyes)
  (check-equal? (companion-cue-gesture (cue-record-planned (oh-last-cue oh)))
                'blink))

;; Separate ticks produce separate cues with monotone ids.
(let ([oh (make-oh #:sit 10 #:water 15)])
  (oh-step-minutes! oh 10)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(sit))
  (oh-step-minutes! oh 5)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(water))
  (check-equal? (length (oh-cues oh)) 2)
  (check-true (< (cue-record-id (car (oh-cues oh)))
                 (cue-record-id (cadr (oh-cues oh))))))

;; --- lifecycle: pending → displayed → settled -------------------------------
;; Transitions are functional (the ledger stores the new value); assertions
;; re-find the record by id, exactly like the wire host does.

;; Displayed is a host report, idempotent, and unknown ids are no-ops.
(let ([oh (make-oh #:sit 10)])
  (oh-step-minutes! oh 10)
  (define id (cue-record-id (oh-last-cue oh)))
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'pending)
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'displayed)
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'displayed)
  (orchestrator-acknowledge-cue! (orch-harness-o oh) 99999)
  (check-equal? (length (oh-open oh)) 1))

;; Done on a sit cue: acknowledged, session ends, the celebration counter
;; advances; stats are NOT touched by an acknowledgment.
(let ([oh (make-oh #:sit 10 #:water 300)])
  (oh-step-minutes! oh 10)
  (check-equal? (length (oh-cues oh)) 1)
  (define id (cue-record-id (oh-last-cue oh)))
  (check-equal? (h-session-ms (orch-harness-h oh)) (* 10 minute-ms))
  (check-equal? (day-stats-sit-reminders (h-stats (orch-harness-h oh))) 1)
  (orchestrator-acknowledge-cue! (orch-harness-o oh) id)
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'acknowledged)
  (check-equal? (length (oh-open oh)) 0)
  (check-equal? (h-session-ms (orch-harness-h oh)) 0)
  (check-equal? (orchestrator-sit-acks-today (orch-harness-o oh)) 1)
  (check-equal? (day-stats-sit-reminders (h-stats (orch-harness-h oh))) 1))

;; Done on a water-only cue does NOT end the counted sitting session.
(let ([oh (make-oh #:sit 300 #:water 10)])
  (oh-step-minutes! oh 10)
  (orchestrator-acknowledge-cue! (orch-harness-o oh) (cue-record-id (oh-last-cue oh)))
  (check-equal? (h-session-ms (orch-harness-h oh)) (* 10 minute-ms))
  (check-equal? (orchestrator-sit-acks-today (orch-harness-o oh)) 0))

;; Milestones fire at exactly 3/5/8 acknowledged sit cues per day.
(let ([oh (make-oh #:sit 5 #:water 300)])
  (let loop ([n 0])
    (when (< n 3)
      (oh-step-minutes! oh 5)
      (orchestrator-acknowledge-cue!
       (orch-harness-o oh) (cue-record-id (oh-last-cue oh)))
      (loop (add1 n))))
  (check-equal? (orchestrator-sit-acks-today (orch-harness-o oh)) 3)
  (check-true (should-celebrate? (orchestrator-sit-acks-today (orch-harness-o oh))))
  ;; the 4th ack is between milestones
  (oh-step-minutes! oh 5)
  (orchestrator-acknowledge-cue!
   (orch-harness-o oh) (cue-record-id (oh-last-cue oh)))
  (check-false (should-celebrate? (orchestrator-sit-acks-today (orch-harness-o oh)))))

;; Later on a merged cue defers EVERY merged kind by the snooze minutes.
(let ([oh (make-oh #:sit 300 #:water 30 #:micro 30 #:snooze 4)])
  (oh-step-minutes! oh 30 1)
  (define id (cue-record-id (oh-last-cue oh)))
  (check-equal? (cue-record-kinds (orchestrator-find-cue (orch-harness-o oh) id))
                '(water micro))
  (orchestrator-snooze-cue! (orch-harness-o oh) id)
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'snoozed)
  (check-equal? (length (oh-open oh)) 0)
  ;; accum = interval - snooze = 26 -> both re-fire after 4 more active minutes
  (oh-step-minutes! oh 3 1)
  (check-equal? (h-fired-kinds (orch-harness-h oh)) '(water micro))
  (oh-step-minutes! oh 4 1)
  (check-equal? (h-fired-kinds (orch-harness-h oh)) '(water micro water micro)))

;; Hide ends the cue WITHOUT claiming completion and without deferring:
;; water re-fires on its normal full interval, not after a snooze. Hide keeps
;; its own terminal status so the outcome history can tell it from a timeout.
(let ([oh (make-oh #:sit 300 #:water 10 #:snooze 5)])
  (oh-step-minutes! oh 10)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-dismiss-cue! (orch-harness-o oh) id)
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'dismissed)
  (check-equal? (length (oh-open oh)) 0)
  (check-equal? (h-session-ms (orch-harness-h oh)) (* 10 minute-ms))
  ;; normal schedule: the next water reminder is one FULL interval after the
  ;; fire (minute 10 + 10 = 20), not a snooze-length defer
  (oh-step-minutes! oh 9 1)
  (check-equal? (h-fired-kinds (orch-harness-h oh)) '(water))
  (oh-step-minutes! oh 1 1)
  (check-equal? (h-fired-kinds (orch-harness-h oh)) '(water water)))

;; Timeout expiry: an unacknowledged cue closes after the policy window and
;; the next reminder keeps the normal schedule (nothing silently lost).
;; Water 15 keeps the re-fire (minute 30) clear of the expiry moment (25).
(let ([oh (make-oh #:sit 300 #:water 15)])
  (oh-step-minutes! oh 15 5)
  (check-equal? (length (oh-open oh)) 1)
  (oh-step-minutes! oh 9 3)
  (check-equal? (length (oh-open oh)) 1) ; 9 minutes old: still current
  (oh-step-minutes! oh 2 1)
  (check-equal? (length (oh-open oh)) 0) ; past cue-expiry-ms: expired
  (check-equal? (h-fired-kinds (orch-harness-h oh)) '(water)))

;; --- outcome events (issue #88): presentation ≠ response ≠ timeout ----------

;; The full delivery/response path: presenting a merged cue reports one
;; 'presented per kind; Done reports 'self-reported-done; neither implies
;; more than the user actually did.
(let ([oh (make-oh #:sit 10 #:water 10)])
  (oh-step-minutes! oh 10)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(sit water))
  (define id (cue-record-id (oh-last-cue oh)))
  (check-equal? (oh-outcomes oh) '()) ; pending, not yet on screen
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (check-equal? (oh-outcomes oh) '((sit presented) (water presented)))
  (orchestrator-acknowledge-cue! (orch-harness-o oh) id)
  (check-equal? (oh-outcomes oh)
                '((sit presented) (water presented)
                  (sit self-reported-done) (water self-reported-done))))

;; Later reports its own terminal, distinct from a timeout (oldest first).
(let ([oh (make-oh #:sit 300 #:water 10)])
  (oh-step-minutes! oh 10)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (orchestrator-snooze-cue! (orch-harness-o oh) id)
  (check-equal? (oh-outcomes oh)
                '((water presented) (water snoozed))))

;; Hide reports 'dismissed, again distinct from a timeout.
(let ([oh (make-oh #:sit 300 #:water 10)])
  (oh-step-minutes! oh 10)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (orchestrator-dismiss-cue! (orch-harness-o oh) id)
  (check-equal? (oh-outcomes oh)
                '((water presented) (water dismissed))))

;; A shown cue that times out unanswered is 'expired.
(let ([oh (make-oh #:sit 300 #:water 15)])
  (oh-step-minutes! oh 15 5)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (oh-step-minutes! oh 11 1)
  (check-equal? (oh-outcomes oh) '((water presented) (water expired))))

;; A never-shown pending cue that times out outside Focus is 'not-delivered:
;; nothing reached the screen, and history must not pretend it did.
(let ([oh (make-oh #:sit 300 #:water 5)])
  ;; A host that never reports displayed: the cue fires and times out unseen.
  (oh-step-minutes! oh 5)
  (check-equal? (length (oh-open oh)) 1)
  (oh-step-minutes! oh 11 1)
  (check-equal? (oh-outcomes oh) '((water not-delivered))))

;; Superseding by Focus-exit fires NO outcome event for the superseded cue.
(let ([oh (make-oh #:sit 300 #:water 10)])
  (oh-step-minutes! oh 10)
  (define first-id (cue-record-id (oh-last-cue oh)))
  (orchestrator-cue-displayed! (orch-harness-o oh) first-id)
  (orchestrator-set-quiet! (orch-harness-o oh) #t)
  (orchestrator-set-quiet! (orch-harness-o oh) #f)
  ;; Only the original presentation exists — no expired/not-delivered entry.
  (check-equal? (length (oh-outcomes oh)) 1)
  (check-equal? (oh-outcomes oh) '((water presented))))

;; --- quiet mode: queue, never emit; bounded summary on exit -----------------

;; While quiet, a due reminder creates a pending ledger entry and emits
;; NOTHING; leaving quiet emits ONE summary cue carrying the union of kinds
;; and expires the superseded entries.
(let ([oh (make-oh #:sit 300 #:water 10)])
  (orchestrator-set-quiet! (orch-harness-o oh) #t)
  (oh-step-minutes! oh 10)
  (check-equal? (oh-cues oh) '())
  (check-equal? (length (oh-open oh)) 1)
  (orchestrator-set-quiet! (orch-harness-o oh) #f)
  (check-equal? (length (oh-cues oh)) 1)
  (define summary (oh-last-cue oh))
  (check-equal? (cue-record-kinds summary) '(water))
  (check-equal? (companion-cue-delivery (cue-record-planned summary)) 'character)
  (check-equal? (length (oh-open oh)) 1)
  (check-eq? (car (oh-open oh)) summary))

;; The summary is bounded: three quiet moments collapse into one cue whose
;; kinds are the priority-ordered union.
(let ([oh (make-oh #:sit 10 #:water 10 #:micro 10)])
  (orchestrator-set-quiet! (orch-harness-o oh) #t)
  (oh-step-minutes! oh 10)
  (check-equal? (oh-cues oh) '())
  (check-equal? (length (oh-open oh)) 1)
  (orchestrator-set-quiet! (orch-harness-o oh) #f)
  (check-equal? (length (oh-cues oh)) 1)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(sit water micro)))

;; Long meetings do NOT expire a reminder that was never shown. The core
;; preserves its meaning for one merged invite after Focus ends, even when the
;; original due event is older than the ordinary ten-minute visual timeout.
(let ([oh (make-oh #:sit 300 #:water 20)])
  (orchestrator-set-quiet! (orch-harness-o oh) #t)
  (oh-step-minutes! oh 20 5)
  (check-equal? (length (oh-open oh)) 1)
  (oh-step-minutes! oh 15 3)
  (check-equal? (length (oh-open oh)) 1) ; still deferred, not silently lost
  (orchestrator-set-quiet! (orch-harness-o oh) #f)
  (check-equal? (length (oh-cues oh)) 1)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(water))
  (check-equal? (length (oh-open oh)) 1))

;; Entering Focus while an already-displayed cue is visible removes it from
;; presentation, rather than "taking it as seen". A late native delivered
;; callback must not consume it while Focus is on. One new invitation on exit.
(let ([oh (make-oh #:sit 300 #:water 10)])
  (oh-step-minutes! oh 10)
  (define first (oh-last-cue oh))
  (define id (cue-record-id first))
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (check-equal? (cue-record-status
                 (orchestrator-find-cue (orch-harness-o oh) id))
                'displayed)
  (orchestrator-set-quiet! (orch-harness-o oh) #t)
  (check-equal? (cue-record-status
                 (orchestrator-find-cue (orch-harness-o oh) id))
                'pending)
  (orchestrator-cue-displayed! (orch-harness-o oh) id) ; late host callback
  (check-equal? (cue-record-status
                 (orchestrator-find-cue (orch-harness-o oh) id))
                'pending)
  (orchestrator-set-quiet! (orch-harness-o oh) #f)
  (check-equal? (length (oh-cues oh)) 2)
  (define summary (oh-last-cue oh))
  (check-equal? (cue-record-kinds summary) '(water))
  ;; The retracted cue is superseded by the merged invitation — a bookkeeping
  ;; terminal with NO outcome event, never a fabricated expiry.
  (check-equal? (cue-record-status
                 (orchestrator-find-cue (orch-harness-o oh) id))
                'superseded)
  (check-equal? (length (oh-open oh)) 1)
  ;; Repeated Focus-off command does not re-emit or fabricate a new cue.
  (orchestrator-set-quiet! (orch-harness-o oh) #f)
  (check-equal? (length (oh-cues oh)) 2))

;; Already-acknowledged reminders are settled and must NOT be replayed by
;; Focus/resume. Hiding a cue also never implies completion.
(let ([oh (make-oh #:sit 300 #:water 10)])
  (oh-step-minutes! oh 10)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-acknowledge-cue! (orch-harness-o oh) id)
  (orchestrator-set-quiet! (orch-harness-o oh) #t)
  (orchestrator-set-quiet! (orch-harness-o oh) #f)
  (check-equal? (length (oh-cues oh)) 1)
  (check-equal? (length (oh-open oh)) 0))

;; --- host capability inputs -------------------------------------------------

;; An unsupported character surface degrades to a non-blocking notification.
(let ([oh (make-oh #:sit 10)])
  (orchestrator-set-host-capability!
   (orch-harness-o oh) #:surface-supported? #f)
  (oh-step-minutes! oh 10)
  (check-equal? (companion-cue-delivery (cue-record-planned (oh-last-cue oh)))
                'notification))

;; OS Reduce Motion forces a static cue; so does the in-app motion toggle.
(let ([oh (make-oh #:sit 10)])
  (orchestrator-set-host-capability!
   (orch-harness-o oh) #:reduce-motion? #t)
  (oh-step-minutes! oh 10)
  (check-false (companion-cue-animated? (cue-record-planned (oh-last-cue oh)))))
(let ([oh (make-oh #:sit 10)])
  (set-scheduler-config!
   (h-scheduler (orch-harness-h oh))
   (struct-copy reminder-config (h-config (orch-harness-h oh))
                [motion-enabled #f]))
  (oh-step-minutes! oh 10)
  (check-equal? (companion-cue-delivery (cue-record-planned (oh-last-cue oh)))
                'character)
  (check-false (companion-cue-animated? (cue-record-planned (oh-last-cue oh)))))

;; --- unchanged orchestration contracts --------------------------------------

;; Stats flush fires on every 10th tick (~5 minutes at 30 s ticks).
(let ([oh (make-oh #:sit 300 #:water 300)])
  (oh-step-minutes! oh 20 2) ; 10 ticks of 2 minutes
  (check-equal? (unbox (orch-harness-flushes oh)) 1)
  (oh-step-minutes! oh 20 2) ; another 10 ticks
  (check-equal? (unbox (orch-harness-flushes oh)) 2))

;; Orchestrator-flush! flushes on demand (host exit / update restart).
(let ([oh (make-oh #:sit 300 #:water 300)])
  (orchestrator-flush! (orch-harness-o oh))
  (check-equal? (unbox (orch-harness-flushes oh)) 1))

;; Pause from the tray action: 1 hour, session reset.
(let ([oh (make-oh #:sit 300 #:water 300)])
  (oh-step-minutes! oh 30)
  (orchestrator-pause-1h! (orch-harness-o oh))
  (check-true (h-paused? (orch-harness-h oh)))
  (check-equal? (h-session-ms (orch-harness-h oh)) 0)
  (orchestrator-resume! (orch-harness-o oh))
  (check-false (h-paused? (orch-harness-h oh))))

;; The celebration decision stays a pure boundary check.
(check-true (should-celebrate? 3))
(check-false (should-celebrate? 4))
(check-true (should-celebrate? 5))
(check-false (should-celebrate? 7))
(check-true (should-celebrate? 8))
(check-false (should-celebrate? 9))
(check-false (should-celebrate? 0))
