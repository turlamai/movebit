#lang racket/base

;; Tests for the v1 cue lifecycle: same-tick merge rule, the explicit
;; pending → displayed → acknowledged | snoozed | dismissed transitions,
;; PERSISTENT invitations with the supersede merge (issue #140), quiet
;; queuing with its bounded summary, ledger bookkeeping and host capability
;; inputs. Pinned so every host shell gets identical reminder behavior.

(require rackunit
         "harness.rkt"
         "../movebit/companion-cue.rkt"
         "../movebit/orchestrator.rkt"
         "../movebit/scheduler.rkt")

(define minute-ms 60000)

(struct orch-harness (h o cues flushes outcomes) #:transparent)

;; Build a scheduler harness plus its orchestrator with a recording on-cue
;; and a recording on-outcome (issue #88). The rhythm is the fixed product
;; cadence: micro fires at 20/40/60/80... active minutes, sit at 50/100...,
;; water at 60/120...
(define (make-oh)
  (define h (make-harness))
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

;; A micro-only tick stays its own cue with the eye-rest action.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(micro))
  (check-equal? (companion-cue-action (cue-record-planned (oh-last-cue oh)))
                'rest-eyes)
  (check-equal? (companion-cue-gesture (cue-record-planned (oh-last-cue oh)))
                'blink)
  (check-equal? (companion-cue-delivery (cue-record-planned (oh-last-cue oh)))
                'character)
  (check-true (companion-cue-animated? (cue-record-planned (oh-last-cue oh)))))

;; Water + micro due on the same tick merge into ONE cue; the character
;; gesture carries the highest-priority kind's meaning. (The 50-minute sit
;; invitation is answered first so the fresh pair stays sit-free.)
(let ([oh (make-oh)])
  (oh-step-minutes! oh 50)
  (orchestrator-acknowledge-cue! (orch-harness-o oh)
                                 (cue-record-id (oh-last-cue oh)))
  (oh-step-minutes! oh 10)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(water micro))
  (check-equal? (companion-cue-action (cue-record-planned (oh-last-cue oh)))
                'drink-water))

;; Separate ticks produce separate cues with monotone ids.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(micro))
  (oh-step-minutes! oh 20)
  (check-equal? (length (oh-cues oh)) 2)
  (check-true (< (cue-record-id (car (oh-cues oh)))
                 (cue-record-id (cadr (oh-cues oh))))))

;; --- persistence + supersede merge (issue #140) ------------------------------

;; A reminder firing while an invitation is still open FOLDS INTO it: one
;; merged cue, kinds union, superseded entries report no outcome, and the
;; ledger keeps exactly one open invitation. The union snowballs until the
;; user answers — the screen always holds exactly one Mubi.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 60)
  ;; c1 (micro@20) superseded by c2 (micro@40), c3 (sit+micro@50), then
  ;; c4 (sit+water+micro@60): four emissions, one open invitation.
  (check-equal? (length (oh-cues oh)) 4)
  (define c4 (oh-last-cue oh))
  (check-equal? (cue-record-kinds c4) '(sit water micro))
  (check-equal? (companion-cue-action (cue-record-planned c4))
                'stand-and-stretch)
  (check-equal? (length (oh-open oh)) 1)
  (check-eq? (car (oh-open oh)) c4)
  (for ([c (in-list (oh-cues oh))] #:unless (eq? c c4))
    (check-equal? (cue-record-status
                   (orchestrator-find-cue (orch-harness-o oh) (cue-record-id c)))
                  'superseded))
  ;; supersede fires NO outcome events: kinds were presented and carried
  ;; forward, never settled behind the user's back
  (check-equal? (oh-outcomes oh) '()))

;; An answered invitation ends the snowball: the next reminder starts fresh.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
  (orchestrator-acknowledge-cue! (orch-harness-o oh)
                                 (cue-record-id (oh-last-cue oh)))
  (check-equal? (length (oh-open oh)) 0)
  (oh-step-minutes! oh 20)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(micro))
  (check-equal? (length (oh-open oh)) 1))

;; --- lifecycle: pending → displayed → settled -------------------------------
;; Transitions are functional (the ledger stores the new value); assertions
;; re-find the record by id, exactly like the wire host does.

;; Displayed is a host report, idempotent, and unknown ids are no-ops.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
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

;; Done on a sit-bearing cue: acknowledged, session ends, the celebration
;; counter advances; stats are NOT touched by an acknowledgment.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 50)
  (check-not-false (memq 'sit (cue-record-kinds (oh-last-cue oh))))
  (define id (cue-record-id (oh-last-cue oh)))
  (check-equal? (h-session-ms (orch-harness-h oh)) (* 50 minute-ms))
  (check-equal? (day-stats-sit-reminders (h-stats (orch-harness-h oh))) 1)
  (orchestrator-acknowledge-cue! (orch-harness-o oh) id)
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'acknowledged)
  (check-equal? (length (oh-open oh)) 0)
  (check-equal? (h-session-ms (orch-harness-h oh)) 0)
  (check-equal? (orchestrator-sit-acks-today (orch-harness-o oh)) 1)
  (check-equal? (day-stats-sit-reminders (h-stats (orch-harness-h oh))) 1))

;; Done on a micro-only cue does NOT end the counted sitting session.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
  (orchestrator-acknowledge-cue! (orch-harness-o oh) (cue-record-id (oh-last-cue oh)))
  (check-equal? (h-session-ms (orch-harness-h oh)) (* 20 minute-ms))
  (check-equal? (orchestrator-sit-acks-today (orch-harness-o oh)) 0))

;; Milestones fire at exactly 3/5/8 acknowledged sit cues per day. With the
;; fixed cadence a sit cue arrives every 50 active minutes; answering the
;; latest cue each time also settles the snowball.
(let ([oh (make-oh)])
  (let loop ([n 0])
    (when (< n 3)
      (oh-step-minutes! oh 50)
      (orchestrator-acknowledge-cue!
       (orch-harness-o oh) (cue-record-id (oh-last-cue oh)))
      (loop (add1 n))))
  (check-equal? (orchestrator-sit-acks-today (orch-harness-o oh)) 3)
  (check-true (should-celebrate? (orchestrator-sit-acks-today (orch-harness-o oh))))
  ;; the 4th ack is between milestones
  (oh-step-minutes! oh 50)
  (orchestrator-acknowledge-cue!
   (orch-harness-o oh) (cue-record-id (oh-last-cue oh)))
  (check-false (should-celebrate? (orchestrator-sit-acks-today (orch-harness-o oh)))))

;; Later on a merged cue defers EVERY merged kind by the fixed snooze
;; (10 active minutes): accumulators jump to interval - snooze.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 50)
  (define id (cue-record-id (oh-last-cue oh)))
  (check-equal? (cue-record-kinds (orchestrator-find-cue (orch-harness-o oh) id))
                '(sit micro))
  (orchestrator-snooze-cue! (orch-harness-o oh) id)
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'snoozed)
  (check-equal? (length (oh-open oh)) 0)
  ;; snooze = interval - snooze: sit accumulates at 40, so no sit re-fire
  ;; within the next 9 active minutes, then it re-fires right after.
  (define sit-fires-at-snooze (day-stats-sit-reminders (h-stats (orch-harness-h oh))))
  (oh-step-minutes! oh 9 1)
  (check-equal? (day-stats-sit-reminders (h-stats (orch-harness-h oh)))
                sit-fires-at-snooze)
  (oh-step-minutes! oh 2 1)
  (check-equal? (day-stats-sit-reminders (h-stats (orch-harness-h oh)))
                (add1 sit-fires-at-snooze)))

;; Hide ends the cue WITHOUT claiming completion and without deferring:
;; the kind re-fires on its normal full interval, not after a snooze.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 50)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-dismiss-cue! (orch-harness-o oh) id)
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'dismissed)
  (check-equal? (length (oh-open oh)) 0)
  (check-equal? (h-session-ms (orch-harness-h oh)) (* 50 minute-ms))
  ;; normal schedule: no sit fires until the full 50-minute interval elapses
  (oh-step-minutes! oh 49 1)
  (check-false
   (for/or ([c (in-list (oh-cues oh))])
     (and (memq 'sit (cue-record-kinds c))
          (> (cue-record-created-ms c) (cue-record-created-ms
                                        (orchestrator-find-cue (orch-harness-o oh) id))))))
  (oh-step-minutes! oh 1 1)
  (check-true
   (for/or ([c (in-list (oh-cues oh))])
     (and (memq 'sit (cue-record-kinds c))
          (> (cue-record-created-ms c) (cue-record-created-ms
                                        (orchestrator-find-cue (orch-harness-o oh) id)))))))

;; --- persistence: no visual expiry, day-scale bookkeeping --------------------

;; An invitation STAYS OPEN well past the old ten-minute window: ignoring it
;; is not an answer, the reminder keeps waiting (issue #140). (Steps stop
;; before minute 40, when the next micro fire would supersede-merge — that
;; path is pinned by the snowball test above.)
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (oh-step-minutes! oh 9 1)
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'displayed)
  (check-equal? (length (oh-open oh)) 1)
  (oh-step-minutes! oh 10 1)
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'displayed))

;; Bookkeeping only: an open entry older than a full day (a stale session)
;; closes as 'expired so the ledger stays bounded. Never reachable in a
;; live session.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (oh-step! oh (* 24 60 minute-ms))
  (check-equal? (cue-record-status (orchestrator-find-cue (orch-harness-o oh) id))
                'expired)
  (check-equal? (oh-outcomes oh) '((micro presented) (micro expired))))

;; --- outcome events (issue #88): presentation ≠ response ≠ timeout ----------

;; The full delivery/response path: presenting a merged cue reports one
;; 'presented per kind; Done reports 'self-reported-done; neither implies
;; more than the user actually did.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 60)
  (define id (cue-record-id (oh-last-cue oh)))
  (check-equal? (oh-outcomes oh) '()) ; pending, not yet on screen
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (check-equal? (oh-outcomes oh)
                '((sit presented) (water presented) (micro presented)))
  (orchestrator-acknowledge-cue! (orch-harness-o oh) id)
  (check-equal? (oh-outcomes oh)
                '((sit presented) (water presented) (micro presented)
                  (sit self-reported-done) (water self-reported-done)
                  (micro self-reported-done))))

;; Later reports its own terminal, distinct from a timeout (oldest first).
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (orchestrator-snooze-cue! (orch-harness-o oh) id)
  (check-equal? (oh-outcomes oh)
                '((micro presented) (micro snoozed))))

;; Hide reports 'dismissed, again distinct from a timeout.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (orchestrator-dismiss-cue! (orch-harness-o oh) id)
  (check-equal? (oh-outcomes oh)
                '((micro presented) (micro dismissed))))

;; Stopping a guided session is 'abandoned — not Hide, not Done.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-cue-displayed! (orch-harness-o oh) id)
  (orchestrator-abandon-cue! (orch-harness-o oh) id)
  (check-equal? (oh-outcomes oh)
                '((micro presented) (micro abandoned))))

;; --- quiet mode: queue, never emit; bounded summary on exit -----------------

;; While quiet, a due reminder creates a pending ledger entry and emits
;; NOTHING; leaving quiet emits ONE summary cue carrying the union of kinds.
(let ([oh (make-oh)])
  (orchestrator-set-quiet! (orch-harness-o oh) #t)
  (oh-step-minutes! oh 20)
  (check-equal? (oh-cues oh) '())
  (check-equal? (length (oh-open oh)) 1)
  (orchestrator-set-quiet! (orch-harness-o oh) #f)
  (check-equal? (length (oh-cues oh)) 1)
  (define summary (oh-last-cue oh))
  (check-equal? (cue-record-kinds summary) '(micro))
  (check-equal? (companion-cue-delivery (cue-record-planned summary)) 'character)
  (check-equal? (length (oh-open oh)) 1)
  (check-eq? (car (oh-open oh)) summary))

;; The summary is bounded: every quiet moment collapses into one cue whose
;; kinds are the priority-ordered union.
(let ([oh (make-oh)])
  (orchestrator-set-quiet! (orch-harness-o oh) #t)
  (oh-step-minutes! oh 60)
  (check-equal? (oh-cues oh) '())
  (check-true (>= (length (oh-open oh)) 1))
  (orchestrator-set-quiet! (orch-harness-o oh) #f)
  (check-equal? (length (oh-cues oh)) 1)
  (check-equal? (cue-record-kinds (oh-last-cue oh)) '(sit water micro)))

;; Long meetings do NOT expire a reminder that was never shown. The core
;; preserves its meaning for one merged invite after Focus ends, no matter
;; how long the meeting ran.
(let ([oh (make-oh)])
  (orchestrator-set-quiet! (orch-harness-o oh) #t)
  (oh-step-minutes! oh 20 5)
  (check-true (>= (length (oh-open oh)) 1))
  (oh-step-minutes! oh 30 3)
  (check-true (>= (length (oh-open oh)) 1)) ; still deferred, not silently lost
  (orchestrator-set-quiet! (orch-harness-o oh) #f)
  (check-equal? (length (oh-cues oh)) 1)
  (check-not-false (memq 'micro (cue-record-kinds (oh-last-cue oh))))
  (check-equal? (length (oh-open oh)) 1))

;; Entering Focus while an already-displayed cue is visible removes it from
;; presentation, rather than "taking it as seen". A late native delivered
;; callback must not consume it while Focus is on. One new invitation on exit.
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
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
  (check-equal? (cue-record-kinds summary) '(micro))
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
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20)
  (define id (cue-record-id (oh-last-cue oh)))
  (orchestrator-acknowledge-cue! (orch-harness-o oh) id)
  (orchestrator-set-quiet! (orch-harness-o oh) #t)
  (orchestrator-set-quiet! (orch-harness-o oh) #f)
  (check-equal? (length (oh-cues oh)) 1)
  (check-equal? (length (oh-open oh)) 0))

;; --- host capability inputs -------------------------------------------------

;; An unsupported character surface degrades to a non-blocking notification.
(let ([oh (make-oh)])
  (orchestrator-set-host-capability!
   (orch-harness-o oh) #:surface-supported? #f)
  (oh-step-minutes! oh 20)
  (check-equal? (companion-cue-delivery (cue-record-planned (oh-last-cue oh)))
                'notification))

;; OS Reduce Motion forces a static cue.
(let ([oh (make-oh)])
  (orchestrator-set-host-capability!
   (orch-harness-o oh) #:reduce-motion? #t)
  (oh-step-minutes! oh 20)
  (check-false (companion-cue-animated? (cue-record-planned (oh-last-cue oh)))))

;; --- unchanged orchestration contracts --------------------------------------

;; Stats flush fires on every 10th tick (~5 minutes at 30 s ticks).
(let ([oh (make-oh)])
  (oh-step-minutes! oh 20 2) ; 10 ticks of 2 minutes
  (check-equal? (unbox (orch-harness-flushes oh)) 1)
  (oh-step-minutes! oh 20 2) ; another 10 ticks
  (check-equal? (unbox (orch-harness-flushes oh)) 2))

;; Orchestrator-flush! flushes on demand (host exit / update restart).
(let ([oh (make-oh)])
  (orchestrator-flush! (orch-harness-o oh))
  (check-equal? (unbox (orch-harness-flushes oh)) 1))

;; Pause from the tray action: 1 hour, session reset.
(let ([oh (make-oh)])
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
