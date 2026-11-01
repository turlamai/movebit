#lang racket/base

;; Optional, client-side Permit adapter. The app must bundle Permit and a
;; trusted issuer public-key store before enabling any Pro functionality.
;; Never load provider credentials or signing material here.
;;
;; This module is intentionally not imported by backend.rkt until the
;; commercial feature set and deployment policy are approved.

(require permit
         "commercial-policy.rkt")

(provide permit-feature-available?)

;; Only a verified credential object may reach policy evaluation.
;; Every signature, trust, issuer, wrong-product, expiration and other
;; authorization error is a negative decision, never a checkout-based grant.
;; Callers choose how/where to load a public trust store and credential.
(define (permit-feature-available? feature credential)
  (cond
    [(free-feature? feature) #t]
    [(not (pro-feature? feature)) #f]
    [(not (verified-credential? credential)) #f]
    [else
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (and (credential-usable? credential)
            (feature-entitled? credential
                               movebit-product-id
                               (symbol->string feature))
            #t))]))
