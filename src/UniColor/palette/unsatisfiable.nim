# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# palette/unsatisfiable — best-effort palette + warnings when constraints
# cannot be met. A generator that cannot satisfy its constraints must NEVER
# silently swallow the failure. Two entry points:
#   - `satisfy`: the generation path — returns the best-effort palette + a
#     non-empty warning list when unsatisfied (caller sees the compromise).
#   - `requireSatisfied`: the strict path — `ok(palette)` or `err(Unsatisfiable)`.
# Best-effort here is the INPUT palette unchanged: `optim` is the repair engine;
# this module only reports and never hides (no speculative in-place repair).
import UniColor/core/core
import UniColor/palette/types
import UniColor/palette/constraints

type
  WarningCode* {.pure.} = enum
    warnContrastLow   ## a fg/bg pair below the WCAG threshold.
    warnGamutClamped  ## a color needed gamut reduction.
    warnInfoLost      ## information lost (terminal projection).
    warnDeprecated    ## legacy schema/palette (identifier retained for ABI).
    warnUnsatisfiable ## generic constraint violation (ΔE_OK, monotonic, uniform).
    warnInvalidToken  ## an unreadable color token was skipped (import partial).
    warnDuplicateRole ## a role defined twice with different colors; last wins.

  PaletteWarning* = object
    code*: WarningCode
    message*: string
    context*: string ## the offending constraint name.

  PaletteReport* = object
    satisfied*: bool
    palette*: Palette ## best-effort palette (input unchanged when unsatisfied).
    warnings*: seq[PaletteWarning]

# Map a constraint name to its warning code. Contrast -> contrast-low, gamut ->
# gamut-clamped; everything else (ΔE_OK, monotonic, uniform) -> unsatisfiable.
proc codeFor(name: string): WarningCode {.raises: [].} =
  if name == "minContrast": warnContrastLow
  elif name == "gamutTarget": warnGamutClamped
  else: warnUnsatisfiable

proc satisfy*(p: Palette, constraints: openArray[
    Constraint]): PaletteReport {.raises: [].} =
  ## Best-effort generation path: evaluate the constraints; if all are satisfied
  ## return the palette with no warnings, otherwise return the SAME palette
  ## (best-effort, unchanged — repair is the optimiser's job) plus one
  ## `PaletteWarning` per violated constraint. Never silent: an unsatisfied
  ## palette always carries at least one warning.
  let report = checkConstraints(p.colors, constraints)
  var warnings: seq[PaletteWarning] = @[]
  if not report.satisfied:
    for r in report.results:
      if not r.satisfied:
        warnings.add(PaletteWarning(code: codeFor(r.name), message: r.message,
            context: r.name))
  PaletteReport(satisfied: report.satisfied, palette: p, warnings: warnings)

proc requireSatisfied*(p: Palette, constraints: openArray[Constraint]): Result[
    Palette, ColorError] {.raises: [].} =
  ## Strict path: `ok(palette)` when all constraints hold, otherwise
  ## `err(Unsatisfiable)` whose message names every violated constraint. The
  ## palette is NOT returned on failure — use `satisfy` for the best-effort
  ## variant.
  let report = checkConstraints(p.colors, constraints)
  if report.satisfied:
    return ok[Palette, ColorError](p)
  var names = ""
  for r in report.results:
    if not r.satisfied:
      if names.len > 0:
        names.add(", ")
      names.add(r.name)
  err[Palette, ColorError](colorError(Unsatisfiable,
      "palette does not satisfy: " & names, "requireSatisfied"))
