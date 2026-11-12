#lang racket/base
;; Windows hosted runners may fail reading the OS ROOT certificate store.
;; Use trusted Mozilla CA roots without disabling TLS/hostname verification.
(require openssl
         pkg
         racket/file
         racket/string)

;; Default pin for local/CI runs that do not set RIVET_PIN. The block below is
;; read by `raco rivet doctor --release`, which resolves the `${RIVET_PIN}`
;; placeholder in the URL template instead of flagging an empty ref.
#|
env:
  RIVET_PIN: 7f34eee832418c3ad3bd73981e7a318d78d3be24
|#

(define default-rivet-pin "7f34eee832418c3ad3bd73981e7a318d78d3be24")

(define bundle (getenv "MOVEBIT_CI_CA_BUNDLE"))
(unless (and bundle
             (file-exists? bundle)
             (regexp-match? #rx#"-----BEGIN CERTIFICATE-----"
                            (file->bytes bundle)))
  (error 'ci-install-windows-deps
         "trusted Mozilla PEM CA bundle is missing or invalid"))

(ssl-default-verify-sources (list bundle))

(define rivet-pin
  (let ([from-env (getenv "RIVET_PIN")])
    (if (and from-env (not (equal? from-env ""))) from-env default-rivet-pin)))

(unless (regexp-match? #px"^[0-9a-f]{40}$" rivet-pin)
  (error 'ci-install-windows-deps
         "RIVET_PIN must be a full 40-character commit SHA"))

(define url-template "https://github.com/turlamai/rivet.git#${RIVET_PIN}")

(pkg-install-command #:auto #t #:no-docs #t
                     (string-replace url-template "${RIVET_PIN}" rivet-pin))
