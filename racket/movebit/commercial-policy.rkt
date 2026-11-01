#lang racket/base

;; MoveBit's product-rights policy boundary. This module never signs or
;; interprets unverified license claims: callers may supply only a positive
;; decision from the Permit verifier. Payment status is not an entitlement.
;;
;; Shipping default is FREE. Premium feature IDs are reserved for separately
;; implemented capabilities; existing reminders, settings, histories and
;; recovery cannot be gated by a later change in commercial policy.

(provide movebit-product-id
         free-feature?
         pro-feature?
         feature-available?
         known-feature?)

(define movebit-product-id "movebit")

(define free-features
  '(water-reminder sit-reminder eye-rest-reminder
    cue-done cue-later focus-mode
    reminder-settings existing-history
    backup export recovery security-update))

;; Reserved identifiers, not claims that these features are implemented.
(define pro-features
  '(advanced-character-customization advanced-work-insights))

(define (free-feature? feature)
  (and (symbol? feature) (memq feature free-features) #t))

(define (pro-feature? feature)
  (and (symbol? feature) (memq feature pro-features) #t))

(define (known-feature? feature)
  (or (free-feature? feature) (pro-feature? feature)))

;; A Permit verifier must make the positive decision. Any unknown feature is
;; denied, and no runtime may treat redirect/success/payment UI as proof.
(define (feature-available? feature #:permit-granted? [granted? #f])
  (cond
    [(free-feature? feature) #t]
    [(pro-feature? feature) (eq? granted? #t)]
    [else #f]))
