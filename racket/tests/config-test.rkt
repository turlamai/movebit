#lang racket/base

;; MoveBit v1 config schema tests: version gate, clamping, tolerance and the
;; clean-install contract (a foreign file is defaults, never guessed at).

(require rackunit
         racket/file
         json
         "../movebit/config.rkt")

(define (make-temp-dir prefix)
  (define dir (make-temporary-file (string-append "movebit-" prefix "-~a") 'directory))
  dir)

;; Save_and_load_roundtrip_all_settings
(let* ([dir (make-temp-dir "cfg")]
       [expected (reminder-config 50 40 7 25 #f 25 30 #f #f #f #t "auto"
                             "L" "lively" "top-right" "always")])
  (check-true (save-config dir expected))
  (define actual (load-config dir))
  (check-equal? (reminder-config-sit-reminder-minutes actual) 50)
  (check-equal? (reminder-config-water-reminder-minutes actual) 40)
  (check-equal? (reminder-config-away-reset-minutes actual) 7)
  (check-equal? (reminder-config-snooze-minutes actual) 25)
  (check-false (reminder-config-micro-break-enabled actual))
  (check-equal? (reminder-config-micro-break-interval-minutes actual) 25)
  (check-equal? (reminder-config-micro-break-duration-seconds actual) 30)
  (check-false (reminder-config-motion-enabled actual))
  (check-false (reminder-config-sound-enabled actual))
  (check-false (reminder-config-auto-check-updates actual))
  (check-true (reminder-config-welcome-shown actual))
  (check-equal? (reminder-config-companion-size actual) "L")
  (check-equal? (reminder-config-companion-motion actual) "lively")
  (check-equal? (reminder-config-companion-dock actual) "top-right")
  (check-equal? (reminder-config-companion-labels actual) "always")
  ;; atomic write: no .tmp residue
  (check-false (file-exists? (build-path dir "config.json.tmp")))
  ;; every write stamps the schema version
  (define on-disk (call-with-input-file (config-path dir) read-json))
  (check-equal? (hash-ref on-disk 'SchemaVersion) config-schema-version)
  (delete-directory/files dir))

;; Dock_top_left_roundtrips_through_the_existing_schema_v2
;; The 4th corner is additive: old profiles and the file version are unchanged.
(let* ([dir (make-temp-dir "dock-top-left")]
       [fresh (default-config)]
       [as-json (hash-set (config->jsexpr fresh) 'CompanionDock "top-left")])
  (define parsed (jsexpr->config as-json))
  (check-equal? (reminder-config-companion-dock parsed) "top-left")
  (check-true (save-config dir parsed))
  (check-equal? (reminder-config-companion-dock (load-config dir)) "top-left")
  (check-equal? (hash-ref (call-with-input-file (config-path dir) read-json)
                          'SchemaVersion)
                config-schema-version)
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
               'SitReminderMinutes 1
               'WaterReminderMinutes 999
               'AwayResetMinutes 0
               'SnoozeMinutes 999
               'MicroBreakIntervalMinutes 1
               'MicroBreakDurationSeconds 999
               'MotionEnabled "yes")
       out)))
  (define actual (load-config dir))
  (check-equal? (reminder-config-sit-reminder-minutes actual) 10)
  (check-equal? (reminder-config-water-reminder-minutes actual) 180)
  (check-equal? (reminder-config-away-reset-minutes actual) 1)
  (check-equal? (reminder-config-snooze-minutes actual) 60)
  (check-equal? (reminder-config-micro-break-interval-minutes actual) 10)
  (check-equal? (reminder-config-micro-break-duration-seconds actual) 60)
  ;; wrong-typed boolean keeps the default, it is not coerced
  (check-true (reminder-config-motion-enabled actual))
  (check-true (reminder-config-auto-check-updates actual))
  (delete-directory/files dir))

;; Corrupt_json_falls_back_to_defaults
(let* ([dir (make-temp-dir "corrupt")]
       [path (build-path dir "config.json")])
  (display-to-file "{ definitely not json" path)
  (define actual (load-config dir))
  (check-equal? (reminder-config-sit-reminder-minutes actual) 45)
  (check-equal? (reminder-config-water-reminder-minutes actual) 30)
  (check-equal? (reminder-config-snooze-minutes actual) 10)
  (check-true (reminder-config-motion-enabled actual))
  (check-true (reminder-config-auto-check-updates actual))
  (delete-directory/files dir))

;; v1_has_one_gentle_experience_no_forced_break_fields_exist
(let* ([fresh (default-config)])
  ;; The struct has no force-break/duration/skip accessors at all — the old
  ;; fullscreen contract cannot come back through config. The default motion
  ;; and sound experience is on; onboarding has not run yet.
  (check-true (reminder-config-motion-enabled fresh))
  (check-true (reminder-config-sound-enabled fresh))
  (check-false (reminder-config-welcome-shown fresh)))

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
  ;; v0.x had no real users: an old file is NOT migrated. A fresh v1 profile
  ;; starts with defaults; the next save overwrites the foreign file.
  (define actual (load-config dir))
  (check-equal? actual (default-config))
  (check-false (reminder-config-welcome-shown actual))
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

;; Partial_v1_file_keeps_defaults_for_missing_keys
(let* ([dir (make-temp-dir "partial")]
       [path (build-path dir "config.json")])
  (display-to-file
   (format "{\"SchemaVersion\": ~a, \"SitReminderMinutes\": 60, \"WelcomeShown\": true}"
           config-schema-version)
   path)
  (define actual (load-config dir))
  (check-equal? (reminder-config-sit-reminder-minutes actual) 60)
  (check-equal? (reminder-config-snooze-minutes actual) 10)
  (check-true (reminder-config-welcome-shown actual))
  (delete-directory/files dir))

;; Save_clamps_out_of_range_values_too (clamp on save, per the port contract)
(let* ([dir (make-temp-dir "saveclamp")])
  (save-config dir (reminder-config 1 999 0 999 #t 1 999 "x" #t #t #f "klingon"
                                   "huge" "fast" "center" "sometimes"))
  (define actual (load-config dir))
  (check-equal? (reminder-config-sit-reminder-minutes actual) 10)
  (check-equal? (reminder-config-water-reminder-minutes actual) 180)
  (check-equal? (reminder-config-snooze-minutes actual) 60)
  (check-true (reminder-config-motion-enabled actual))
  (check-equal? (reminder-config-language actual) "auto")
  ;; unknown companion choices normalize to the shipped defaults
  (check-equal? (reminder-config-companion-size actual) "M")
  (check-equal? (reminder-config-companion-motion actual) "subtle")
  (check-equal? (reminder-config-companion-dock actual) "bottom-right")
  (check-equal? (reminder-config-companion-labels actual) "cue")
  (delete-directory/files dir))
