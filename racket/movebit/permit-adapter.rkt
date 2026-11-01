#lang racket/base

;; Optional Permit integration, isolated from the Free application build.
;; The calling product must ship a pinned Permit runtime and an authenticated,
;; application-owned PUBLIC trust store before enabling Pro licensing.
;;
;; Checkout redirects, client-provided payment state, unverified claims, and
;; user-selected trust stores are NEVER authorization evidence. Issuer private
;; keys stay in the isolated Commerce signing service.
;;
;; This module is not imported by backend.rkt until the product has a
;; reviewed Pro feature policy and cross-host acceptance.

(require "commercial-policy.rkt")

(provide permit-feature-available?
         permit-feature-available/from-file?)

;; Keep free builds free from a mandatory Permit package dependency.
;; Loading Permit or its native Ed25519 runtime may fail: paid rights then
;; fail closed without disabling reminders, existing history, or recovery.
(define (permit-client-api)
  (values (dynamic-require 'permit 'verified-credential?)
          (dynamic-require 'permit 'edition-entitled?)
          (dynamic-require 'permit 'feature-entitled?)
          (dynamic-require 'permit 'verify-credential)
          (dynamic-require 'permit 'trust-store?)))

;; Caller context matters: a verified signature alone is insufficient when
;; Permit rights constrain product version, installation, or activation.
;; Omitted context cannot satisfy a constraint. An activation credential must
;; itself have been signature-verified with the application's trusted store.
(define (permit-feature-available? feature credential
                                   #:version [version #f]
                                   #:installation-id [installation-id #f]
                                   #:activation [activation #f]
                                   #:published-at [published-at #f])
  (cond
    [(free-feature? feature) #t]
    [(not (pro-feature? feature)) #f]
    [else
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (define-values (verified? edition? feature? _verify _store?)
         (permit-client-api))
       (and (verified? credential)
            (or (edition? credential movebit-product-id "pro"
                          #:version version
                          #:installation-id installation-id
                          #:activation activation)
                (feature? credential movebit-product-id
                          (symbol->string feature)
                          #:published-at published-at
                          #:version version
                          #:installation-id installation-id
                          #:activation activation))
            #t))]))

;; A single persisted-license entrypoint: verify exact signed payload bytes
;; against an application-owned public trust store before policy evaluation.
;; This interface deliberately does not load trust roots from a user path.
(define (permit-feature-available/from-file? feature credential-source trusted-store
                                             #:version [version #f]
                                             #:installation-id [installation-id #f]
                                             #:activation [activation #f]
                                             #:published-at [published-at #f])
  (cond
    [(free-feature? feature) #t]
    [(not (pro-feature? feature)) #f]
    [else
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (define-values (_verified _edition _feature verify store?)
         (permit-client-api))
       (and (store? trusted-store)
            (permit-feature-available?
             feature
             (verify credential-source trusted-store)
             #:version version
             #:installation-id installation-id
             #:activation activation
             #:published-at published-at)))]))
