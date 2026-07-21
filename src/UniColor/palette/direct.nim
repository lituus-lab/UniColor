# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# palette/direct — direct palette generation (golden angle + harmonies). Direct
# resolution O(1)/color — no randomness, so `seed=0` is canonical (the seed
# parameter is for the optimization generators, not here). Golden angle:
# h_i = (h_0 + i·φ) mod 360 with FIXED lightness/chroma. Harmonies rotate the
# base hue in OKLCH, preserving the base L/C (only hue rotates). Colors are
# built DIRECTLY in OKLCH and stored as-is — the generation space — so the hue
# is exact (no round-trip); a caller wanting sRGB converts with `.to(tagSrgb)`.
# All generators are pure functions of their inputs (deterministic). Results are
# `palUnordered` qualitative palettes (`intentQualitative`).
import std/math # `mod` on floats (hue normalization).
import UniColor/core/core
import UniColor/conversion/conversion # `to` (read base in OKLCH/HSL).
import UniColor/palette/types

const GoldenAngleDeg* = 137.508'f64 ## golden angle φ; h_i = h_0 + i·φ mod 360.

# Read the base color in OKLCH and build a rotated/offset color directly in
# OKLCH (exact hue, no round-trip). `deltaDeg` is added to the base hue; L and C
# are taken from `base` (harmonies) or overridden (golden angle). Alpha is
# preserved from the base.
proc oklchRotated(base: Color, deltaDeg, L, C: float64): Result[Color,
    ColorError] {.raises: [].} =
  let okR = base.to(tagOklch)
  if okR.isErr:
    return err[Color, ColorError](okR.error)
  let o = okR.get
  let h0 = o.comp(2).float64
  let h = ((h0 + deltaDeg) mod 360.0 + 360.0) mod 360.0
  color(tagOklch, L.float32, C.float32, h.float32, base.alpha())

proc goldenAngle*(base: Color, n: int, lightness, chroma: float64): Result[
    Palette, ColorError] {.raises: [].} =
  ## Golden-angle qualitative palette: `h_i = (h_0 + i·φ) mod 360`, fixed
  ## `lightness`/`chroma`, `h_0` from `base`. Direct resolution, seed-independent
  ## (seed=0). n>=1, lightness in [0,1], chroma >= 0. Returns a `palUnordered`
  ## qualitative palette.
  if n < 1:
    return err[Palette, ColorError](colorError(InvalidColor,
        "goldenAngle: n must be >= 1, got " & $n, "goldenAngle"))
  if lightness < 0.0 or lightness > 1.0:
    return err[Palette, ColorError](colorError(InvalidColor,
        "goldenAngle: lightness must be in [0,1], got " & $lightness,
        "goldenAngle"))
  if chroma < 0.0:
    return err[Palette, ColorError](colorError(InvalidColor,
        "goldenAngle: chroma must be >= 0, got " & $chroma, "goldenAngle"))
  let okR = base.to(tagOklch)
  if okR.isErr:
    return err[Palette, ColorError](okR.error)
  let h0 = okR.get.comp(2).float64
  var colors: seq[Color] = @[]
  for i in 0 ..< n:
    let h = ((h0 + i.float64 * GoldenAngleDeg) mod 360.0 + 360.0) mod 360.0
    let cR = color(tagOklch, lightness.float32, chroma.float32, h.float32,
        base.alpha())
    if cR.isErr:
      return err[Palette, ColorError](cR.error)
    colors.add(cR.get)
  palette(palUnordered, colors, intentQualitative, 0)

# Harmony helpers: rotate the base hue by `delta`, keep the base L/C.
proc harmony(base: Color, deltas: openArray[float64]): Result[Palette,
    ColorError] {.raises: [].} =
  let okR = base.to(tagOklch)
  if okR.isErr:
    return err[Palette, ColorError](okR.error)
  let o = okR.get
  let L = o.comp(0).float64
  let C = o.comp(1).float64
  var colors: seq[Color] = @[]
  for d in deltas:
    let cR = oklchRotated(base, d, L, C)
    if cR.isErr:
      return err[Palette, ColorError](cR.error)
    colors.add(cR.get)
  palette(palUnordered, colors, intentQualitative, 0)

