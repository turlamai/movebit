#lang racket/base

;; SQLite is machine-local. Sync code receives records, never this file.
(require db racket/file)
(provide database-path call-with-store storage-schema-version)

(define storage-schema-version 1)
(define application-id #x4d424954)
(define (database-path directory) (build-path directory "movebit.sqlite3"))

(define (call-with-store directory proc)
  (make-directory* directory)
  (define connection
    (sqlite3-connect #:database (database-path directory) #:mode 'create
                     #:busy-retry-limit 500 #:busy-retry-delay 0.01))
  (dynamic-wind
    void
    (lambda ()
      (query-exec connection "PRAGMA foreign_keys = ON")
      (call-with-transaction
       connection
       (lambda ()
         (define version (query-value connection "PRAGMA user_version"))
         (define identity (query-value connection "PRAGMA application_id"))
         (cond
           [(and (= version storage-schema-version) (= identity application-id)) (void)]
           [(and (zero? version) (zero? identity)
                 (zero? (query-value connection "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")))
            (query-exec connection "CREATE TABLE settings (id INTEGER PRIMARY KEY CHECK(id = 1), payload TEXT NOT NULL)")
            (query-exec connection "CREATE TABLE records (
              day TEXT NOT NULL, device TEXT NOT NULL,
              revision INTEGER NOT NULL CHECK(revision > 0),
              active INTEGER NOT NULL CHECK(active >= 0),
              sit INTEGER NOT NULL CHECK(sit >= 0),
              water INTEGER NOT NULL CHECK(water >= 0),
              micro INTEGER NOT NULL CHECK(micro >= 0),
              longest INTEGER NOT NULL CHECK(longest >= 0),
              outcomes TEXT NOT NULL, PRIMARY KEY(day, device)) WITHOUT ROWID")
            (query-exec connection "CREATE TABLE sync_state (id INTEGER PRIMARY KEY CHECK(id = 1), pruned_before TEXT NOT NULL)")
            (query-exec connection "INSERT INTO sync_state VALUES (1, '0001-01-01')")
            (query-exec connection (format "PRAGMA application_id = ~a" application-id))
            (query-exec connection (format "PRAGMA user_version = ~a" storage-schema-version))]
           [else (error 'movebit-storage "unsupported or foreign database (schema ~a)" version)]))
       #:option 'immediate)
      (query-value connection "PRAGMA journal_mode = WAL")
      (query-exec connection "PRAGMA synchronous = FULL")
      (proc connection))
    (lambda () (disconnect connection))))
