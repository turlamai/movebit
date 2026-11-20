#lang racket/base
(require json racket/file racket/path racket/system)
;; Packaged acceptance exists only on the shipped platforms (issue #169).
;; Linux machines still run the engine suites (raco test racket/); they have
;; no native host to package.
(define platform (case (system-type 'os) [(windows) "windows"] [(macosx) "macos"] [else (error 'acceptance "unsupported platform")]))
(define raco (or (find-executable-path "raco") (error 'acceptance "raco was not found")))
(unless (system* raco "rivet" "package" "--skip-launch-smoke") (error 'acceptance "package failed"))
(define output (build-path ".rivet" "acceptance" platform))
(make-directory* output)
(call-with-output-file (build-path output "package.json") #:exists 'truncate/replace
  (lambda (out) (write-json (hash 'platform platform 'package-verified #t) out) (newline out)))
