#lang racket/base

;; MoveBit config schema v5 tests (issue #140): the slim nine-field surface,
;; version gate, clamping, tolerance, legacy migrations and the clean-install
;; contract (a foreign file is defaults, never guessed at).

(require rackunit
         racket/file
         json
         "../movebit/config.rkt"
         "../movebit/timeutil.rkt")

(define (make-temp-dir prefix)
  (define dir (make-temporary-file (string-append "movebit-" prefix "-~a") 'directory))
  dir)

;; Save_and_load_roundtrip_all_settings
(let* ([dir (make-temp-dir "cfg")]
       [expected (reminder-config #f #f #t "zh" #t 1230 480 250 750)])
  (check-true (save-config dir expected))
  (define actual (load-config dir))
  (check-equal? actual expected)
  ;; atomic write: no .tmp residue
  (check-false (file-exists? (build-path dir "config.json.tmp")))
  ;; every write stamps the schema version
  (define on-disk (call-with-input-file (config-path dir) read-json))
  (check-equal? (hash-ref on-disk 'SchemaVersion) config-schema-version)
  (delete-directory/files dir))

;; TrySave_returns_false_when_config_directory_is_a_file
(let* ([dir (make-temp-dir "cfgblk")]
       [blocked-path (build-path dir "not-a-directory")])
  (display-to-file "block directory creation" blocked-path)
  (check-false (save-config blocked-path (default-config)))
  (delete-directory/files dir))

;; Load_clamps_numeric_values_from_disk
(let* ([dir (make-temp-dir "clamp")]
       [path (build-path dir "config.json")])
  (call-with-output-file path
    (lambda (out)
      (write-json
       (hasheq 'SchemaVersion config-schema-version
               'QuietHoursStartMinutes -5
               'QuietHoursEndMinutes 9999
               'SoundEnabled "yes"
               'Language "klingon"
               'CompanionFreeX 5000
               'CompanionFreeY -7)
       out)))
  (define actual (load-config dir))
  (check-equal? (reminder-config-quiet-hours-start-minutes actual) 0)
  (check-equal? (reminder-config-quiet-hours-end-minutes actual) 1439)
  ;; wrong-typed boolean keeps the default, it is not coerced
  (check-true (reminder-config-sound-enabled actual))
  (check-equal? (reminder-config-language actual) "auto")
  ;; free position: 5000 clamps to 1000, -7 means "default corner"
  (check-equal? (reminder-config-companion-free-x actual) 1000)
  (check-equal? (reminder-config-companion-free-y actual) -1)
  (delete-directory/files dir))

;; Corrupt_json_falls_back_to_defaults
(let* ([dir (make-temp-dir "corrupt")]
       [path (build-path dir "config.json")])
  (display-to-file "{ definitely not json" path)
  (check-equal? (load-config dir) (default-config))
  (delete-directory/files dir))

;; The v5 defaults ARE the product: sound on (the new cue chime), updates on,
;; onboarding pending, language auto, quiet hours off, default corner.
(let ([fresh (default-config)])
  (check-true (reminder-config-sound-enabled fresh))
  (check-true (reminder-config-auto-check-updates fresh))
  (check-false (reminder-config-welcome-shown fresh))
  (check-equal? (reminder-config-language fresh) "auto")
  (check-false (reminder-config-quiet-hours-enabled fresh))
  (check-equal? (reminder-config-companion-free-x fresh) -1)
  (check-equal? (reminder-config-companion-free-y fresh) -1))

;; Legacy_v0x_PascalCase_file_without_version_marker_is_foreign
(let* ([dir (make-temp-dir "legacy")]
       [path (build-path dir "config.json")])
  (display-to-file #<<EOF
{
  "SitReminderMinutes": 60,
  "ForceBreakEnabled": true,
  "BreakDurationMinutes": 25,
  "SkipAfterSeconds": 90,
  "WelcomeShown": true
}
EOF
                   path)
  ;; v0.x had no real users: an old file is NOT migrated. A fresh profile
  ;; starts with defaults; the next save overwrites the foreign file.
  (check-equal? (load-config dir) (default-config))
  (delete-directory/files dir))

;; Unknown_future_schema_version_is_also_rejected
(let* ([dir (make-temp-dir "future")]
       [path (build-path dir "config.json")])
  (call-with-output-file path
    (lambda (out)
      (write-json (hash-set (config->jsexpr (default-config))
                            'SchemaVersion
                            (add1 config-schema-version))
                  out)))
  (check-equal? (load-config dir) (default-config))
  (delete-directory/files dir))

;; Missing_version_marker_falls_back_even_if_everything_else_matches
(let* ([dir (make-temp-dir "noversion")]
       [path (build-path dir "config.json")])
  (call-with-output-file path
    (lambda (out)
      (write-json (hash-remove (config->jsexpr (default-config)) 'SchemaVersion)
                  out)))
  (check-equal? (load-config dir) (default-config))
  (delete-directory/files dir))

;; Partial_v5_file_keeps_defaults_for_missing_keys
(let* ([dir (make-temp-dir "partial")]
       [path (build-path dir "config.json")])
  (display-to-file
   (format "{\"SchemaVersion\": ~a, \"SoundEnabled\": false, \"WelcomeShown\": true, \"Language\": \"zh\"}"
           config-schema-version)
   path)
  (define actual (load-config dir))
  (check-false (reminder-config-sound-enabled actual))
  (check-true (reminder-config-welcome-shown actual))
  (check-equal? (reminder-config-language actual) "zh")
  (check-false (reminder-config-quiet-hours-enabled actual))
  (delete-directory/files dir))

;; Save_clamps_out_of_range_values_too (clamp on save, per the port contract)
(let* ([dir (make-temp-dir "saveclamp")]
       [draft (struct-copy reminder-config (default-config)
                           [language "klingon"]
                           [quiet-hours-start-minutes -5]
                           [quiet-hours-end-minutes 9999]
                           [companion-free-x 5000]
                           [companion-free-y -7])])
  (save-config dir draft)
  (define actual (load-config dir))
  (check-equal? (reminder-config-language actual) "auto")
  (check-equal? (reminder-config-quiet-hours-start-minutes actual) 0)
  (check-equal? (reminder-config-quiet-hours-end-minutes actual) 1439)
  (check-equal? (reminder-config-companion-free-x actual) 1000)
  (check-equal? (reminder-config-companion-free-y actual) -1)
  (delete-directory/files dir))

;; --- legacy migrations: only the kept fields survive ------------------------

;; A v4 file (previous schema) keeps language / sound / auto-update / quiet
;; hours / placement; the rhythm, preset and companion fields it carries are
;; intentionally dropped — the product ships one cadence and one presentation.
(let* ([dir (make-temp-dir "v4-migrate")]
       [path (build-path dir "config.json")]
       [v4 (hasheq 'SchemaVersion 4
                   'SitReminderMinutes 65
                   'WaterReminderMinutes 55
                   'AwayResetMinutes 8
                   'SnoozeMinutes 20
                   'MicroBreakEnabled #f
                   'MicroBreakIntervalMinutes 35
                   'MicroBreakDurationSeconds 25
                   'MotionEnabled #f
                   'SoundEnabled #t
                   'AutoCheckUpdates #f
                   'WelcomeShown #t
                   'Language "zh"
                   'CompanionSize "L"
                   'CompanionMotion "lively"
                   'CompanionDock "top-left"
                   'CompanionLabels "always"
                   'Preset "gentle"
                   'SitEnabled #f
                   'WaterEnabled #f
                   'QuietHoursEnabled #t
                   'QuietHoursStartMinutes 1200
                   'QuietHoursEndMinutes 480
                   'CompanionFreeX 123
                   'CompanionFreeY 987)])
  (call-with-output-file path (lambda (out) (write-json v4 out)))
  (define migrated (load-config dir))
  (check-true (reminder-config-sound-enabled migrated))
  (check-false (reminder-config-auto-check-updates migrated))
  (check-true (reminder-config-welcome-shown migrated))
  (check-equal? (reminder-config-language migrated) "zh")
  (check-true (reminder-config-quiet-hours-enabled migrated))
  (check-equal? (reminder-config-quiet-hours-start-minutes migrated) 1200)
  (check-equal? (reminder-config-quiet-hours-end-minutes migrated) 480)
  (check-equal? (reminder-config-companion-free-x migrated) 123)
  (check-equal? (reminder-config-companion-free-y migrated) 987)
  ;; the next save writes the v5 shape
  (check-true (save-config dir migrated))
  (check-equal? (hash-ref (call-with-input-file path read-json) 'SchemaVersion)
                config-schema-version)
  (delete-directory/files dir))

;; A v3 file migrates the same way (identical kept keys).
(let* ([dir (make-temp-dir "v3-migrate")]
       [path (build-path dir "config.json")]
       [v3 (hasheq 'SchemaVersion 3
                   'SoundEnabled #t
                   'CompanionDock "top-left"
                   'QuietHoursEnabled #t
                   'QuietHoursStartMinutes 1200
                   'QuietHoursEndMinutes 480)])
  (call-with-output-file path (lambda (out) (write-json v3 out)))
  (define migrated (load-config dir))
  (check-true (reminder-config-sound-enabled migrated))
  (check-true (reminder-config-quiet-hours-enabled migrated))
  (check-equal? (reminder-config-companion-free-x migrated) -1)
  (delete-directory/files dir))

;; A shipped 0.0.1 (v2) file keeps the same surviving choices and leaves a
;; one-time backup behind.
(let* ([dir (make-temp-dir "v2-migrate")]
       [path (build-path dir "config.json")]
       [v2 (hasheq 'SchemaVersion 2
                   'SitReminderMinutes 60
                   'WaterReminderMinutes 40
                   'AwayResetMinutes 8
                   'SnoozeMinutes 20
                   'MicroBreakEnabled #f
                   'MicroBreakIntervalMinutes 35
                   'MicroBreakDurationSeconds 25
                   'MotionEnabled #f
                   'SoundEnabled #t
                   'AutoCheckUpdates #f
                   'WelcomeShown #t
                   'Language "zh"
                   'CompanionSize "L"
                   'CompanionMotion "lively"
                   'CompanionDock "top-left"
                   'CompanionLabels "always")])
  (call-with-output-file path
    (lambda (out) (write-json v2 out)))
  (define migrated (load-config dir))
  (check-true (reminder-config-sound-enabled migrated))
  (check-false (reminder-config-auto-check-updates migrated))
  (check-true (reminder-config-welcome-shown migrated))
  (check-equal? (reminder-config-language migrated) "zh")
  ;; Backup written exactly once, and it is the original v2 document.
  (define bak (build-path dir "config.json.v2.bak"))
  (check-true (file-exists? bak))
  (check-equal? (hash-ref (call-with-input-file bak read-json) 'SchemaVersion) 2)
  (check-true (save-config dir migrated))
  (check-equal? (hash-ref (call-with-input-file path read-json) 'SchemaVersion)
                config-schema-version)
  (check-equal? (hash-ref (call-with-input-file bak read-json) 'SitReminderMinutes)
                60)
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
