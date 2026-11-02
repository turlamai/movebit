#lang racket/base

(require rackunit racket/file racket/path "../movebit/license-store.rkt")

;; The normal domain test suite must work on all three host platforms with
;; no Permit dependency or signing keys; Free remains the default.
(define root (make-temporary-file "movebit-free-license-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (define invalid (build-path root "not-a-license.json"))
   (check-equal? (local-license-status #f #:local-dir root)
                 (hasheq 'tier "free" 'status "missing"))
   (check-equal? (license-file-path #:local-dir root)
                 (build-path root "license.permit.json"))
   (call-with-output-file invalid
     (lambda (out) (display "{\"paid\":true}" out)))
   (check-false (import-signed-license! invalid #f #:local-dir root))
   (check-equal? (local-license-status #f #:local-dir root)
                 (hasheq 'tier "free" 'status "missing"))
   (remove-local-license! #:local-dir root)
   (check-equal? (local-license-status #f #:local-dir root)
                 (hasheq 'tier "free" 'status "missing")))
 (lambda () (delete-directory/files root)))
