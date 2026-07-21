# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# safe — CVD-safe palette registry + confusability audit. The embedded safe
# palettes (Okabe-Ito, ColorBrewer Set1, viridis — shipped in palette/safe) are
# REGISTERED here by name and AUDITED for CVD-safety: under each of the three
# dichromacies (protan/deuter/tritan) at severity 1.0, no pair of colors may
# collapse below the JND threshold (ΔE_OK < TOL_JND = 0.02). This makes the
# "CVD-safe by design" property verifiable instead of asserted.
#
# Design boundary: ACHROMATOPSIA is EXCLUDED from the audit. Monochromats see
# luminance only, so EVERY palette collapses for them (any two colors of equal
# luma become identical) — no palette can be "safe" for achromatopsia. The
# CVD-safety claim targets the DICHROMACIES, which is what Okabe-Ito /
# ColorBrewer / viridis are designed for. Including achromatopsia would make
# `isCvdSafe` always false (useless); excluding it is the standard convention.
#
# Consumer of the core (conversion/to, contrast/distance for ΔE_OK) and of
# palette/safe (the embedded data) + accessibility/cvd (the simulation). It
# does NOT re-ship the palette data — it wraps the palette/safe builders in a
# named registry. All procs pure: no mutation, deterministic, no side effects.
import std/options
import std/tables
import std/math # `min` on float64.
import UniColor/core/core
import UniColor/contrast/contrast # `distance(a, b, "deltaE_ok")`.
import UniColor/palette/types
import UniColor/palette/safe # okabeIto / viridis / colorBrewer (embedded refs).
import UniColor/accessibility/cvd # simulateCvd / cvdReport / CvdType.

# Default audit parameters: the JND threshold (two colors below this ΔE_OK are
# perceptually identical) and full dichromat severity 1.0 (the conservative
# worst case — the claim must hold even for a complete dichromat).
const
  DefaultCvdSafeThreshold* = TOL_JND ## ΔE_OK below which two colors are
                                     ## confusable (JND 0.02).
  DefaultCvdAuditSeverity* = 1.0     ## full dichromat (worst case).

type
  SafePaletteRef* = object
    ## Descriptor for a registered CVD-safe reference palette (data-driven like
    ## the CVD/metric registries). `build(n)` returns the palette; `n` is the
    ## requested color count (viridis/ColorBrewer honor it; Okabe-Ito is a
    ## fixed 8-color set and ignores `n`).
    name*: string
    build*: proc(n: int): Result[Palette, ColorError] {.raises: [].}

  SafeAudit* = object
    ## CVD-safety audit of a palette: for each dichromacy (protan/deuter/tritan)
    ## at `severity`, whether any pair collapsed below `threshold` (False = a
    ## confusable pair was found). `safe` is the conjunction of the three.
    ## `minDeltaE` is the closest any pair got under ANY of the three
    ## dichromacies (the worst-case confusability margin). Achromatopsia is NOT
    ## audited (monochromats — see module doc).
    name*: string
    threshold*: float64
    severity*: float64
    protanSafe*: bool
    deuterSafe*: bool
    tritanSafe*: bool
    minDeltaE*: float64
    safe*: bool

# Registry — module-level table, idempotent registration, optional seal.
# Extensible: a downstream user can register their own CVD-safe reference.
var
  safeByName: Table[string, SafePaletteRef]
  safeSealed: bool

proc registerSafePalette*(refp: SafePaletteRef): bool {.raises: [].} =
  ## Register a safe palette by name. Idempotent: a sealed registry or an
  ## empty/duplicate name is rejected (returns false).
  if safeSealed or refp.name.len == 0 or safeByName.hasKey(refp.name) or
      refp.build.isNil:
    return false
  safeByName[refp.name] = refp
  true

proc lookupSafePalette*(name: string): Option[SafePaletteRef] {.raises: [].} =
  if safeByName.hasKey(name):
    some(safeByName.getOrDefault(name))
  else:
    none(SafePaletteRef)

proc safePaletteCount*(): int {.raises: [].} =
  safeByName.len

proc safeNames*(): seq[string] {.raises: [].} =
  result = @[]
  for k in keys(safeByName):
    result.add(k)

proc sealSafePalettes*() {.raises: [].} =
  safeSealed = true

proc safePalette*(name: string, n: int): Result[Palette, ColorError] {.
    raises: [].} =
  ## Build a registered safe palette by name with `n` colors. Unknown name ->
  ## `UnknownAlgorithm`. The per-builder validation (viridis n>=1, ColorBrewer
  ## 1<=n<=9) is delegated to palette/safe.
  let m = lookupSafePalette(name)
  if m.isNone:
    return err[Palette, ColorError](colorError(UnknownAlgorithm,
        "unknown safe palette: " & name, "safePalette"))
  m.get.build(n)

