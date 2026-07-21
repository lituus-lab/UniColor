# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# tonal_share — tonalScale shared palette↔theme via cloneFrom. Two operations:
#   - `cloneFrom(reference, base, gamut)` clones the reference ramp's LIGHTNESS
#     distribution (its perceptual DNA — the defining tonal structure) and
#     re-tints with `base`: hue = base hue, chroma = base chroma bell
#     `Cmax·sin(πu)`. This is the re-skin: take the L steps of a reference ramp
#     (e.g. a neutral Tailwind ramp) and produce a colored ramp with those exact
#     L steps but a different hue/chroma. Returns a `palOrdered` UI palette.
#   - `rampTokens(p, names)` bridges a tonal palette to theme primitive tokens
#     (palette→theme): zip each tone with a caller-supplied name into a
#     `ThemeToken` ready for `theme()`.
#
# Chroma is re-derived from `base` (NOT cloned from reference): a neutral
# reference has C≈0, cloning its chroma shape would yield a gray ramp — the
# useful op grafts the base's chroma bell onto the reference's L skeleton.
# Curve-space differences (OKLCH vs HCT vs CIELCH) are normalized by reading
# every reference tone's L in OKLCH. Label conventions (Tailwind 50..950, Radix
# 1..12, Material 0..100) are golden — `rampTokens` takes explicit names, no
# naming baked in. Deterministic.
import std/math
import UniColor/core/core
import UniColor/conversion/conversion # `to`, `gamutMap`.
import UniColor/palette/types
import UniColor/theme/tree

# Whether a palette carries an ordered lightness progression cloneFrom can read
# as a tonal DNA.
proc isOrderedRamp(t: PaletteTag): bool {.raises: [].} =
  t in {palOrdered, palScientific, palContinuous}

proc cloneFrom*(reference: Palette, base: Color,
    gamut: SpaceTag = tagSrgb): Result[Palette, ColorError] {.raises: [].} =
  ## Clone `reference`'s lightness distribution and re-tint with `base`. Each
  ## output tone takes its L from the matching reference tone (read in OKLCH to
  ## normalize across curve spaces), the base hue, and the base chroma bell
  ## `Cmax·sin(πu)`. The result is a `palOrdered` UI palette with the same
  ## length as `reference`. `reference` must be an ordered ramp
  ## (`Ordered`/`Scientific`/`Continuous`) with at least 2 tones; else
  ## `InvalidOp`. Deterministic (no RNG). The original palette is untouched.
  if not reference.tag.isOrderedRamp:
    return err[Palette, ColorError](colorError(InvalidOp,
        "cloneFrom: reference must be an ordered ramp, got " & $reference.tag,
        "cloneFrom"))
  let refCs = reference.colors
  if refCs.len < 2:
    return err[Palette, ColorError](colorError(InvalidOp,
        "cloneFrom: reference ramp needs >= 2 tones, got " & $refCs.len,
        "cloneFrom"))
  let bR = base.to(tagOklch)
  if bR.isErr:
    return err[Palette, ColorError](bR.error)
  let baseHue = bR.get.comp(2).float64
  let baseChroma = bR.get.comp(1).float64
  let n = refCs.len
  var cs: seq[Color] = @[]
  for i in 0 ..< n:
    let rR = refCs[i].to(tagOklch)
    if rR.isErr:
      return err[Palette, ColorError](rR.error)
    let clonedL = rR.get.comp(0).float64
    let u = float64(i) / float64(n - 1)
    let chroma = baseChroma * sin(PI * u)
    let shifted = color(tagOklch, clonedL.float32, chroma.float32,
        baseHue.float32, base.alpha())
    if shifted.isErr:
      return err[Palette, ColorError](shifted.error)
    let gR = shifted.get.gamutMap(gamut)
    if gR.isErr:
      return err[Palette, ColorError](gR.error)
    cs.add(gR.get)
  palette(palOrdered, cs, intentUI, 0)

proc rampTokens*(p: Palette, names: openArray[string]): Result[seq[ThemeToken],
    ColorError] {.raises: [].} =
  ## Bridge a tonal palette to theme primitive tokens (palette→theme). Zip each
  ## of `p`'s colors with the matching name from `names` into a primitive
  ## `ThemeToken` (alias empty) ready for `theme()`. `names.len` must equal
  ## `p.len`; else `InvalidOp`. Label conventions (Tailwind 50..950, Radix
  ## 1..12, Material 0..100) are golden — the caller supplies explicit names; no
  ## naming convention is baked in here. Deterministic.
  let cs = p.colors
  if names.len != cs.len:
    return err[seq[ThemeToken], ColorError](colorError(InvalidOp,
        "rampTokens: names.len (" & $names.len & ") != palette.len (" &
        $cs.len & ")", "rampTokens"))
  var toks: seq[ThemeToken] = @[]
  for i in 0 ..< cs.len:
    if names[i].len == 0:
      return err[seq[ThemeToken], ColorError](colorError(InvalidOp,
          "rampTokens: empty name at index " & $i, "rampTokens"))
    toks.add(ThemeToken(name: names[i], color: cs[i]))
  ok[seq[ThemeToken], ColorError](toks)
