#lang racket/base

;; Login autostart, port of the old Services/AutoStart.cs — a health tool whose
;; whole value is "always running". Per-platform targets:
;;   macOS   ~/Library/LaunchAgents/com.turlamai.movebit.plist (RunAtLoad)
;;   Linux   $XDG_CONFIG_HOME/autostart/movebit.desktop
;;   Windows HKCU\Software\Microsoft\Windows\CurrentVersion\Run, value "MoveBit"
;; Best-effort exactly like the old app: an enabled check never throws and a
;; failed toggle is swallowed — the app keeps running either way. The exe path
;; and home directory are parameters so tests can run isolated.

(require ffi/unsafe
         racket/file
         racket/path
         racket/port
         racket/string
         (only-in racket/format ~a))

(provide autostart-enabled?
         set-autostart!
         migrate-launch-agent!
         ;; test hooks
         autostart-home
         autostart-executable-path
         launch-agent-label
         launch-agent-path
         legacy-launch-agent-path
         ;; CI probe: surface the errors set-autostart! swallows
         windows-value-present?
         windows-set!)

(define autostart-home
  (make-parameter (find-system-path 'home-dir)))

;; Process-global override for tests and embedded hosts (same pattern as
;; MOVEBIT_DATA_DIR): env wins over the parameter so every thread sees it.
(define (autostart-base-dir)
  (define override (getenv "MOVEBIT_AUTOSTART_HOME"))
  (if (and override (not (string=? override "")))
      (string->path override)
      (autostart-home)))

;; Defaults to the host executable the embedded runtime was booted with
;; (rivet passes the host binary as boot.exec_file). Tests override this.
(define autostart-executable-path
  (make-parameter
   (path->string (find-system-path 'exec-file))))

;; launchd identifiers. `com.turinglambdaai.movebit` is the retired GitHub
;; owner baked into releases up to 0.0.5; renaming it without migration would
;; orphan the plist of every existing install and silently disable autostart
;; (issue #128).
(define launch-agent-label "com.turlamai.movebit")
(define legacy-launch-agent-label "com.turinglambdaai.movebit")

(define (launch-agent-path)
  (build-path (autostart-base-dir) "Library" "LaunchAgents"
              (string-append launch-agent-label ".plist")))

(define (legacy-launch-agent-path)
  (build-path (autostart-base-dir) "Library" "LaunchAgents"
              (string-append legacy-launch-agent-label ".plist")))

;; One-time idempotent migration of the retired-owner LaunchAgent.
;;
;; Deliberately file-based: the running process may itself have been started
;; by the old agent, so `launchctl bootout` could kill the app mid-launch.
;; launchd reads ~/Library/LaunchAgents at login, and the new plist is written
;; with RunAtLoad, so the next login picks it up. Re-registering here (rather
;; than only deleting the old file) preserves the user's enabled choice.
(define (migrate-launch-agent!)
  (with-handlers ([exn:fail? void])
    (define old (legacy-launch-agent-path))
    (when (file-exists? old)
      (define new (launch-agent-path))
      (unless (file-exists? new)
        (write-launch-agent! new))
      (delete-file old))))


(define (xdg-autostart-dir)
  (define xdg (getenv "XDG_CONFIG_HOME"))
  (build-path (if (and xdg (not (string=? xdg "")) (absolute-path? xdg))
                  (string->path xdg)
                  (build-path (autostart-base-dir) ".config"))
              "autostart"))

(define (desktop-entry-path)
  (build-path (xdg-autostart-dir) "movebit.desktop"))

(define (windows-run-key)
  ;; Subkey under HKEY_CURRENT_USER — the HKCU root is the handle, not part
  ;; of the path (RegOpenKeyExW rejects the "HKCU\..." textual form here).
  "Software\\Microsoft\\Windows\\CurrentVersion\\Run")

;; --- enabled? --------------------------------------------------------------

(define (autostart-enabled?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (case (system-type)
      [(windows) (windows-value-present?)]
      [(macosx) (file-exists? (launch-agent-path))]
      [else (file-exists? (desktop-entry-path))])))

;; --- set! ------------------------------------------------------------------

(define (set-autostart! enabled?)
  (with-handlers ([exn:fail? void])
    (case (system-type)
      [(windows) (windows-set! enabled?)]
      [(macosx) (macos-set! enabled?)]
      [else (linux-set! enabled?)])))

;; --- macOS LaunchAgent -----------------------------------------------------

(define (macos-set! enable?)
  (define plist (launch-agent-path))
  (if enable?
      (write-launch-agent! plist)
      (when (file-exists? plist)
        (delete-file plist))))

(define (write-launch-agent! plist)
  (make-directory* (path-only plist))
  (with-output-to-file plist #:exists 'replace
    (lambda ()
      (displayln "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
      (displayln "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \
\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">")
      (displayln "<plist version=\"1.0\">")
      (displayln "<dict>")
      (displayln (~a "  <key>Label</key><string>" launch-agent-label "</string>"))
      (displayln "  <key>ProgramArguments</key>")
      (displayln (~a "  <array><string>" (xml-escape (autostart-executable-path))
                     "</string></array>"))
      (displayln "  <key>RunAtLoad</key><true/>")
      (displayln "</dict>")
      (display "</plist>"))))

(define (xml-escape s)
  (string-append*
   (for/list ([c (in-string s)])
     (case c
       [(#\<) "&lt;"]
       [(#\>) "&gt;"]
       [(#\&) "&amp;"]
       [else (string c)]))))

;; --- Linux XDG autostart ---------------------------------------------------

(define (linux-set! enable?)
  (define entry (desktop-entry-path))
  (if enable?
      (begin
        (make-directory* (path-only entry))
        (with-output-to-file entry #:exists 'replace
          (lambda ()
            (displayln "[Desktop Entry]")
            (displayln "Type=Application")
            (displayln "Name=MoveBit")
            (displayln (~a "Exec=" (quote-desktop-exec (autostart-executable-path))))
            (display "X-GNOME-Autostart-enabled=true"))))
      (when (file-exists? entry)
        (delete-file entry))))

;; Desktop Entry Exec quoting, port of QuoteDesktopExec: double quotes with
;; backslash-escaped backslash, double quote, backtick, and dollar sign.
(define (quote-desktop-exec value)
  (string-append
   "\""
   (string-append*
    (for/list ([c (in-string value)])
      (case c
        [(#\\) "\\\\"]
        [(#\") "\\\""]
        [(#\`) "\\`"]
        [(#\$) "\\$"]
        [else (string c)])))
   "\""))

;; --- Windows HKCU Run key --------------------------------------------------
;; advapi32 bindings fetched lazily via get-ffi-obj: the module loads on every
;; platform (raco test compiles it everywhere), but nothing touches
;; Advapi32.dll until a windows-only code path actually runs. Port of
;; AutoStart.cs: the stored value is REG_SZ with the QUOTED exe path so
;; Program Files style spaces survive command-line parsing.

(require ffi/unsafe)

(define value-name "MoveBit")

(define advapi32-cache #f)

(define (advapi32)
  (unless advapi32-cache
    (set! advapi32-cache (ffi-lib "Advapi32.dll")))
  advapi32-cache)

(define (_HKEY-type) _fpointer)
(define (key-read)  #x20019)  ; KEY_READ
(define (key-write) #x20006)  ; KEY_SET_VALUE
(define reg-sz 1)

(define (reg-open)
  (get-ffi-obj "RegOpenKeyExW" (advapi32)
               (_fun _fpointer _string/utf-16 _uint32 _uint32
                     (out : (_ptr o _fpointer)) -> (rcode : _sint32)
                     -> (values rcode out))))
(define (reg-close)
  (get-ffi-obj "RegCloseKey" (advapi32) (_fun _fpointer -> _sint32)))
(define (reg-query)
  (get-ffi-obj "RegQueryValueExW" (advapi32)
               (_fun _fpointer _string/utf-16 _pointer _pointer _pointer
                     _pointer -> _sint32)))
(define (reg-set)
  (get-ffi-obj "RegSetValueExW" (advapi32)
               (_fun _fpointer _string/utf-16 _uint32 _uint32 _bytes _uint32
                     -> _sint32)))
(define (reg-delete)
  (get-ffi-obj "RegDeleteValueW" (advapi32)
               (_fun _fpointer _string/utf-16 -> _sint32)))
(define (reg-create)
  ;; Port of AutoStart.cs CreateSubKey(writable: true): the Run key and its
  ;; parents are created when missing instead of failing the toggle.
  (get-ffi-obj "RegCreateKeyExW" (advapi32)
               (_fun _fpointer _string/utf-16 _uint32 _pointer _uint32 _uint32
                     _pointer (out : (_ptr o _fpointer))
                     (_disposition : (_ptr o _uint32))
                     -> (rcode : _sint32)
                     -> (values rcode out))))

(define hkey-current-user (cast #x80000001 _sint64 _fpointer))

(define (call-with-run-key access proc)
  (define-values (rcode key)
    ((reg-open) hkey-current-user (windows-run-key) 0 access))
  (unless (zero? rcode)
    (error 'autostart "RegOpenKeyExW failed: ~a" rcode))
  (dynamic-wind
    void
    (lambda () (proc key))
    (lambda () ((reg-close) key))))

(define (call-with-run-key-create proc)
  (define-values (rcode key)
    ((reg-create) hkey-current-user (windows-run-key) 0 #f 0 (key-write) #f))
  (unless (zero? rcode)
    (error 'autostart "RegCreateKeyExW failed: ~a" rcode))
  (dynamic-wind
    void
    (lambda () (proc key))
    (lambda () ((reg-close) key))))

(define (windows-value-present?)
  (call-with-run-key
   (key-read)
   (lambda (key)
     ;; Ask with a bounded buffer; ERROR_SUCCESS means the value exists.
     (define size (malloc 4 'raw))
     (define data (malloc 1024 'raw))
     (dynamic-wind
       void
       (lambda ()
         (ptr-set! size _uint32 1024)
         (zero? ((reg-query) key value-name #f #f data size)))
       (lambda () (free size) (free data))))))

(define (windows-set! enable?)
  (call-with-run-key-create
   (lambda (key)
     (cond
       [enable?
        (define value
          (string->bytes/utf-8
           (string-append "\"" (autostart-executable-path) "\"\0")))
        (define code ((reg-set) key value-name 0 reg-sz
                      value (bytes-length value)))
        (unless (zero? code)
          (error 'autostart "RegSetValueExW failed: ~a" code))]
       [else
        (define code ((reg-delete) key value-name))
        ;; 2 = ERROR_FILE_NOT_FOUND: already absent is success.
        (unless (or (zero? code) (= code 2))
          (error 'autostart "RegDeleteValueW failed: ~a" code))]))))
