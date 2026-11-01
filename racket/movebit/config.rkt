#lang racket/base

;; MoveBit v1 reminder settings. The v1 reboot (issue #55) broke the old
;; .NET-era PascalCase format on purpose: a file without the v1 schema marker
;; is foreign and falls back to defaults — clean-install only, no migration
;; code, no legacy field compatibility. The marker also future-proofs reads:
;; anything this build does not understand is ignored in favor of defaults,
;; and every write stamps the current version.
;;
;; Numeric settings are clamped on load AND save; a corrupt or unreadable file
;; silently falls back to defaults — a tray app must never crash on config.

(require json
         racket/bool
         racket/file
         racket/math)

(provide config-schema-version
         (struct-out reminder-config)
         default-config
         clamp-config
         config->jsexpr
         jsexpr->config
         load-config
         save-config
         config-path)

;; Bump only for a breaking on-disk change; readers reject other versions.
(define config-schema-version 2)

(struct reminder-config
  (sit-reminder-minutes      ; 45 (10-240, UI step 5)
   water-reminder-minutes    ; 30 (5-180, UI step 5)
   away-reset-minutes        ; 5  (1-60)
   snooze-minutes            ; 10 (5-60, UI step 5)
   micro-break-enabled       ; #t
   micro-break-interval-minutes ; 30 (10-60)
   micro-break-duration-seconds ; 20 (10-60) — suggested eye-rest length
   motion-enabled            ; #t — character animation; #f = static cues
   sound-enabled             ; #t
   auto-check-updates        ; #t
   welcome-shown             ; #f
   language                  ; "auto" | "zh" | "en"
   companion-size            ; "S" | "M" | "L" — Mubi BODY height 60/78/104
   companion-motion          ; "still" | "subtle" | "lively"
   companion-dock            ; "bottom-right" | "bottom-left" | "top-right" | "top-left"
   companion-labels)         ; "always" | "cue"
  #:transparent)

;; v1 has exactly one reminder experience: gentle character-delivered cues.
;; The old force-break/duration/skip fields are gone by design.
(define (default-config)
  (reminder-config 45 30 5 10 #t 30 20 #t #t #t #f "auto"
                   "M" "subtle" "bottom-right" "cue"))

(define (clamp v lo hi) (min (max v lo) hi))

(define (valid-language? v) (and (string? v) (member v '("auto" "zh" "en"))))

(define (valid-choice? v choices)
  (and (string? v) (member v choices) #t))

(define companion-size-choices '("S" "M" "L"))
(define companion-motion-choices '("still" "subtle" "lively"))
(define companion-dock-choices '("bottom-right" "bottom-left" "top-right" "top-left"))
(define companion-labels-choices '("always" "cue"))

(define (bool-field c accessor)
  (define v (accessor c))
  (if (boolean? v) v (not (false? v))))

;; Clamp every numeric field and normalize language. Applied on load, on save,
;; and on every RPC write — a persisted file can never drift out of range.
(define (clamp-config c)
  (reminder-config
   (clamp (exact-floor (reminder-config-sit-reminder-minutes c)) 10 240)
   (clamp (exact-floor (reminder-config-water-reminder-minutes c)) 5 180)
   (clamp (exact-floor (reminder-config-away-reset-minutes c)) 1 60)
   (clamp (exact-floor (reminder-config-snooze-minutes c)) 5 60)
   (bool-field c reminder-config-micro-break-enabled)
   (clamp (exact-floor (reminder-config-micro-break-interval-minutes c)) 10 60)
   (clamp (exact-floor (reminder-config-micro-break-duration-seconds c)) 10 60)
   (bool-field c reminder-config-motion-enabled)
   (bool-field c reminder-config-sound-enabled)
   (bool-field c reminder-config-auto-check-updates)
   (bool-field c reminder-config-welcome-shown)
   (let ([lang (reminder-config-language c)])
     (if (valid-language? lang) lang "auto"))
   (let ([v (reminder-config-companion-size c)])
     (if (valid-choice? v companion-size-choices) v "M"))
   (let ([v (reminder-config-companion-motion c)])
     (if (valid-choice? v companion-motion-choices) v "subtle"))
   (let ([v (reminder-config-companion-dock c)])
     (if (valid-choice? v companion-dock-choices) v "bottom-right"))
   (let ([v (reminder-config-companion-labels c)])
     (if (valid-choice? v companion-labels-choices) v "cue"))))

(define (config->jsexpr c)
  (define clamped (clamp-config c))
  (hasheq 'SchemaVersion config-schema-version
          'SitReminderMinutes (reminder-config-sit-reminder-minutes clamped)
          'WaterReminderMinutes (reminder-config-water-reminder-minutes clamped)
          'AwayResetMinutes (reminder-config-away-reset-minutes clamped)
          'SnoozeMinutes (reminder-config-snooze-minutes clamped)
          'MicroBreakEnabled (reminder-config-micro-break-enabled clamped)
          'MicroBreakIntervalMinutes (reminder-config-micro-break-interval-minutes clamped)
          'MicroBreakDurationSeconds (reminder-config-micro-break-duration-seconds clamped)
          'MotionEnabled (reminder-config-motion-enabled clamped)
          'SoundEnabled (reminder-config-sound-enabled clamped)
          'AutoCheckUpdates (reminder-config-auto-check-updates clamped)
          'WelcomeShown (reminder-config-welcome-shown clamped)
          'Language (reminder-config-language clamped)
          'CompanionSize (reminder-config-companion-size clamped)
          'CompanionMotion (reminder-config-companion-motion clamped)
          'CompanionDock (reminder-config-companion-dock clamped)
          'CompanionLabels (reminder-config-companion-labels clamped)))

;; Tolerant reader with a hard version gate: a file written by another schema
;; (v0.x PascalCase, future versions) is foreign — use defaults, never guess.
;; Within the known version, missing keys keep defaults, wrong-typed values
;; keep defaults, numerics are clamped.
(define (jsexpr->config js)
  (cond
    [(and (hash? js)
          (eq? (hash-ref js 'SchemaVersion #f) config-schema-version))
     (define (int-field key default lo hi)
       (define v (hash-ref js key default))
       (if (exact-integer? v) (clamp v lo hi) default))
     (define (bool-field key default)
       (define v (hash-ref js key default))
       (if (boolean? v) v default))
     (reminder-config
      (int-field 'SitReminderMinutes 45 10 240)
      (int-field 'WaterReminderMinutes 30 5 180)
      (int-field 'AwayResetMinutes 5 1 60)
      (int-field 'SnoozeMinutes 10 5 60)
      (bool-field 'MicroBreakEnabled #t)
      (int-field 'MicroBreakIntervalMinutes 30 10 60)
      (int-field 'MicroBreakDurationSeconds 20 10 60)
      (bool-field 'MotionEnabled #t)
      (bool-field 'SoundEnabled #t)
      (bool-field 'AutoCheckUpdates #t)
      (bool-field 'WelcomeShown #f)
      (let ([lang (hash-ref js 'Language "auto")])
        (if (valid-language? lang) lang "auto"))
      (let ([v (hash-ref js 'CompanionSize "M")])
        (if (valid-choice? v companion-size-choices) v "M"))
      (let ([v (hash-ref js 'CompanionMotion "subtle")])
        (if (valid-choice? v companion-motion-choices) v "subtle"))
      (let ([v (hash-ref js 'CompanionDock "bottom-right")])
        (if (valid-choice? v companion-dock-choices) v "bottom-right"))
      (let ([v (hash-ref js 'CompanionLabels "cue")])
        (if (valid-choice? v companion-labels-choices) v "cue")))]
    [else (default-config)]))

(define (config-path directory)
  (build-path directory "config.json"))

;; Load config.json from the given directory. Any read/parse problem falls
;; back to defaults (same failure posture as v0.x: a tray app keeps working).
(define (load-config directory)
  (define path (config-path directory))
  (with-handlers ([exn:fail? (lambda (_) (default-config))])
    (define js
      (call-with-input-file path read-json))
    (jsexpr->config js)))

;; Atomic write: config.json.tmp -> rename. Returns #t when the file reached
;; disk, #f otherwise (reminders keep working from in-memory settings).
(define (save-config directory config)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define path (config-path directory))
    (define tmp (build-path directory "config.json.tmp"))
    (make-directory* directory)
    (call-with-output-file tmp
      (lambda (out)
        (write-json (config->jsexpr (clamp-config config)) out)
        (newline out))
      #:exists 'replace)
    (rename-file-or-directory tmp path #t)
    #t))
