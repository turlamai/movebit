#lang racket/base

;; MoveBit v1: choose HOW to present an already-due health reminder.
;;
;; The core product is hydration, standing/movement and eye-rest reminders,
;; not a desktop pet. The scheduler/orchestrator still own all timing, merging,
;; pause, snooze, idle and statistics; these choices do not reset any timer.
;; The native host is responsible for safe surfaces, input pass-through,
;; labels, accessibility and presentation capability reporting.
;;
;; v0.x was an experiment with no real users: there is deliberately no legacy
;; presentation flag or compatibility mode. Character-style cues are the
;; first real product default. On unsupported platforms use a non-blocking
;; native notification rather than an interactive or fullscreen overlay.
;;
;; This module also owns the two presentation-side policies the reminder
;; contract requires to be EXPLICIT (issue #55):
;;   - cue-expiry-ms: an unacknowledged cue stops being current after this
;;     much wall-clock time. Expiry closes the ledger entry only — the fired
;;     reminder already restarted its cycle, so the next reminder arrives on
;;     the normal schedule. Silence never counts as completion.
;;   - summarize-open-cues: when Focus/presentation silence ends, the queued
;;     cues collapse into ONE bounded summary cue carrying the union of their
;;     kinds — never a pile-up of every missed moment.

(require racket/list)

(provide cue-expiry-ms
         (struct-out companion-cue)
         (struct-out open-cue)
         plan-companion-cue
         summarize-open-cues)

;; kinds:     ALL due kinds (priority order); preserve for snooze/actions
;; action:    semantic suggested health action, independent of appearance
;; gesture:   original visual rendering hint for the character
;; delivery:  'character | 'notification | 'quiet
;; animated?: static when Reduce Motion or presentation silence is selected
(struct companion-cue (kinds action gesture delivery animated?) #:transparent)

;; The orchestrator's ledger of an emitted-but-unsettled cue. status is
;; 'pending (not yet shown) or 'displayed (the host confirmed rendering).
;; settled outcomes (acknowledged / snoozed / expired) leave the open list.
(struct open-cue (id kinds status created-ms) #:transparent)

;; Ten minutes of no response closes the cue. Long enough to stay visible
;; through a meeting slide change, short enough that the character never
;; becomes furniture.
(define cue-expiry-ms (* 10 60 1000))

(define known-kinds '(sit water micro))

(define (plan-companion-cue kinds
                            #:quiet? [quiet? #f]
                            #:surface-supported? [surface-supported? #t]
                            #:reduce-motion? [reduce-motion? #f])
  (unless (and (list? kinds)
               (andmap (lambda (kind) (and (symbol? kind)
                                          (memq kind known-kinds)))
                       kinds))
    (raise-argument-error
     'plan-companion-cue "(listof (or/c 'sit 'water 'micro))" kinds))
  (unless (boolean? quiet?)
    (raise-argument-error 'plan-companion-cue "boolean?" quiet?))
  (unless (boolean? surface-supported?)
    (raise-argument-error 'plan-companion-cue "boolean?" surface-supported?))
  (unless (boolean? reduce-motion?)
    (raise-argument-error 'plan-companion-cue "boolean?" reduce-motion?))

  ;; Deterministic regardless of host event order; one already-merged event
  ;; results in one cue while all kinds remain available for the user action.
  (define ordered
    (filter (lambda (kind) (memq kind kinds)) known-kinds))
  (cond
    [(null? ordered) #f]
    [else
     (define-values (action gesture)
       (cond [(memq 'sit ordered) (values 'stand-and-stretch 'stretch)]
             [(memq 'water ordered) (values 'drink-water 'water)]
             [else (values 'rest-eyes 'blink)]))
     ;; Quiet merely controls presentation. It must never be used as proof
     ;; that the user completed a break or drank water; queue/expiry semantics
     ;; belong to the reminder engine, not the renderer.
     (define delivery
       (cond [quiet? 'quiet]
             [surface-supported? 'character]
             [else 'notification]))
     (companion-cue ordered
                    action
                    gesture
                    delivery
                    (and (eq? delivery 'character)
                         (not reduce-motion?)))]))

;; Collapse the open-cue ledger into at most ONE summary invitation:
;; the union of 'pending kinds, priority-ordered. On ENTERING Focus the
;; orchestrator retracts already-shown, still-open reminders back to 'pending
;; because native hosts now hide Mubi immediately; acknowledged/snoozed/hidden
;; events are settled and never replayed. A late "displayed" callback during
;; Focus is deliberately ignored.
;; Returns the summary kinds or #f when none need replay. The orchestrator
;; gives the re-invitation one fresh id and expires all superseded entries.
;; The visible timer and a long meeting NEVER fabricate a Done.
(define (summarize-open-cues entries)
  (unless (and (list? entries)
               (andmap open-cue? entries))
    (raise-argument-error 'summarize-open-cues "(listof open-cue?)" entries))
  (define kinds
    (filter (lambda (kind)
              (for/or ([e (in-list entries)])
                (and (eq? (open-cue-status e) 'pending)
                     (memq kind (open-cue-kinds e)))))
            known-kinds))
  (and (pair? kinds) kinds))
