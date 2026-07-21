# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# palette/tonal — tonalScale + neutralScale primitives. A tonal scale is a ramp
# of tones from a base color: lightness STRICTLY monotone, chroma a bell curve
# (max at the middle, fading to achromatic at the ends), hue = base hue. The
# `curve` selects the perceptual space the ramp is built in: tailwind=OKLCH,
# radix=CIELCH (Lab), material=HCT. Each tone is gamut-mapped into the target
# gamut — output colors live in `gamut` (default sRGB). `neutralScale` builds a
# gray/tinted ramp (pure/tinted/warm/cool).
#
# This ships the PRIMITIVE with a parametric linear-L distribution; the curve
# differs by SPACE only. Exact per-step golden L tables (Tailwind 50..950, Radix
# 12, Material tone 0..100) are a separate reproduction concern and can drop in
# later without breaking callers. `cloneFrom` (clone a reference ramp's
# perceptual DNA) needs theme context and lands with the theme layer.
import std/math
import UniColor/core/core
import UniColor/conversion/conversion # `to`, `gamutMap`.
import UniColor/palette/types

type
  TonalCurve* {.pure.} = enum
    tcTailwind ## OKLCH: L linear, C bell, h = base.
    tcRadix    ## CIELCH (CIELAB polar): L linear, C bell, h = base.
    tcMaterial ## HCT: T linear, C bell, h = base.

  NeutralMode* {.pure.} = enum
    nmPure   ## achromatic (C=0), gray ramp.
    nmTinted ## small chroma, base hue (no dead gray).
    nmWarm   ## small chroma, warm hue (~70°, yellow-orange).
    nmCool   ## small chroma, cool hue (~250°, blue).

# Curve space + lightness range. HCT/CIELCH lightness (T / L*) is 0..100; OKLCH
# L is 0..1.
proc curveSpace(c: TonalCurve): tuple[s: SpaceTag, lMin,
    lMax: float64] {.raises: [].} =
  case c
  of tcTailwind: (tagOklch, 0.15, 0.95)
  of tcRadix: (tagLch, 10.0, 90.0)
  of tcMaterial: (tagHct, 10.0, 90.0)

# Build a tone in `space` from (lightness, chroma, hue). HCT orders components
# (H,C,T); the polar CIELAB/OKLCH order (L,C,h) — so HCT swaps lightness and hue
# into the 3rd / 1st slot.
proc makeTone(space: SpaceTag, lightness, chroma, hue: float64): Result[Color,
    ColorError] {.raises: [].} =
  if space == tagHct:
    color(space, hue.float32, chroma.float32, lightness.float32) # (H, C, T)
  else:
    color(space, lightness.float32, chroma.float32, hue.float32) # (L, C, h)

proc tonalScale*(base: Color, n: int, curve: TonalCurve,
    gamut: SpaceTag = tagSrgb): Result[Palette, ColorError] {.raises: [].} =
  ## A ramp of `n` tones from `base`: L strictly monotone, chroma a bell
  ## `Cmax * sin(π·u)` (max at the middle), hue = base hue, built in the curve's
  ## space and gamut-mapped into `gamut` per color. `n < 2` -> `InvalidOp`.
  ## `Cmax` is the base's chroma in the curve space (achromatic base -> gray
  ## ramp). Returns a `palOrdered` UI palette.
  if n < 2:
    return err[Palette, ColorError](colorError(InvalidOp,
        "tonalScale: n < 2 (need a ramp)", "tonalScale"))
  let (space, lMin, lMax) = curveSpace(curve)
  let bR = base.to(space)
  if bR.isErr:
    return err[Palette, ColorError](bR.error)
  let b = bR.get
  # Hue index is curve-dependent: HCT orders components (H, C, T) so the hue is
  # comp(0); the polar OKLCH/CIELCH order (L, C, h) puts the hue at comp(2).
  # Reading comp(2) for HCT would extract the tone (T) and emit a wrong-hue ramp
  # (e.g. a blue base -> an orange Material ramp). Mirror the swap in `makeTone`.
  let hBase = if space == tagHct: b.comp(0).float64 else: b.comp(2).float64
  let cmax = b.comp(1).float64
  var cs: seq[Color] = @[]
  for i in 0 ..< n:
    let u = float64(i) / float64(n - 1)
    let lightness = lMin + u * (lMax - lMin)
    let chroma = cmax * sin(PI * u)
    let tR = makeTone(space, lightness, chroma, hBase)
    if tR.isErr:
      return err[Palette, ColorError](tR.error)
    let gR = gamutMap(tR.get, gamut)
    if gR.isErr:
      return err[Palette, ColorError](gR.error)
    cs.add(gR.get)
  palette(palOrdered, cs, intentUI, 0)

proc neutralScale*(base: Color, n: int, mode: NeutralMode,
    gamut: SpaceTag = tagSrgb): Result[Palette, ColorError] {.raises: [].} =
  ## A gray/tinted ramp of `n` steps: L strictly monotone, small flat chroma
  ## (no bell — neutral tints stay subtle and consistent). `pure`=achromatic,
  ## `tinted`=base hue, `warm`/`cool`=fixed warm/cool hue. Gamut-mapped into
  ## `gamut` per color. `n < 2` -> `InvalidOp`. `palOrdered` UI palette.
  if n < 2:
    return err[Palette, ColorError](colorError(InvalidOp,
        "neutralScale: n < 2 (need a ramp)", "neutralScale"))
  let bR = base.to(tagOklch)
  if bR.isErr:
    return err[Palette, ColorError](bR.error)
  let hBase = bR.get.comp(2).float64
  const cNeutral = 0.015 # subtle tint chroma (OKLCH).
  let (chroma, hue) = case mode
    of nmPure: (0.0, hBase) # C=0 -> h irrelevant (achromatic).
    of nmTinted: (cNeutral, hBase)
    of nmWarm: (cNeutral, 70.0)
    of nmCool: (cNeutral, 250.0)
  var cs: seq[Color] = @[]
  for i in 0 ..< n:
    let u = float64(i) / float64(n - 1)
    let lightness = 0.2 + u * 0.75 # [0.2, 0.95]
    let tR = makeTone(tagOklch, lightness, chroma, hue)
    if tR.isErr:
      return err[Palette, ColorError](tR.error)
    let gR = gamutMap(tR.get, gamut)
    if gR.isErr:
      return err[Palette, ColorError](gR.error)
    cs.add(gR.get)
  palette(palOrdered, cs, intentUI, 0)
