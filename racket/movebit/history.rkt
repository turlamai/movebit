#lang racket/base

;; Local SQLite records; optional versioned device/day files are transport only.

(require db
         "storage.rkt"
         json
         racket/file
         racket/format
         racket/math
         racket/path
         racket/port
         racket/string
         "timeutil.rkt")

(provide (struct-out day-record)
         default-day-record
         day-record->jsexpr
         jsexpr->day-record
         aggregate-day-records
         cue-outcome-bump
         cue-outcomes-sum
         cue-outcome-count
         (struct-out history-store)
         make-history-store
         history-load!
         history-refresh!
         history-observe-longest-session!
         history-save-day!
         history-get-recent
         history-device-record
         history-device-ids
         history-days
         retention-days
         history-path
         sync-schema-version
         current-history-diagnostic)

;; Cue lifecycle outcomes per reminder kind (issue #88): what actually
;; happened after a reminder fired, so history never conflates "we reminded
;; you" with "you did it". The map is kind-symbol -> status-symbol -> count:
;;   presented          the cue was really shown (once per kind per showing)
;;   self-reported-done the user clicked Done — a claim, never proof
;;   snoozed            the user clicked Later
;;   dismissed          the user clicked Hide
;;   expired            shown, then timed out unanswered
;;   not-delivered      timed out while still pending — never made it on
;;                      screen (Focus, shutdown, …)
;; Counts are events, not unique cues: a cue re-presented after Focus counts
;; its presentations, which is the truthful delivery record. Active minutes
;; stay an ESTIMATE derived from idle sampling; nothing here claims verified
;; breaks or health outcomes.
(struct day-record
  (active-minutes sit-breaks water-reminders micro-breaks longest-session-minutes cue-outcomes)
  #:transparent)

;; days: mutable hash date-key -> (mutable hash device-id -> day-record)
(struct history-store (dir device-id [days #:mutable] sync-dir)
  #:transparent)

(define (default-day-record)
  (day-record 0 0 0 0 0 (hasheq)))

;; --- cue outcome map helpers -------------------------------------------------

(define (cue-outcome-bump outcomes kind status)
  ;; Pure: return `outcomes` with (kind status) counted once more.
  (define per-kind (hash-ref outcomes kind (hasheq)))
  (hash-set outcomes kind
            (hash-update per-kind status add1 0)))

(define (cue-outcomes-sum a b)
  ;; Pure: union-sum two outcome maps (cross-device aggregation).
  (for/fold ([acc a])
            ([(kind per-kind) (in-hash b)])
    (hash-set acc kind
              (for/fold ([inner (hash-ref acc kind (hasheq))])
                        ([(status n) (in-hash per-kind)])
                (hash-update inner status (lambda (m) (+ m n)) 0)))))

(define (cue-outcome-count outcomes kind status)
  (hash-ref (hash-ref outcomes kind (hasheq)) status 0))

;; JSON shape: {"water": {"presented": 3, "self-reported-done": 1}, …}.
;; Racket's json module uses symbol keys in both directions, so kinds and
;; statuses ride as symbols end to end; unknown kinds/statuses survive the
;; round-trip (forward compatibility) with nonneg int values.
(define (cue-outcomes->jsexpr outcomes)
  (for/hasheq ([(kind per-kind) (in-hash outcomes)]
               #:when (symbol? kind))
    (values kind
            (for/hasheq ([(status n) (in-hash per-kind)]
                         #:when (and (symbol? status)
                                     (exact-nonnegative-integer? n)))
              (values status n)))))

(define (jsexpr->cue-outcomes js)
  (if (hash? js)
      (for/hasheq ([(kind per-kind) (in-hash js)] #:when (hash? per-kind))
        (values (as-symbol kind)
                (for/hasheq ([(status n) (in-hash per-kind)]
                             #:when (exact-nonnegative-integer? n))
                  (values (as-symbol status) n))))
      (hasheq)))

;; JSON keys read back as symbols; accept strings too so a foreign writer
;; (or hand-edit) cannot poison the shard.
(define (as-symbol v)
  (cond [(symbol? v) v]
        [(string? v) (string->symbol v)]
        [else 'invalid]))

(define retention-days 370)

(define history-path database-path)
(define sync-schema-version 1)

(define (nonneg n)
  (if (and (exact-integer? n) (>= n 0)) n 0))

(define (day-record->jsexpr r)
  (hasheq 'ActiveMinutes (day-record-active-minutes r)
          'SitBreaks (day-record-sit-breaks r)
          'WaterReminders (day-record-water-reminders r)
          'MicroBreaks (day-record-micro-breaks r)
          'LongestSessionMinutes (day-record-longest-session-minutes r)
          'CueOutcomes (cue-outcomes->jsexpr (day-record-cue-outcomes r))))

;; Tolerant reader: every field defaults to zero when absent or ill-typed, so
;; legacy records (and half-written ones) still load. Cue outcomes default to
;; an empty map — pre-#88 shards simply observed no lifecycle outcomes.
(define (jsexpr->day-record js)
  (if (hash? js)
      (day-record
       (nonneg (hash-ref js 'ActiveMinutes 0))
       (nonneg (hash-ref js 'SitBreaks 0))
       (nonneg (hash-ref js 'WaterReminders 0))
       (nonneg (hash-ref js 'MicroBreaks 0))
       (nonneg (hash-ref js 'LongestSessionMinutes 0))
       (jsexpr->cue-outcomes (hash-ref js 'CueOutcomes (hasheq))))
      (default-day-record)))

;; Apple Screen Time semantics: additive counters sum across devices (cue
;; outcome events included — each device counts what IT showed, so summing
;; reconstructs the whole without double-counting); the longest continuous
;; session is a per-device property, so it takes the max.
(define (aggregate-day-records records)
  (for/fold ([acc (default-day-record)])
            ([r (in-list records)])
    (day-record (+ (day-record-active-minutes acc)
                   (day-record-active-minutes r))
                (+ (day-record-sit-breaks acc)
                   (day-record-sit-breaks r))
                (+ (day-record-water-reminders acc)
                   (day-record-water-reminders r))
                (+ (day-record-micro-breaks acc)
                   (day-record-micro-breaks r))
                (max (day-record-longest-session-minutes acc)
                     (day-record-longest-session-minutes r))
                (cue-outcomes-sum (day-record-cue-outcomes acc)
                                  (day-record-cue-outcomes r)))))

;; A record is a monotonically growing snapshot for one device/day. Replays
;; never add counters; distinct devices are aggregated only at read time.
;; The native backend installs a file-backed diagnostic sink. Domain/storage
;; failures must never allocate a Windows stderr console.
(define current-history-diagnostic (make-parameter (lambda (_) (void))))
(define (report-storage-error context e)
  (with-handlers ([exn:fail? void])
    ((current-history-diagnostic) (format "~a: ~a" context (exn-message e)))))

(define max-counter (sub1 (expt 2 31)))
(define max-revision (sub1 (expt 2 63)))
(define max-shard-bytes (* 64 1024))
(define (counter? n) (and (exact-nonnegative-integer? n) (<= n max-counter)))
(define (date-key? s)
  (and (string? s) (regexp-match? #px"^[0-9]{4}-[0-9]{2}-[0-9]{2}$" s)
       (date-key->civil-day s) (equal? (date-key+days s 0) s)))
(define (device-id? s) (and (string? s) (regexp-match? #px"^[0-9a-f]{8}$" s)))
(define (outcomes-valid? outcomes)
  (and (hash? outcomes) (<= (hash-count outcomes) 32)
       (for/and ([(kind statuses) (in-hash outcomes)])
         (and (symbol? kind) (<= (string-length (symbol->string kind)) 64)
              (hash? statuses) (<= (hash-count statuses) 32)
              (for/and ([(status n) (in-hash statuses)])
                (and (symbol? status) (<= (string-length (symbol->string status)) 64)
                     (counter? n)))))))
(define (record-valid? r)
  (and (day-record? r)
       (andmap counter? (list (day-record-active-minutes r) (day-record-sit-breaks r)
                             (day-record-water-reminders r) (day-record-micro-breaks r)
                             (day-record-longest-session-minutes r)))
       (outcomes-valid? (day-record-cue-outcomes r))
       (<= (bytes-length (jsexpr->bytes (day-record->jsexpr r))) (- max-shard-bytes 1024))))
(define (record-json-valid? js)
  (and (hash? js)
       (for/and ([key '(ActiveMinutes SitBreaks WaterReminders MicroBreaks LongestSessionMinutes)])
         (counter? (hash-ref js key #f)))
       (outcomes-valid? (hash-ref js 'CueOutcomes #f))))
(define (merge-outcomes a b)
  (for/fold ([acc a]) ([(kind statuses) (in-hash b)])
    (hash-set acc kind
      (for/fold ([inner (hash-ref acc kind (hasheq))]) ([(status n) (in-hash statuses)])
        (hash-update inner status (lambda (v) (max v n)) 0)))))
(define (merge-record a b)
  (day-record (max (day-record-active-minutes a) (day-record-active-minutes b))
              (max (day-record-sit-breaks a) (day-record-sit-breaks b))
              (max (day-record-water-reminders a) (day-record-water-reminders b))
              (max (day-record-micro-breaks a) (day-record-micro-breaks b))
              (max (day-record-longest-session-minutes a) (day-record-longest-session-minutes b))
              (merge-outcomes (day-record-cue-outcomes a) (day-record-cue-outcomes b))))

;; File identities also catch case aliases on case-insensitive volumes.
(define (contains-directory? parent child)
  (define p (normal-case-path (normalize-path parent)))
  (define c (normal-case-path (normalize-path child)))
  (define relative (find-relative-path p c))
  (or (and (relative-path? relative) (not (member 'up (explode-path relative))))
      (and (directory-exists? p)
           (let ([identity (file-or-directory-identity p)])
             (let loop ([current c])
               (or (and (directory-exists? current)
                        (= identity (file-or-directory-identity current)))
                   (let-values ([(base name dir?) (split-path current)])
                     (and (path? base) (not (equal? base current)) (loop base)))))))))

(define (make-history-store directory device-id #:sync-dir [sync-dir #f])
  (unless (device-id? device-id) (raise-argument-error 'make-history-store "8 lowercase hex digits" device-id))
  (when (and sync-dir (contains-directory? sync-dir directory))
    (error 'make-history-store "sync directory must not contain the local database directory"))
  (history-store directory device-id (make-hash) sync-dir))

(define (with-history store proc) (call-with-store (history-store-dir store) proc))
(define (row->record row [offset 0])
  (day-record (vector-ref row offset) (vector-ref row (+ offset 1))
              (vector-ref row (+ offset 2)) (vector-ref row (+ offset 3))
              (vector-ref row (+ offset 4))
              (jsexpr->cue-outcomes (string->jsexpr (vector-ref row (+ offset 5))))))
(define (get-row db day device)
  (query-maybe-row db "SELECT revision, active, sit, water, micro, longest, outcomes FROM records WHERE day = ? AND device = ?" day device))
(define (put-row! db day device revision record)
  (query-exec db "INSERT INTO records VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(day, device) DO UPDATE SET revision=excluded.revision, active=excluded.active,
    sit=excluded.sit, water=excluded.water, micro=excluded.micro, longest=excluded.longest, outcomes=excluded.outcomes"
    day device revision (day-record-active-minutes record) (day-record-sit-breaks record)
    (day-record-water-reminders record) (day-record-micro-breaks record)
    (day-record-longest-session-minutes record) (jsexpr->string (day-record-cue-outcomes record))))

(define (reload-days! store)
  (define rows (with-history store (lambda (db) (query-rows db "SELECT day, device, active, sit, water, micro, longest, outcomes FROM records ORDER BY day, device"))))
  (define next (make-hash))
  (for ([row (in-list rows)])
    (hash-set! (hash-ref! next (vector-ref row 0) make-hash)
               (vector-ref row 1) (row->record row 2)))
  ;; Publish one complete snapshot; concurrent readers never see a cleared
  ;; or half-filled cache while a database refresh is being materialized.
  (set-history-store-days! store next))

;; Import is transactional and validates both the envelope and payload before
;; touching SQLite. Equal/stale revisions are no-ops, including conflict copies.
(define (import-shard! store day device file)
  (when (and (not (link-exists? file)) (<= (file-size file) max-shard-bytes))
    (define js
      (call-with-input-file file
        (lambda (in)
          (define bytes (read-bytes (add1 max-shard-bytes) in))
          (and (bytes? bytes) (<= (bytes-length bytes) max-shard-bytes)
               (call-with-input-bytes bytes
                 (lambda (bounded)
                   (define value (read-json bounded))
                   (and (regexp-match? #px"^\\s*$" (port->string bounded)) value)))))))
    (when (and (hash? js) (equal? (hash-ref js 'SchemaVersion #f) sync-schema-version)
               (equal? (hash-ref js 'Date #f) day) (equal? (hash-ref js 'DeviceId #f) device)
               (exact-positive-integer? (hash-ref js 'Revision #f))
               (<= (hash-ref js 'Revision) max-revision)
               (record-json-valid? (hash-ref js 'Record #f)))
      (define incoming (jsexpr->day-record (hash-ref js 'Record)))
      (define revision (hash-ref js 'Revision))
      (with-history store
        (lambda (db)
          (call-with-transaction db
            (lambda ()
              (define cutoff (query-value db "SELECT pruned_before FROM sync_state WHERE id = 1"))
              (define existing (get-row db day device))
              (when (and (string>=? day cutoff)
                         ;; A local database is authoritative for its own existing rows.
                         (or (not (string=? device (history-store-device-id store))) (not existing))
                         (or (not existing) (> revision (vector-ref existing 0))))
                ;; A higher revision must not rewind a counter from the same writer.
                (define next (if existing (merge-record (row->record existing 1) incoming) incoming))
                (put-row! db day device revision next)))
            #:option 'immediate))))))

(define (scan-sync! store)
  (define root (and (history-store-sync-dir store) (build-path (history-store-sync-dir store) "history")))
  (when (and root (directory-exists? root) (not (link-exists? root)))
    (for ([entry (in-list (directory-list root))])
      (define day (path->string entry))
      (define dir (build-path root entry))
      (when (and (date-key? day) (directory-exists? dir) (not (link-exists? dir)))
        (for ([name (in-list (directory-list dir))])
          (define matched (regexp-match #px"^([0-9a-f]{8})[.]json$" (path->string name)))
          (when matched
            (with-handlers ([exn:fail? (lambda (_) (void))])
              (import-shard! store day (cadr matched) (build-path dir name)))))))))

(define (shard-content day device revision record)
  (jsexpr->bytes (hasheq 'SchemaVersion sync-schema-version 'Date day 'DeviceId device
                        'Revision revision 'Record (day-record->jsexpr record))))
(define (write-shard! store day revision record)
  (define root (history-store-sync-dir store))
  (when root
    (define dir (build-path root "history" day))
    (when (or (link-exists? (build-path root "history")) (link-exists? dir))
      (error 'record-sync "refusing a linked history directory"))
    (make-directory* dir)
    (define file (build-path dir (string-append (history-store-device-id store) ".json")))
    (when (link-exists? file) (error 'record-sync "refusing a linked record"))
    (define bytes (shard-content day (history-store-device-id store) revision record))
    (unless (and (file-exists? file) (<= (file-size file) max-shard-bytes)
                 (bytes=? bytes (file->bytes file)))
      (define tmp (make-temporary-file ".movebit-record-~a.tmp" #f dir))
      (dynamic-wind void
        (lambda ()
          (call-with-output-file tmp (lambda (out) (write-bytes bytes out)) #:exists 'truncate)
          (rename-file-or-directory tmp file #t))
        (lambda () (when (file-exists? tmp) (delete-file tmp)))))))

;; The committed local rows ARE the durable outbox. A failed export or a
;; stale file left by another instance is repaired on the next refresh;
;; neither can roll back the committed local snapshot or its revision.
(define (publish-own! store)
  (when (history-store-sync-dir store)
    (define rows (with-history store (lambda (db)
      (query-rows db "SELECT day, revision, active, sit, water, micro, longest, outcomes FROM records WHERE device = ? ORDER BY day"
                  (history-store-device-id store)))))
    (for ([row (in-list rows)])
      (write-shard! store (vector-ref row 0) (vector-ref row 1) (row->record row 2)))))

(define (prune! store today-key)
  (define cutoff (date-key+days today-key (- (sub1 retention-days))))
  (with-history store (lambda (db)
    (call-with-transaction db (lambda ()
      (query-exec db "UPDATE sync_state SET pruned_before = max(pruned_before, ?) WHERE id = 1" cutoff)
      (query-exec db "DELETE FROM records WHERE day < (SELECT pruned_before FROM sync_state WHERE id = 1)"))
      #:option 'immediate)))
  ;; Never edit a peer's transport file. The durable watermark rejects old
  ;; arrivals even if their files are still present in the shared directory.
  (define root (and (history-store-sync-dir store) (build-path (history-store-sync-dir store) "history")))
  (when (and root (directory-exists? root) (not (link-exists? root)))
    (for ([entry (in-list (directory-list root))])
      (define day (path->string entry))
      (define dir (build-path root entry))
      (when (and (date-key? day) (string<? day cutoff) (directory-exists? dir) (not (link-exists? dir)))
        (define file (build-path dir (string-append (history-store-device-id store) ".json")))
        (when (and (file-exists? file) (not (link-exists? file))) (delete-file file))
        (when (null? (directory-list dir)) (delete-directory dir))))))

(define (best-effort-sync! store)
  (with-handlers ([exn:fail? (lambda (e) (report-storage-error "record sync deferred" e))])
    (scan-sync! store)
    (publish-own! store)))
(define (history-load! store)
  (with-handlers ([exn:fail? (lambda (e) (report-storage-error "SQLite load deferred" e))])
    (prune! store (ms->date-key (now-ms)))
    (best-effort-sync! store)
    (reload-days! store))
  store)
(define (history-refresh! store)
  (with-handlers ([exn:fail? (lambda (e) (report-storage-error "SQLite refresh deferred" e))])
    (prune! store (ms->date-key (now-ms)))
    (best-effort-sync! store)
    (reload-days! store))
  store)

(define (history-observe-longest-session! store date-key minutes)
  (when (and (counter? minutes) (positive? minutes))
    (define per-device (hash-ref! (history-store-days store) date-key make-hash))
    (define device (history-store-device-id store))
    (define record (hash-ref per-device device (default-day-record)))
    (hash-set! per-device device
      (struct-copy day-record record [longest-session-minutes (max minutes (day-record-longest-session-minutes record))]))))

(define (history-save-day! store date-key record [today-key (ms->date-key (now-ms))])
  (unless (and (date-key? date-key) (date-key? today-key) (record-valid? record))
    (error 'history-save-day! "invalid local daily record"))
  (prune! store (if (string>? date-key today-key) date-key today-key))
  (define cached (history-device-record store date-key))
  (with-history store
    (lambda (db)
      (call-with-transaction db
        (lambda ()
          (define cutoff (query-value db "SELECT pruned_before FROM sync_state WHERE id = 1"))
          (when (string>=? date-key cutoff)
            (define existing (get-row db date-key (history-store-device-id store)))
            (define next (merge-record (merge-record cached record)
                                       (if existing (row->record existing 1) (default-day-record))))
            (unless (and existing (equal? next (row->record existing 1)))
              (define revision (if existing (add1 (vector-ref existing 0)) 1))
              (when (> revision max-revision) (error 'history-save-day! "record revision exhausted"))
              (put-row! db date-key (history-store-device-id store) revision next))))
        #:option 'immediate)))
  (reload-days! store)
  (with-handlers ([exn:fail? (lambda (e) (report-storage-error "record export deferred" e))])
    (publish-own! store)))

(define (history-device-record store date-key)
  (hash-ref (hash-ref (history-store-days store) date-key (hasheq))
            (history-store-device-id store) (default-day-record)))
(define (history-device-ids store date-key)
  (sort (hash-keys (hash-ref (history-store-days store) date-key (hasheq))) string<?))
(define (aggregate-day store date-key)
  (aggregate-day-records (hash-values (hash-ref (history-store-days store) date-key (hasheq)))))
(define (history-get-recent store count today-key)
  (for/list ([i (in-range (sub1 count) -1 -1)])
    (define key (date-key+days today-key (- i)))
    (cons key (aggregate-day store key))))
(define (history-days store)
  (for/hasheq ([(day records) (in-hash (history-store-days store))])
    (values day (aggregate-day-records (hash-values records)))))
