#lang racket/base

;; Real Ed25519/Permit integration proof with ephemeral, TEST-ONLY issuer keys.
;; No key, credential or payment fixture is shipped with the application.

(require rackunit
         racket/file
         racket/path
         json
         (prefix-in issuer: permit/issuer)
         permit
         "../racket/movebit/permit-adapter.rkt")

(define-values (test-private test-public)
  (issuer:generate-ed25519-keypair))

(define test-store
  (issuer:jsexpr->trust-store
   (hasheq 'protocol "permit-trust-store"
           'version 1
           'issuer "movebit-ci-test"
           'keys
           (hasheq 'test-only
                   (hasheq 'algorithm "Ed25519"
                           'status "active"
                           'public_key (issuer:public-key->base64 test-public)
                           'purposes '("entitlement")
                           'not_before 'null
                           'not_after 'null)))))

(define (write-test-right path #:product [product "movebit"]
                          #:edition [edition "pro"]
                          #:features [features '()]
                          #:expires [expires 'null]
                          #:installation-id [installation-id 'null]
                          #:version-min [version-min 'null])
  (define claims
    (issuer:entitlement-payload
     #:issuer "movebit-ci-test"
     #:credential-id (path->string (file-name-from-path path))
     #:entitlement-id "test-entitlement"
     #:subject (issuer:subject #:type "person" #:id "ci-only")
     #:grants (list (issuer:grant #:products (list product)
                                 #:edition edition
                                 #:features features))
     #:constraints (issuer:constraints #:use-expires-at expires
                                       #:installation-id installation-id
                                       #:version-min version-min)
     #:issued-at "2026-01-01T00:00:00Z"))
  (issuer:write-issued-credential
   (issuer:issue-credential (issuer:payload->bytes claims)
                            test-private
                            "test-only"
                            test-store)
   path))

(define dir (make-temporary-file "movebit-permit-ci-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (define pro (build-path dir "valid-pro.json"))
   (define feature (build-path dir "feature-only.json"))
   (define other (build-path dir "wrong-product.json"))
   (define expired (build-path dir "expired.json"))
   (define device-bound (build-path dir "device-bound.json"))
   (define version-bound (build-path dir "version-bound.json"))
   (define tampered (build-path dir "tampered.json"))
   (write-test-right pro)
   (write-test-right feature
                     #:edition 'null
                     #:features '("advanced-work-insights"))
   (write-test-right other #:product "another-product")
   (write-test-right expired #:expires "2026-01-02T00:00:00Z")
   (write-test-right device-bound #:installation-id "different-installation")
   (write-test-right version-bound #:version-min "1.0.0")

   ;; A real signed license is verified and evaluated; raw claims or a
   ;; browser checkout result can never be passed through as authorization.
   (check-true (permit-feature-available/from-file?
                'advanced-work-insights pro test-store))
   (check-true (permit-feature-available/from-file?
                'advanced-character-customization pro test-store))
   (check-true (permit-feature-available/from-file?
                'advanced-work-insights feature test-store))
   (check-false (permit-feature-available/from-file?
                 'advanced-character-customization feature test-store))
   (check-false (permit-feature-available? 'advanced-work-insights #t))
   (check-false (permit-feature-available? 'advanced-work-insights
                                          (hasheq 'paid #t)))
   (check-false (permit-feature-available/from-file?
                 'advanced-work-insights other test-store))
   (check-false (permit-feature-available/from-file?
                 'advanced-work-insights expired test-store))
   ;; Version- and installation-bound rights cannot be accepted without
   ;; the required product context. A future paid host must supply both.
   (check-false (permit-feature-available/from-file?
                 'advanced-work-insights device-bound test-store))
   (check-false (permit-feature-available/from-file?
                 'advanced-work-insights version-bound test-store))
   ;; Correct product context authorizes a valid bound entitlement. A
   ;; different device or an older version cannot substitute.
   (check-true (permit-feature-available/from-file?
                'advanced-work-insights device-bound test-store
                #:installation-id "different-installation"))
   (check-false (permit-feature-available/from-file?
                 'advanced-work-insights device-bound test-store
                 #:installation-id "wrong-installation"))
   (check-true (permit-feature-available/from-file?
                'advanced-work-insights version-bound test-store
                #:version "1.1.0"))
   (check-false (permit-feature-available/from-file?
                 'advanced-work-insights version-bound test-store
                 #:version "0.0.3"))
   (check-false (permit-feature-available/from-file?
                 'advanced-work-insights version-bound test-store
                 #:version "invalid-version"))
   (check-false (permit-feature-available/from-file?
                 'advanced-work-insights (build-path dir "missing.json")
                 test-store))
   (check-false (permit-feature-available/from-file?
                 'advanced-work-insights pro #f))
   (check-false (permit-feature-available/from-file?
                 'unknown-feature pro test-store))

   ;; Change the signature WITHOUT re-signing; the verifier must refuse it.
   (define envelope (call-with-input-file pro read-json))
   (call-with-output-file tampered #:exists 'truncate
     (lambda (out)
       (write-json (hash-set envelope 'signature (make-string 88 (integer->char 65))) out)))
   (check-false (permit-feature-available/from-file?
                 'advanced-work-insights tampered test-store))

   ;; Free functions survive missing, invalid, expired and wrong-product
   ;; credentials. This is a product policy guarantee, not a trial.
   (for ([license (list #f pro expired other tampered)])
     (check-true (permit-feature-available/from-file?
                  'water-reminder license test-store))
     (check-true (permit-feature-available/from-file?
                  'existing-history license test-store))
     (check-true (permit-feature-available/from-file?
                  'recovery license test-store))))
 (lambda () (delete-directory/files dir)))
