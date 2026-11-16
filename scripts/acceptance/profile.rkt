#lang racket/base

;; Native acceptance uses the real storage API, never retired JSON fixtures.
(require racket/cmdline racket/match "../../racket/movebit/config.rkt")
(command-line
 #:args (action directory)
 (match action
   ["seed"
    (unless (save-config directory
                        (struct-copy reminder-config (default-config)
                                     [welcome-shown #t] [language "en"]
                                     [sound-enabled #f] [auto-check-updates #f]))
      (error 'acceptance-profile "could not initialize the isolated SQLite profile"))]
   ["position"
    (define c (load-config directory))
    (printf "~a ~a\n" (reminder-config-companion-free-x c) (reminder-config-companion-free-y c))]
   [_ (error 'acceptance-profile "expected seed or position")]))
