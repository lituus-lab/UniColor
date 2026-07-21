# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# import/partial — partial-failure helpers. The TOKEN-LEVEL partial-failure
# framework shared by every format importer. The partial-failure model: the
# import does NOT fail globally on an unreadable token — it continues,
# collects the error as a PaletteWarning, returns the PARTIAL theme + Report.
# Only a FATAL (unreadable structure, schema < min without migration) -> `err
# ImportFailed`. The strict knob (`opts.strict`) selects the mode:
#   - `strict = false` (default, `defaultImportOpts`) — best-effort: unreadable
#     token -> SKIP + `warnInvalidToken` PaletteWarning + continue (partial
#     theme + Report).
#   - `strict = true` — hard-fail: the same unreadable token -> `err
#     InvalidColor` (the pre-partial behavior, now opt-in).
#
# DUPLICATE ROLE ("duplicate -> last value wins + warning (deterministic)"):
# the import collects role->color in a Table; when a role is set TWICE with a
# DIFFERENT color, last-wins + a `warnDuplicateRole` PaletteWarning. A re-set
# with the SAME color (a format's overlapping slots — one role projected to
# multiple slots carry the SAME hex) is NOT a conflict — it is the inverse
# projection collapsing a known overlap, so NO warning (this preserves the
# byte-identical round-trip without spurious warnings). The warning fires on a
# REAL conflict (different colors), not on an idempotent re-set.
#
# Order-stable aggregation: warnings are appended in source order (no re-sort)
# — a deterministic, reproducible Report. No RNG, no I/O. `import` is a Nim
# keyword -> quoted import where needed.
#
# Layer: import (consumer of core + palette/unsatisfiable + the registry
# types).
import std/options
import std/tables
import UniColor/core/result
import UniColor/core/core # Color.
import UniColor/core/color_error
import UniColor/palette/unsatisfiable # PaletteWarning / WarningCode.
import "UniColor/import/registry" # ImportOpts.

# Accumulates recoverable warnings (skipped token, duplicate-role conflict) in
# source order (order-stable). Passed by `var` into the importer's parse loop;
# flushed into the `ImportReport.warnings` at the end.
type PartialCollector* = object
  warnings*: seq[PaletteWarning]

# Decide the fate of a color-read `Result`. Returns:
#   `ok(some(color))` — a usable color (the read succeeded).
#   `ok(none(Color))` — RECOVERABLE: the read failed, the token is SKIPPED, a
#     `warnInvalidToken` PaletteWarning was appended to `coll` (best-effort
#     mode, `opts.strict = false`). The caller skips this role and continues.
#   `err(e)` — FATAL in strict mode (`opts.strict = true`): propagate
#     `InvalidColor` (hard-fail).
# `role`/`formatName` give the warning its context. The warning is NON-SILENT
# (an unreadable token is always reported, never swallowed).
proc readColorOrSkip*(cR: Result[Color, ColorError], role, formatName: string,
    opts: ImportOpts, coll: var PartialCollector): Result[Option[Color],
    ColorError] {.raises: [].} =
  if cR.isOk:
    return ok[Option[Color], ColorError](some(cR.get))
  if opts.strict:
    return err[Option[Color], ColorError](cR.error)
  coll.warnings.add(PaletteWarning(code: warnInvalidToken,
      message: formatName & ": role '" & role & "' skipped — " &
      cR.error.message, context: role))
  ok[Option[Color], ColorError](none(Color))

# Insert a role->color into the dedup table with the duplicate rule.
# `last-wins`: the new color always replaces the old. A `warnDuplicateRole`
# PaletteWarning is appended ONLY when the role was already present AND the new
# color DIFFERS from the existing one (a REAL conflict — a third-party file
# defining the same role twice with different values). A re-set with the SAME
# color (a format's overlapping slots carry the same hex) is idempotent -> NO
# warning (the inverse projection collapsing a known overlap is not a
# conflict). `opts.strict` does NOT escalate a duplicate to an error (a
# duplicate is recoverable, not fatal).
proc setRoleDedup*(table: var Table[string, Color], role: string,
    color: Color, formatName: string,
    coll: var PartialCollector): void {.raises: [].} =
  if table.hasKey(role):
    if table.getOrDefault(role) != color:
      coll.warnings.add(PaletteWarning(code: warnDuplicateRole,
          message: formatName & ": role '" & role &
          "' defined twice with different colors — last value wins",
          context: role))
  table[role] = color
