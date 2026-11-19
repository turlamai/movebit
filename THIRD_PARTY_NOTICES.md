# Third-party notices

MoveBit builds on the components below. Each entry names where the
component enters the shipped artifacts and the license it is distributed
under; consult the upstream license files for full terms. The Rivet
toolchain and Permit are first-party TurLamAI projects (MIT) consumed as
pinned packages — not third-party code — so they are not listed here.

## Racket CS runtime

Every platform host embeds the statically linked Racket CS runtime
([racket/racket](https://github.com/racket/racket), 9.x). Racket is
distributed under the MIT license and the Apache License 2.0, at your
option; the Racket CS runtime system additionally embeds Chez Scheme,
distributed under the Apache License 2.0 (per Racket's `LICENSE.txt`).
