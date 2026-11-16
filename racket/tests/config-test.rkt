#lang racket/base

(require rackunit db racket/file json
         "../movebit/storage.rkt" "../movebit/config.rkt" "../movebit/timeutil.rkt")
(define (make-temp-dir prefix)
  (make-temporary-file (string-append "movebit-" prefix "-~a") 'directory))
(define (write-payload dir js)
  (call-with-store dir (lambda (db)
    (query-exec db "INSERT OR REPLACE INTO settings VALUES (1, ?)" (jsexpr->string js)))))

(test-case "preferences are durable SQLite rows, not JSON files"
  (define dir (make-temp-dir "sqlite-config"))
  (define expected (reminder-config #f #f #t "zh" #t 1230 480 250 750))
  (check-true (save-config dir expected))
  (check-equal? (load-config dir) expected)
  (check-equal? (call-with-input-file (config-path dir) (lambda (in) (read-bytes 16 in)))
                #"SQLite format 3\0")
  (check-false (file-exists? (build-path dir "config.json")))
  (call-with-store dir (lambda (db)
    (check-equal? (query-value db "PRAGMA user_version") storage-schema-version)
    (check-equal? (query-value db "SELECT count(*) FROM settings") 1)))
  (save-config dir (default-config))
  (call-with-store dir (lambda (db) (check-equal? (query-value db "SELECT count(*) FROM settings") 1)))
  (delete-directory/files dir))

(test-case "failed writes and corrupt/foreign databases are not overwritten"
  (define dir (make-temp-dir "blocked"))
  (define blocker (build-path dir "not-a-directory"))
  (display-to-file "blocked" blocker)
  (check-false (save-config blocker (default-config)))
  (define path (database-path dir))
  (display-to-file "not a database" path)
  (check-equal? (load-config dir) (default-config))
  (check-false (save-config dir (default-config)))
  (check-equal? (file->string path) "not a database")
  (delete-file path)
  (define db (sqlite3-connect #:database path #:mode 'create))
  (query-exec db "CREATE TABLE somebody_elses_data (value TEXT)")
  (disconnect db)
  (check-false (save-config dir (default-config)))
  (set! db (sqlite3-connect #:database path))
  (check-equal? (query-value db "SELECT count(*) FROM sqlite_master WHERE name = 'somebody_elses_data'") 1)
  (disconnect db)
  (delete-directory/files dir))

(test-case "versioned configuration validation survives the SQLite encoding"
  (define dir (make-temp-dir "validation"))
  (for ([js (list (hasheq) (hasheq 'SchemaVersion 4)
                   (hasheq 'SchemaVersion (add1 config-schema-version)))])
    (write-payload dir js)
    (check-equal? (load-config dir) (default-config)))
  (write-payload dir (hasheq 'SchemaVersion config-schema-version 'SoundEnabled #f
                             'Language "zh" 'QuietHoursStartMinutes -5
                             'QuietHoursEndMinutes 9999 'CompanionFreeX 5000 'CompanionFreeY -7))
  (define actual (load-config dir))
  (check-false (reminder-config-sound-enabled actual))
  (check-equal? (reminder-config-language actual) "zh")
  (check-equal? (reminder-config-quiet-hours-start-minutes actual) 0)
  (check-equal? (reminder-config-quiet-hours-end-minutes actual) 1439)
  (check-equal? (reminder-config-companion-free-x actual) 1000)
  (check-equal? (reminder-config-companion-free-y actual) -1)
  (write-payload dir (hasheq 'SchemaVersion config-schema-version 'SoundEnabled "yes" 'Language "foreign"))
  (check-true (reminder-config-sound-enabled (load-config dir)))
  (check-equal? (reminder-config-language (load-config dir)) "auto")
  (delete-directory/files dir))

(test-case "new database does not import retired JSON settings"
  (define dir (make-temp-dir "clean-slate"))
  (call-with-output-file (build-path dir "config.json")
    (lambda (out) (write-json (hash-set (config->jsexpr (default-config)) 'Language "zh") out)))
  (check-equal? (load-config dir) (default-config))
  (check-true (file-exists? (build-path dir "config.json")))
  (check-true (save-config dir (struct-copy reminder-config (default-config) [language "en"])))
  (check-equal? (reminder-config-language (load-config dir)) "en")
  (delete-directory/files dir))
;; --- quiet hours ------------------------------------------------------------

(define (quiet-config start end)
  (clamp-config (struct-copy reminder-config (default-config)
                           [quiet-hours-enabled #t]
                           [quiet-hours-start-minutes start]
                           [quiet-hours-end-minutes end])))

(define (at hh mm) (local-ymd->ms 2026 1 15 hh mm 0))

(let ([c (quiet-config 1320 420)]) ; 22:00 -> 07:00, wraps midnight
  (check-true (quiet-hours-active? c (at 23 0)))
  (check-true (quiet-hours-active? c (at 0 30)))
  (check-true (quiet-hours-active? c (at 6 59)))
  (check-false (quiet-hours-active? c (at 7 0)))
  (check-false (quiet-hours-active? c (at 12 0)))
  (check-false (quiet-hours-active? c (at 21 59)))
  (check-equal? (quiet-hours-seconds-remaining c (at 23 0)) (* 8 3600))
  (check-equal? (quiet-hours-seconds-remaining c (at 6 0)) 3600)
  (check-equal? (quiet-hours-seconds-remaining c (at 12 0)) 0))

;; A same-day window (09:00 -> 17:00) does not wrap.
(let ([c (quiet-config 540 1020)])
  (check-true (quiet-hours-active? c (at 9 0)))
  (check-true (quiet-hours-active? c (at 16 59)))
  (check-false (quiet-hours-active? c (at 17 0)))
  (check-equal? (quiet-hours-seconds-remaining c (at 16 0)) 3600))

;; start == end means "off", never an all-day pause.
(let ([c (quiet-config 600 600)])
  (check-false (quiet-hours-active? c (at 10 0)))
  (check-equal? (quiet-hours-seconds-remaining c (at 10 0)) 0))

;; Disabled quiet hours never activate.
(let ([c (clamp-config (struct-copy reminder-config (quiet-config 1320 420)
                                     [quiet-hours-enabled #f]))])
  (check-false (quiet-hours-active? c (at 23 0))))

;; --- free placement ---------------------------------------------------------

;; Free coordinates round-trip as per-mille values; -1 means "default corner".
(let* ([dir (make-temp-dir "free-pos")]
       [config (clamp-config
                (struct-copy reminder-config (default-config)
                             [companion-free-x 123]
                             [companion-free-y 987]))])
  (check-true (save-config dir config))
  (define loaded (load-config dir))
  (check-equal? (reminder-config-companion-free-x loaded) 123)
  (check-equal? (reminder-config-companion-free-y loaded) 987)
  (delete-directory/files dir))

;; Out-of-range free coordinates normalize to -1 (default corner), never
;; off-screen.
(let ([c (clamp-config (struct-copy reminder-config (default-config)
                                     [companion-free-x 4000]
                                     [companion-free-y -5]))])
  (check-equal? (reminder-config-companion-free-x c) 1000)
  (check-equal? (reminder-config-companion-free-y c) -1))

(test-case "a future SQLite schema is refused without erasing settings"
  (define dir (make-temp-dir "future-db"))
  (save-config dir (struct-copy reminder-config (default-config) [language "zh"]))
  (define db (sqlite3-connect #:database (database-path dir)))
  (query-exec db "PRAGMA user_version = 2")
  (disconnect db)
  (check-equal? (load-config dir) (default-config))
  (check-false (save-config dir (default-config)))
  (set! db (sqlite3-connect #:database (database-path dir)))
  (check-equal? (query-value db "PRAGMA user_version") 2)
  (check-equal? (hash-ref (string->jsexpr (query-value db "SELECT payload FROM settings")) 'Language) "zh")
  (disconnect db)
  (delete-directory/files dir))
