#lang racket/base

;; Optional, LOCAL signed-credential store for the future MoveBit Pro edition.
;; Not imported by the Free backend or exposed over RVT1 until the product
;; approves live Pro capabilities and a package-owned trusted issuer key.
;;
;; Credentials are kept in the *machine-local* default app-data location,
;; not the user-selectable synchronized reminder/history directory.
;; Do not call this with a trust store supplied by the customer or checkout UI.

(require racket/file
         racket/path
         "commercial-policy.rkt"
         "permit-adapter.rkt"
         "paths.rkt")

(provide license-file-path
         local-license-status
         import-signed-license!
         remove-local-license!)

(define max-credential-size 131072)

(define (license-file-path #:local-dir [dir (default-data-dir)])
  (build-path dir "license.permit.json"))

;; Strictly bounded before parsing: never parse an unlimited downloaded file.
;; The very same immutable byte sequence is verified and later stored,
;; preventing a source-file replacement between verification and copying.
(define (read-credential-bytes path)
  (call-with-input-file
   path
   (lambda (in)
     (define raw (read-bytes (add1 max-credential-size) in))
     (unless (and (bytes? raw)
                  (positive? (bytes-length raw))
                  (<= (bytes-length raw) max-credential-size))
       (error 'read-credential-bytes "credential missing or exceeds size limit"))
     (bytes->immutable-bytes raw))))

(define (verified-from-bytes raw trusted-store)
  (define verify (dynamic-require 'permit 'verify-credential))
  (define valid-store? (dynamic-require 'permit 'trust-store?))
  (unless (valid-store? trusted-store)
    (error 'verified-from-bytes "no trusted public issuer store"))
  (verify (open-input-bytes raw) trusted-store))

(define (pro-allowed? credential #:version version #:installation-id installation-id)
  (for/or ([feature (in-list (pro-feature-ids))])
    (permit-feature-available? feature credential
                               #:version version
                               #:installation-id installation-id)))

;; Fixed, non-sensitive status vocabulary; never return raw claims, customer
;; identifiers, signed bytes, filesystem paths, or provider metadata to UI.
(define (local-license-status trusted-store
                              #:local-dir [dir (default-data-dir)]
                              #:version [version #f]
                              #:installation-id [installation-id #f])
  (define target (license-file-path #:local-dir dir))
  (cond
    [(not (file-exists? target))
     (hasheq 'tier "free" 'status "missing")]
    [else
     (with-handlers ([exn:fail? (lambda (_) (hasheq 'tier "free" 'status "invalid"))])
       (define credential
         (verified-from-bytes (read-credential-bytes target) trusted-store))
       (if (pro-allowed? credential
                         #:version version
                         #:installation-id installation-id)
           (hasheq 'tier "pro" 'status "active")
           (hasheq 'tier "free" 'status "not-entitled")))]))

;; Import a currently usable Pro right OR a newer verified withdrawal for an
;; existing entitlement lineage. A failed attempt never replaces a credential. A verified revision
;; for an existing entitlement lineage must not roll back: otherwise a user
;; could re-import an older locally cached right after an updated withdrawal.
;; This only constrains what THIS installation has already observed; a device
;; that never receives a withdrawal still cannot infer an offline revocation.
(define (import-signed-license! source trusted-store
                                #:local-dir [dir (default-data-dir)]
                                #:version [version #f]
                                #:installation-id [installation-id #f])
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (let* ([raw (read-credential-bytes source)]
           [candidate (verified-from-bytes raw trusted-store)]
           [target (license-file-path #:local-dir dir)]
           ;; An invalid old file may be replaced by a newly verified Pro
           ;; credential, but a valid newer lineage must not be rolled back.
           [prior
            (and (file-exists? target)
                 (with-handlers ([exn:fail? (lambda (_) #f)])
                   (let ([old-bytes (read-credential-bytes target)])
                     (cons old-bytes
                           (verified-from-bytes old-bytes trusted-store)))))]
           [issuer (dynamic-require 'permit 'verified-credential-issuer)]
           [entitlement-id
            (dynamic-require 'permit 'verified-credential-entitlement-id)]
           [subject-type
            (dynamic-require 'permit 'verified-credential-subject-type)]
           [subject-id
            (dynamic-require 'permit 'verified-credential-subject-id)]
           [revision (dynamic-require 'permit 'verified-credential-revision)]
           [same-lineage?
            (and prior
                 (equal? (issuer (cdr prior)) (issuer candidate))
                 (equal? (entitlement-id (cdr prior))
                         (entitlement-id candidate)))]
           [newer?
            (and same-lineage?
                 (> (revision candidate) (revision (cdr prior))))])
      (when same-lineage?
        ;; Even a signature-valid credential cannot silently transfer a
        ;; previously observed entitlement lineage to another subject. This
        ;; also constrains a newer withdrawal: otherwise another customer's
        ;; revocation could overwrite the local holder's still-valid right.
        (unless (and (equal? (subject-type (cdr prior))
                             (subject-type candidate))
                     (equal? (subject-id (cdr prior))
                             (subject-id candidate)))
          (error 'import-signed-license! "entitlement subject changed"))
        (when (or (< (revision candidate) (revision (cdr prior)))
                  (and (= (revision candidate) (revision (cdr prior)))
                       (not (bytes=? raw (car prior)))))
          (error 'import-signed-license! "stale or conflicting revision")))
      ;; A verified signed withdrawal with a NEWER revision must be accepted
      ;; for the existing lineage even if Pro is now expired/not entitled.
      ;; Refusing it would leave a still-usable older local credential behind.
      (unless (or (pro-allowed? candidate
                               #:version version
                               #:installation-id installation-id)
                  newer?)
        (error 'import-signed-license!
               "not an active MoveBit right or a newer signed withdrawal"))
      (make-directory* dir)
      (let ([temporary (make-temporary-file "movebit-license-~a" #f dir)])
        (dynamic-wind
         void
         (lambda ()
           (call-with-output-file temporary
             (lambda (out) (write-bytes raw out))
             #:exists 'truncate)
           (rename-file-or-directory temporary target #t))
         (lambda ()
           (when (file-exists? temporary)
             (delete-file temporary)))))
      #t)))

;; Explicit uninstall/reset action; never called by Free feature checks.
(define (remove-local-license! #:local-dir [dir (default-data-dir)])
  (define target (license-file-path #:local-dir dir))
  (when (file-exists? target)
    (delete-file target))
  (void))