proc complement*(base: Color): Result[Palette, ColorError] {.raises: [].} =
  ## Complementary harmony: base + h±180°. Two colors.
  harmony(base, [0.0, 180.0])

proc triadic*(base: Color): Result[Palette, ColorError] {.raises: [].} =
  ## Triadic harmony: h, h+120°, h+240°. Three colors.
  harmony(base, [0.0, 120.0, 240.0])

proc analogous*(base: Color, delta = 30.0): Result[Palette,
    ColorError] {.raises: [].} =
  ## Analogous harmony: h, h−delta, h+delta (default 30°). Three colors.
  harmony(base, [0.0, -delta, delta])

proc splitComplement*(base: Color): Result[Palette, ColorError] {.raises: [].} =
  ## Split-complementary harmony: h, h+150°, h+210°. Three colors.
  harmony(base, [0.0, 150.0, 210.0])

proc tetradic*(base: Color): Result[Palette, ColorError] {.raises: [].} =
  ## Tetradic square harmony: h, h+90°, h+180°, h+270°. Four colors.
  harmony(base, [0.0, 90.0, 180.0, 270.0])

# HSL harmonies — the traditional/web complement model (rotate hue in HSL, keep
# S and L). For #0080ff the OKLCH complement preserves L/C and yields #b67500,
# whereas HSL keeps saturation/lightness and yields #ff7f00. The two answer
# different questions — HSL is geometrically opposite on the HSL cylinder,
# OKLCH is perceptually opposite. Both are exposed so callers pick the model
# their audience expects. Colors are built DIRECTLY in HSL so the rotated hue is
# exact (no round-trip).
proc harmonyHsl(base: Color, deltas: openArray[float64]): Result[Palette,
    ColorError] {.raises: [].} =
  let hslR = base.to(tagHsl)
  if hslR.isErr:
    return err[Palette, ColorError](hslR.error)
  let comps = hslR.get.components
  let h0 = comps.c0
  let s = comps.c1
  let l = comps.c2
  var colors: seq[Color] = @[]
  for d in deltas:
    let h = (((h0.float64 + d) mod 360.0) + 360.0) mod 360.0
    let cR = color(tagHsl, h.float32, s, l, base.alpha())
    if cR.isErr:
      return err[Palette, ColorError](cR.error)
    colors.add(cR.get)
  palette(palUnordered, colors, intentQualitative, 0)

proc complementHsl*(base: Color): Result[Palette, ColorError] {.raises: [].} =
  ## Complementary harmony in HSL: base + h±180°, S/L preserved.
  harmonyHsl(base, [0.0, 180.0])

proc triadicHsl*(base: Color): Result[Palette, ColorError] {.raises: [].} =
  ## Triadic harmony in HSL: h, h+120°, h+240°, S/L preserved.
  harmonyHsl(base, [0.0, 120.0, 240.0])

proc analogousHsl*(base: Color, delta = 30.0): Result[Palette,
    ColorError] {.raises: [].} =
  ## Analogous harmony in HSL: h, h−delta, h+delta (default 30°), S/L preserved.
  harmonyHsl(base, [0.0, -delta, delta])

proc splitComplementHsl*(base: Color): Result[Palette,
    ColorError] {.raises: [].} =
  ## Split-complementary harmony in HSL: h, h+150°, h+210°, S/L preserved.
  harmonyHsl(base, [0.0, 150.0, 210.0])

proc tetradicHsl*(base: Color): Result[Palette, ColorError] {.raises: [].} =
  ## Tetradic square harmony in HSL: h, h+90°, h+180°, h+270°, S/L preserved.
  harmonyHsl(base, [0.0, 90.0, 180.0, 270.0])
