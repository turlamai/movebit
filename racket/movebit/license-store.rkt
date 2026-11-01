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

;; Import only a verified, CURRENTLY usable MoveBit Pro entitlement. A failed
;; attempt never replaces a previously valid credential. A verified revision
;; for an existing entitlement lineage must not roll back: otherwise a user
;; could re-import an older locally cached right after an updated withdrawal.
;; This only constrains what THIS installation has already observed; a device
;; that never receives a withdrawal still cannot infer an offline revocation.
(define (import-signed-license! source trusted-store
                                #:local-dir [dir (default-data-dir)]
                                #:version [version #f]
                                #:installation-id [installation-id #f])
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define raw (read-credential-bytes source))
    (define candidate (verified-from-bytes raw trusted-store))
    (unless (pro-allowed? candidate
                          #:version version
                          #:installation-id installation-id)
      (error 'import-signed-license! "not entitled to MoveBit Pro"))
    (define target (license-file-path #:local-dir dir))
    (when (file-exists? target)
      ;; Recovery from a genuinely damaged old file is allowed. Only the
      ;; old parse/verify step may fail open; revision mismatches MUST abort.
      (define prior
        (with-handlers ([exn:fail? (lambda (_) #f)])
          (define prior-bytes (read-credential-bytes target))
          (cons prior-bytes (verified-from-bytes prior-bytes trusted-store))))
      (when prior
        (define old-bytes (car prior))
        (define old (cdr prior))
        (define issuer (dynamic-require 'permit 'verified-credential-issuer))
        (define entitlement-id (dynamic-require 'permit 'verified-credential-entitlement-id))
        (define revision (dynamic-require 'permit 'verified-credential-revision))
        (when (and (equal? (issuer old) (issuer candidate))
                   (equal? (entitlement-id old) (entitlement-id candidate)))
          (when (or (< (revision candidate) (revision old))
                    (and (= (revision candidate) (revision old))
                         (not (bytes=? raw old-bytes))))
            (error 'import-signed-license! "stale or conflicting revision")))))
    (make-directory* dir)
    (define temporary (make-temporary-file "movebit-license-~a" #f dir))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file temporary
          (lambda (out) (write-bytes raw out))
          #:exists 'truncate)
        (rename-file-or-directory temporary target #t))
      (lambda ()
        (when (file-exists? temporary)
          (delete-file temporary))))
    #t))

;; Explicit uninstall/reset action; never called by Free feature checks.
(define (remove-local-license! #:local-dir [dir (default-data-dir)])
  (define target (license-file-path #:local-dir dir))
  (when (file-exists? target)
    (delete-file target))
  (void))
