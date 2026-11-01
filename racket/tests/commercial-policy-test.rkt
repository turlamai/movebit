#lang racket/base
(require rackunit "../movebit/commercial-policy.rkt")

(check-equal? movebit-product-id "movebit")
(for ([feature '(water-reminder sit-reminder eye-rest-reminder
                  cue-done cue-later focus-mode reminder-settings
                  existing-history backup export recovery security-update)])
  (check-true (free-feature? feature))
  (check-true (feature-available? feature))
  (check-true (feature-available? feature #:permit-granted? #f)))

(for ([feature '(advanced-character-customization advanced-work-insights)])
  (check-true (pro-feature? feature))
  (check-false (feature-available? feature))
  (check-false (feature-available? feature #:permit-granted? 'paid))
  (check-true (feature-available? feature #:permit-granted? #t)))

(check-false (known-feature? 'unrecognized-feature))
(check-false (feature-available? 'unrecognized-feature #:permit-granted? #t))
(check-false (feature-available? "advanced-work-insights" #:permit-granted? #t))
