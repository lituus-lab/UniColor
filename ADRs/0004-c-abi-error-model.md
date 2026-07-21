<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0004: C ABI error model

- Status: Accepted
- Date: 2026-07-21
- Scope: every `uc_*` C ABI function

## Decision

The C ABI never raises and carries no error-code return type. Failure is
reported in-band, by return type:

- **Color-producing procs** return the sentinel `uc_color`
  (`tag == UC_TAG_UNKNOWN`) on invalid input (unknown space, out-of-range
  alpha, a non-finite component). The validating constructor never emits it
  otherwise, so a non-zero tag is always a real color.
- **Numeric procs** (contrast, distance) return `NaN` on a sentinel operand,
  an unknown metric, or a computation failure.
- **String-producing procs** use a measure+fill buffer:
  `size_t f(..., char *buf, size_t size)` returns the required length
  (excluding the NUL); passing `buf = NULL` or `size = 0` measures without
  writing.
- **Handle-producing procs** (theme/palette/import/validation, added later)
  return `NULL`.

Several C ABI functions read from registries (contrast metrics, color
spaces, import/export formats, validation rules) populated by Nim
module-init side effects. The host must call `uc_init()` once before any
registry-based proc — it runs `NimMain` under the hood.
