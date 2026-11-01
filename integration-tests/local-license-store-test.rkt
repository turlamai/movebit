#lang racket/base

;; TEST ONLY. Real Ed25519 signature verification with ephemeral issuer keys;
;; no production key or commercial offer is committed or enabled.
(require rackunit
         racket/file
         racket/path
         (prefix-in issuer: permit/issuer)
         "../racket/movebit/license-store.rkt")

(define-values (private-key public-key)
  (issuer:generate-ed25519-keypair))
(define trust
  (issuer:jsexpr->trust-store
   (hasheq 'protocol "permit-trust-store"
           'version 1
           'issuer "movebit-local-vault-ci"
           'keys
           (hasheq 'test-only
                   (hasheq 'algorithm "Ed25519"
                           'status "active"
                           'public_key (issuer:public-key->base64 public-key)
                           'purposes '("entitlement")
                           'not_before 'null
                           'not_after 'null)))))

(define root (make-temporary-file "movebit-license-ci-~a" 'directory))
(define machine-dir (build-path root "machine-local"))

(define (issue-test-license path
                            #:product [product "movebit"]
                            #:edition [edition "pro"]
                            #:revision [revision 0]
                            #:credential-id [credential-id "ci-original"]
                            #:expires [expires 'null]
                            #:version-min [version-min 'null])
  (define payload
    (issuer:entitlement-payload
     #:issuer "movebit-local-vault-ci"
     #:credential-id credential-id
     #:entitlement-id "ci-lineage"
     #:revision revision
     #:subject (issuer:subject #:type "person" #:id "ci-only")
     #:grants (list (issuer:grant
                     #:products (list product)
                     #:edition edition))
     #:constraints (issuer:constraints #:use-expires-at expires
                                       #:version-min version-min)
     #:issued-at "2026-01-01T00:00:00Z"))
  (issuer:write-issued-credential
   (issuer:issue-credential (issuer:payload->bytes payload)
                            private-key "test-only" trust)
   path))

(dynamic-wind
 void
 (lambda ()
   (define v0 (build-path root "v0.json"))
   (define v1 (build-path root "v1.json"))
   (define withdrawn (build-path root "withdrawn.json"))
   (define oversized (build-path root "oversized.json"))
   (define wrong-product (build-path root "other.json"))
   (define expired (build-path root "expired.json"))
   (define wrong-version (build-path root "version.json"))
   (define conflicting (build-path root "conflicting.json"))
   (define invalid (build-path root "invalid.json"))
   (issue-test-license v0)
   (issue-test-license v1 #:revision 1 #:credential-id "ci-updated")
   ;; Newer verified successor removes Pro entitlement (mock refund).
   (issue-test-license withdrawn #:revision 2
                       #:credential-id "ci-withdrawn"
                       #:expires "2026-02-01T00:00:00Z")
   (call-with-output-file oversized
     (lambda (out) (write-bytes (make-bytes 131073 65) out)))
   (issue-test-license wrong-product #:product "not-movebit")
   (issue-test-license expired #:expires "2026-02-01T00:00:00Z")
   (issue-test-license wrong-version #:version-min "99.0.0")
   (issue-test-license conflicting #:credential-id "ci-conflicting")
   (call-with-output-file invalid
     (lambda (out) (display "{\"checkout\":\"success\"}" out)))

   (check-equal? (local-license-status trust #:local-dir machine-dir)
                 (hasheq 'tier "free" 'status "missing"))
   (check-false (import-signed-license! invalid trust #:local-dir machine-dir))
   (check-false (import-signed-license! oversized trust #:local-dir machine-dir))
   (check-false (import-signed-license! wrong-product trust #:local-dir machine-dir))
   (check-false (import-signed-license! expired trust #:local-dir machine-dir))
   (check-false (import-signed-license! wrong-version trust #:local-dir machine-dir
                                        #:version "1.0.0"))
   (check-equal? (local-license-status trust #:local-dir machine-dir)
                 (hasheq 'tier "free" 'status "missing"))

   (check-true (import-signed-license! v0 trust #:local-dir machine-dir))
   (check-equal? (local-license-status trust #:local-dir machine-dir)
                 (hasheq 'tier "pro" 'status "active"))
   (check-equal? (file->bytes (license-file-path #:local-dir machine-dir))
                 (file->bytes v0))

   ;; A fake checkout must not erase an existing valid credential.
   (check-false (import-signed-license! invalid trust #:local-dir machine-dir))
   (check-false (import-signed-license! conflicting trust #:local-dir machine-dir))
   (check-equal? (file->bytes (license-file-path #:local-dir machine-dir))
                 (file->bytes v0))

   (check-true (import-signed-license! v1 trust #:local-dir machine-dir))
   (check-equal? (file->bytes (license-file-path #:local-dir machine-dir))
                 (file->bytes v1))
   ;; Once a newer signed lineage revision has been observed locally, no
   ;; reimported older copy may downgrade/undo that snapshot.
   (check-false (import-signed-license! v0 trust #:local-dir machine-dir))
   (check-equal? (file->bytes (license-file-path #:local-dir machine-dir))
                 (file->bytes v1))
   (check-equal? (local-license-status trust #:local-dir machine-dir)
                 (hasheq 'tier "pro" 'status "active"))

   ;; A verified newer withdrawal MUST be importable even though it does
   ;; not authorize Pro; otherwise a refunded offline right stays active.
   (check-true (import-signed-license! withdrawn trust
                                      #:local-dir machine-dir))
   (check-equal? (local-license-status trust #:local-dir machine-dir)
                 (hasheq 'tier "free" 'status "not-entitled"))
   (check-false (import-signed-license! v1 trust #:local-dir machine-dir))
   (check-equal? (file->bytes (license-file-path #:local-dir machine-dir))
                 (file->bytes withdrawn))

   ;; A user-controlled invalid trust root cannot turn signed rights on.
   (check-equal? (local-license-status #f #:local-dir machine-dir)
                 (hasheq 'tier "free" 'status "invalid"))
   (remove-local-license! #:local-dir machine-dir)
   (check-equal? (local-license-status trust #:local-dir machine-dir)
                 (hasheq 'tier "free" 'status "missing")))
 (lambda () (delete-directory/files root)))
