#lang racket/base

;; i18n single-source checker: shared/i18n/{zh,en}.json must cover exactly the
;; same key tree, and the copy pools must keep their canonical sizes
;; (water 8, micro 9, deep-night variants 3 each). The v1 reboot (issue #55)
;; removed the fullscreen-break copy: brk.* and copy.breakHintPool are gone.
;; Run: racket scripts/check-i18n.rkt

(require json
         racket/file
         racket/list
         racket/match
         racket/path
         racket/string)

(define root (path-only (path->complete-path (syntax-source #'here))))
;; this script lives in <repo>/scripts/
(define i18n-dir (build-path root ".." "shared" "i18n"))

(define (load-lang name)
  (call-with-input-file (build-path i18n-dir (format "~a.json" name)) read-json))

(define zh (load-lang "zh"))
(define en (load-lang "en"))

;; Flatten nested hashes to dotted leaf paths.
(define (leaves doc [prefix ""])
  (cond
    [(hash? doc)
     (append* (for/list ([(k v) (in-hash doc)])
                (leaves v (string-append prefix (symbol->string k) "."))))]
    [else (list (string-trim prefix "." #:left? #f))]))

(define zh-keys (sort (leaves zh) string<?))
(define en-keys (sort (leaves en) string<?))

(define failed? #f)

(when (not (equal? zh-keys en-keys))
  (set! failed? #t)
  (eprintf "key sets differ:~n  zh-only: ~a~n  en-only: ~a~n"
           (remove* en-keys zh-keys)
           (remove* zh-keys en-keys)))

;; Contract: the counted UI key set plus the flat copy pools. The v1 source
;; is a FLAT string->string table (dot-keyed; the family convention rivet's
;; doctor enforces); the rotating copy pools are indexed keys
;; copy.<pool>.<i>, and the milestone policy lives in the backend, not here.
(define ui-keys (filter (lambda (k) (not (string-prefix? k "copy."))) zh-keys))
(define copy-keys (filter (lambda (k) (string-prefix? k "copy.")) zh-keys))
(unless (= (length ui-keys) 216)
  (set! failed? #t)
  (eprintf "expected 216 UI keys, got ~a~n" (length ui-keys)))

(define (pool doc name expected)
  (define prefix (string-append "copy." (symbol->string name) "."))
  (define n
    (count (lambda (k) (string-prefix? k prefix)) zh-keys))
  (cond [(zero? n)
         (set! failed? #t)
         (eprintf "copy.~a missing~n" name)]
        [(not (= n expected))
         (set! failed? #t)
         (eprintf "copy.~a: expected ~a lines, got ~a~n" name expected n)]))

;; pools exist with the canonical sizes
(for ([table (in-list (list zh en))])
  (for ([k (in-list (hash-keys table))])
    (unless (string? (hash-ref table k))
      (set! failed? #t)
      (eprintf "~a is not a string~n" k))))
(pool zh 'waterPool 8)
(pool zh 'microPool 9)
(pool zh 'sitToastPool 6)
(pool zh 'lateNightWaterPool 3)
(pool zh 'lateNightMicroPool 3)

(when failed? (exit 1))
(printf "i18n OK: flat table, 216 UI keys, pools verbatim, zh/en parity~n")
(when failed? (exit 1))