# Whether a palette's colors stay pairwise distinguishable (ΔE_OK >= threshold)
# under one CVD type. Uses `cvdReport` for the confusability machinery; returns
# the closest pair distance (worst margin) and whether that closest pair is
# still above threshold (safe for this deficiency).
proc auditOneDichromacy(colors: openArray[Color], t: CvdType, severity,
    threshold: float64): tuple[safe: bool, minDeltaE: float64] {.raises: [].} =
  let rep = cvdReport(colors, DefaultCvdModel, t, severity, threshold)
  # `rep.pairs` holds the confusable pairs (ΔE_OK < threshold); none -> safe.
  # For the closest pair we recompute the min (cvdReport only reports the max).
  var mn = 1.0e9
  let sim = rep.simulated
  for i in 0 ..< sim.len:
    for j in (i + 1) ..< sim.len:
      let dR = distance(sim[i], sim[j], "deltaE_ok")
      if dR.isOk and dR.get < mn:
        mn = dR.get
  if mn > 1.0e8:
    mn = Inf # empty / single-color: no pairs -> infinite margin (vacuously
             # safe), matching minPairwiseDeltaE's convention so the cvdSafe
             # constraint does not flag a pairless palette (threshold - Inf = 0).
  (rep.pairs.len == 0, mn)

proc auditSafeColors*(colors: openArray[Color],
    threshold = DefaultCvdSafeThreshold, severity = DefaultCvdAuditSeverity,
    name = ""): SafeAudit {.raises: [].} =
  ## Audit a palette's CVD-safety across the three dichromacies (protan/deuter/
  ## tritan) at `severity` (default full dichromat). A pair collapsing below
  ## `threshold` (default JND) under any dichromacy makes the palette NOT safe.
  ## `minDeltaE` is the worst-case confusability margin over the three
  ## dichromacies. Achromatopsia is NOT audited (monochromats — module doc).
  ## Deterministic, no input mutation.
  let (ps, pm) = auditOneDichromacy(colors, cvdProtanopia, severity, threshold)
  let (ds, dm) = auditOneDichromacy(colors, cvdDeuteranopia, severity, threshold)
  let (ts, tm) = auditOneDichromacy(colors, cvdTritanopia, severity, threshold)
  let worst = min(min(pm, dm), tm)
  SafeAudit(name: name, threshold: threshold, severity: severity,
      protanSafe: ps, deuterSafe: ds, tritanSafe: ts, minDeltaE: worst,
      safe: ps and ds and ts)

proc auditSafePalette*(name: string, n: int,
    threshold = DefaultCvdSafeThreshold,
    severity = DefaultCvdAuditSeverity): Result[SafeAudit,
    ColorError] {.raises: [].} =
  ## Build a registered safe palette by name and audit it (see
  ## `auditSafeColors`). Unknown name -> `UnknownAlgorithm`; builder error
  ## propagates.
  let pR = safePalette(name, n)
  if pR.isErr:
    return err[SafeAudit, ColorError](pR.error)
  ok[SafeAudit, ColorError](auditSafeColors(pR.get.colors, threshold, severity,
      name))

proc isCvdSafe*(colors: openArray[Color], threshold = DefaultCvdSafeThreshold,
    severity = DefaultCvdAuditSeverity): bool {.raises: [].} =
  ## Convenience: whether `colors` are CVD-safe across the three dichromacies
  ## (no confusable pair under any). See `auditSafeColors` for the full report.
  auditSafeColors(colors, threshold, severity).safe

# Bootstrap — register the three embedded CVD-safe references. Okabe-Ito is a
# fixed 8-color set (ignores `n`); ColorBrewer Set1 honors `n` (1..9); viridis
# honors `n` (>=1).
proc buildOkabeIto(n: int): Result[Palette, ColorError] {.raises: [].} =
  discard n # fixed 8-color set; the count is part of the reference, not a param.
  ok[Palette, ColorError](okabeIto())

proc buildColorBrewerSet1(n: int): Result[Palette, ColorError] {.raises: [].} =
  colorBrewer("Set1", n)

proc buildViridis(n: int): Result[Palette, ColorError] {.raises: [].} =
  viridis(n)

discard registerSafePalette(SafePaletteRef(name: "okabeIto",
    build: buildOkabeIto))
discard registerSafePalette(SafePaletteRef(name: "colorBrewerSet1",
    build: buildColorBrewerSet1))
discard registerSafePalette(SafePaletteRef(name: "viridis",
    build: buildViridis))
