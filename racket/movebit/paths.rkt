#lang racket/base

;; Platform data-directory helpers. The contract (kept identical to the old
;; app for drop-in migration): config.json / history live under
;;   macOS   ~/Library/Application Support/movebit
;;   Linux   ~/.config/movebit            (XDG_CONFIG_HOME respected)
;;   Windows %APPDATA%/movebit
;; MOVEBIT_DATA_DIR overrides everything for tests and embedded hosts.
;;
;; Cross-device sync support: the data directory itself is user-aimable
;; (point it at a Resilio/Syncthing folder), which is enabled by a bootstrap
;; file that always lives in the DEFAULT appdata location and never inside
;; the synced data. It carries the two per-machine facts:
;;   device-id  — stable short id naming this machine's history shards
;;   data-dir   — the custom data directory (absent/null = default location)
;; Changing data-dir takes effect on the next launch; the pointer itself must
;; not travel with the synced folder or every device would chase the same
;; pointer.

(require json
         racket/file
         racket/format
         racket/path)

(provide default-data-dir
         movebit-data-dir
         bootstrap-path
         load-bootstrap
         save-bootstrap
         ensure-device-id)

;; --- Default location -----------------------------------------------------

(define (home-dir)
  (find-system-path 'home-dir))

(define (default-data-dir)
  (case (system-type)
    [(macosx)
     (build-path (home-dir) "Library" "Application Support" "movebit")]
    [(windows)
     (define appdata (getenv "APPDATA"))
     (build-path (if (and appdata (not (string=? appdata "")))
                     (string->path appdata)
                     (build-path (home-dir) "AppData" "Roaming"))
                 "movebit")]
    [else
     (define xdg (getenv "XDG_CONFIG_HOME"))
     (build-path (if (and xdg (not (string=? xdg "")) (absolute-path? xdg))
                     (string->path xdg)
                     (build-path (home-dir) ".config"))
                 "movebit")]))

;; --- Bootstrap ------------------------------------------------------------

;; The bootstrap always lives OUTSIDE the (possibly synced) data directory;
;; MOVEBIT_BOOTSTRAP_DIR overrides the location for tests.
(define (bootstrap-path)
  (define override (getenv "MOVEBIT_BOOTSTRAP_DIR"))
  (build-path (if (and override (not (string=? override "")))
                  (string->path override)
                  (default-data-dir))
              "bootstrap.json"))

;; Tolerant reader: absent/corrupt file reads as an empty bootstrap (fresh
;; machine), never an error.
(define (load-bootstrap)
  (define path (bootstrap-path))
  (define js
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (and (file-exists? path)
           (call-with-input-file path read-json))))
  (if (hash? js) js (hasheq)))

(define (save-bootstrap js)
  (define path (bootstrap-path))
  (make-directory* (path-only path))
  (define tmp (string->path (string-append (path->string path) ".tmp")))
  (call-with-output-file tmp
    (lambda (out) (write-json js out) (newline out))
    #:exists 'replace)
  (rename-file-or-directory tmp path #t))

;; Stable 8-hex machine id naming this device's history shards. Generated on
;; first use and persisted next to the default location, so the same synced
;; data directory can host several devices without colliding.
(define (ensure-device-id)
  (define js (load-bootstrap))
  (define existing (hash-ref js 'device-id #f))
  (if (and (string? existing)
           (regexp-match? #px"^[0-9a-f]{8}$" existing))
      existing
      (let ([fresh
             (apply string-append
                    (for/list ([_ (in-range 4)])
                      (define s (~r (random 256) #:base 16))
                      (string-append (substring "00" (string-length s)) s)))])
        (save-bootstrap (hash-set js 'device-id fresh))
        fresh)))

;; --- Effective data directory ----------------------------------------------

(define (movebit-data-dir)
  (define override (getenv "MOVEBIT_DATA_DIR"))
  (cond
    [(and override (not (string=? override "")))
     (simple-form-path override)]
    [else
     (define custom (hash-ref (load-bootstrap) 'data-dir #f))
     (if (and (string? custom) (not (string=? custom "")))
         (simple-form-path custom)
         (default-data-dir))]))
