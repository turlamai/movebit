#lang racket/base

;; MoveBit v1 first product contract: one useful HEALTH reminder, not a pet
;; event. Pure tests exercise policy without a host/window or real clock.

(require rackunit
         "../movebit/companion-cue.rkt")

;; New product default is a character-delivered, actionable water reminder.
;; There is no opt-in compatibility path from the experimental v0.x.
(let ([cue (plan-companion-cue '(water))])
  (check-equal? (companion-cue-kinds cue) '(water))
  (check-equal? (companion-cue-action cue) 'drink-water)
  (check-equal? (companion-cue-gesture cue) 'water)
  (check-equal? (companion-cue-delivery cue) 'character)
  (check-true (companion-cue-animated? cue)))

;; Every visual hint must have a clear real-world health action.
(let ([cue (plan-companion-cue '(sit))])
  (check-equal? (companion-cue-action cue) 'stand-and-stretch)
  (check-equal? (companion-cue-gesture cue) 'stretch))
(let ([cue (plan-companion-cue '(micro))])
  (check-equal? (companion-cue-action cue) 'rest-eyes)
  (check-equal? (companion-cue-gesture cue) 'blink))

;; A merged scheduler event produces exactly one cue, deterministic priority,
;; and preserves EVERY due kind for downstream Done/Later behavior.
(let ([cue (plan-companion-cue '(micro water sit water))])
  (check-equal? (companion-cue-kinds cue) '(sit water micro))
  (check-equal? (companion-cue-action cue) 'stand-and-stretch)
  (check-equal? (companion-cue-delivery cue) 'character))
(let ([cue (plan-companion-cue '(micro water))])
  (check-equal? (companion-cue-kinds cue) '(water micro))
  (check-equal? (companion-cue-action cue) 'drink-water))

;; Presentation/Focus mode suppresses UI, NOT real reminder state.
(let ([cue (plan-companion-cue '(sit water) #:quiet? #t)])
  (check-equal? (companion-cue-kinds cue) '(sit water))
  (check-equal? (companion-cue-action cue) 'stand-and-stretch)
  (check-equal? (companion-cue-delivery cue) 'quiet)
  (check-false (companion-cue-animated? cue)))

;; An incapable compositor must get a non-blocking native notification
;; rather than a bogus interactive overlay or full-screen interruption.
(let ([cue (plan-companion-cue '(water)
                               #:surface-supported? #f)])
  (check-equal? (companion-cue-delivery cue) 'notification)
  (check-equal? (companion-cue-action cue) 'drink-water)
  (check-false (companion-cue-animated? cue)))

;; Reduce Motion still delivers the health suggestion as a static visual.
(let ([cue (plan-companion-cue '(micro) #:reduce-motion? #t)])
  (check-equal? (companion-cue-delivery cue) 'character)
  (check-equal? (companion-cue-action cue) 'rest-eyes)
  (check-false (companion-cue-animated? cue)))

(check-false (plan-companion-cue '()))
(check-exn exn:fail:contract?
           (lambda () (plan-companion-cue '(unknown))))
(check-exn exn:fail:contract?
           (lambda () (plan-companion-cue "water")))
(check-exn exn:fail:contract?
           (lambda () (plan-companion-cue '(water) #:quiet? 'maybe)))
(check-exn exn:fail:contract?
           (lambda () (plan-companion-cue '(water) #:surface-supported? 'maybe)))
(check-exn exn:fail:contract?
           (lambda () (plan-companion-cue '(water) #:reduce-motion? 'maybe)))

;; The ledger bound is bookkeeping only (issue #140): invitations persist
;; until answered in a live session; this closes stale-session entries.
(check-true (> ledger-expiry-ms 0))
(check-equal? ledger-expiry-ms (* 24 60 60 1000))
