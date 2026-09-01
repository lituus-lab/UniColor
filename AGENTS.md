<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# AGENTS.md — UniColor

## Build & gates

```bash
nimble install -y
nimble testAll    # Nim debug + release + C ABI
nimble pyTest     # Cython + pytest (needs libUniColor.so)
nimble example
nimble coverage   # gcov + lcov -> coverage/ (needs lcov; linux/macOS)
nimble docs       # nimib book + API reference -> pages/ (needs nimib)
```

`nimble docs` needs a complete Nim distribution: `--project` builds `dochack`,
which Homebrew's `nim` omits (no `tools/`). choosenim and the CI action ship it.

CI: 3-OS Nim matrix + C ABI (linux/macOS) + Python.

## Conventions

- English comments, terse, describe what is done. No "deprecated".
- NimContracts `{.contractual.}` + `require:`/`ensure:`/`body:`, compiled away
  under `-d:release`. C ABI never raises — it clamps out-of-range input.
- A postcondition is cheaper than the body: never re-derives the result by
  calling the function itself.
- C ABI: hand-written `include/UniColor.h` kept in sync with
  `src/UniColor/c_api.nim`; `tests/c` links the header against the lib.
  Built `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release`.
- C symbols `uc_*`; lib `libUniColor`; header `UniColor.h`.
- C ABI error model (ADR-0004): no error codes. Color procs return a sentinel
  `uc_color` (`tag == UC_TAG_UNKNOWN`); numeric procs return NaN; string procs
  use a measure+fill buffer (`size_t f(..., char* buf, size_t size)` returns
  the required length, 0 on failure); handle procs return NULL. The host MUST
  call `uc_init()` once first — it runs `NimMain`, populating the contrast /
  import / export / spaces / validation registries.
- `book/index.nim` is nimib: its code blocks are compiled and run at docs build,
  so prose that outlives its API breaks the build. `py/notebooks/quickstart.ipynb`
  plays the same role for Python and renders natively on GitHub.
- End covered sources with a blank line. Nim maps a trailing statement one line
  past EOF. `nimble coverage` suppresses exactly two lcov categories, both
  compiler artefacts with no source-level fix: `mismatch`, where lcov 2.x and
  gcov disagree on the end line of Nim's generated destructors, and `range`,
  that EOF + 1 attribution, which `--filter range` drops. Every other error
  still fails the build.

## Scope

Perceptual color engine: color spaces, conversions through the XYZ hub,
contrast metrics, interpolation, palettes, themes, and accessibility. No
image file codecs — `image/` operates on raw pixel buffers already in
memory. Apache-2.0, DCO.
