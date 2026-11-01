#lang racket/base

;; Optional Permit integration, isolated from the Free application build.
;; The calling product must ship a pinned Permit runtime and an authenticated,
;; application-owned PUBLIC trust store before enabling Pro licensing.
;;
;; A downloaded checkout result, raw claims or a user-writable trust store
;; must NEVER count as proof of rights. The private issuer key belongs only
;; in Commerce's isolated signing environment.

(require "commercial-policy.rkt")

(provide permit-feature-available?
         permit-feature-available/from-file?)

;; Dynamic imports keep raco test racket/ and the Free host build independent
;; of Permit until a product explicitly opts into commercial authorization.
;; A missing/unsupported crypto runtime or package always denies paid access.
(define (permit-client-api)
  (values (dynamic-require 'permit 'verified-credential?)
          (dynamic-require 'permit 'edition-entitled?)
          (dynamic-require 'permit 'feature-entitled?)
          (dynamic-require 'permit 'verify-credential)
          (dynamic-require 'permit 'trust-store?)))

(define (permit-feature-available? feature credential)
  (cond
    [(free-feature? feature) #t]
    [(not (pro-feature? feature)) #f]
    [else
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (define-values (verified? edition? feature? _verify _store?)
         (permit-client-api))
       (and (verified? credential)
            ;; An explicit Pro edition or an explicit feature grant can
            ;; authorize one of the independently reviewed Pro feature IDs.
            ;; Permit evaluates validity, expiry, product and constraints.
            (or (edition? credential movebit-product-id "pro")
                (feature? credential movebit-product-id
                          (symbol->string feature)))
            #t))]))

(define (permit-feature-available/from-file? feature credential-source trusted-store)
  (cond
    [(free-feature? feature) #t]
    [(not (pro-feature? feature)) #f]
    [else
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (define-values (_verified _edition _feature verify store?)
         (permit-client-api))
       (and (store? trusted-store)
            ;; This is the only supported persisted-license path: signature
            ;; and trust verification BEFORE policy evaluation.
            (permit-feature-available?
             feature
             (verify credential-source trusted-store))))]))
