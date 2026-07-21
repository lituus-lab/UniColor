<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0003: C ABI and Python binding

- Status: Accepted
- Date: 2026-07-21
- Scope: `src/UniColor/c_api.nim`, `include/UniColor.h`, `py/`

## Decision

- The engine is pure Nim; a thin C ABI (`src/UniColor/c_api.nim`) is the only
  supported entry point for foreign callers, built
  `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release` into
  `libUniColor.a` / `libUniColor.so`.
- The C header (`include/UniColor.h`) is hand-written and kept in sync with
  `c_api.nim`; `tests/c` links the header against the built lib, so a
  renamed or retyped symbol fails to link — the C test is the ABI drift
  detector. Nim's `--header:` auto-generation is not used.
- `--mm:arc`: a deterministic memory model for foreign callers, with no
  cycle collector running behind the host's back. `--noMain`: the host
  controls when `NimMain` runs (ADR-0004).
- The Python binding is a Cython extension over the shared library, with the
  library's RPATH set to `$ORIGIN` so the wheel is self-contained.
