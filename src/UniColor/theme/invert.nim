# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# invert — deterministic light/dark inversion + level variant. `invert(theme)`
# transforms the primitive tree to the opposite mode WITHOUT randomness:
#   - neutrals/surfaces (chroma < `neutralChromaMax`): invert the lightness
#     hierarchy (`L' = 1 - L`) so a light background becomes a dark one and a
#     dark text becomes a light one, then reduce chroma (×
#     `surfaceChromaFactor`, Radix 0.6) for the dark surface look.
#   - accents/interactives (chroma >= `neutralChromaMax`): keep hue and chroma,
#     raise lightness (+ `accentLift`, Radix 0.15) toward a dark-appropriate
#     tone so the accent pops on dark.
# The alias structure (semantics/components) is preserved verbatim — only
# primitive colors change. `variant(theme, level)` is the parametric multi-level
# form: a deterministic lightness shift by `level` tone-steps (full step on
# neutrals, half on accents). Pre-baked families (Catppuccin, Rosé Pine) are
# reference DATA consumed via the golden references, not encoded here
# (documented spec hole — `variant` ships the mechanism, families ship later).
#
# WCAG/APCA contrast ENFORCEMENT is the accessibility / generation layer, NOT
# invert. Invert's symmetric L-flip preserves the bg/text contrast gap (both
# ends flip), so contrast is kept, not re-enforced here. Deterministic.
import std/math
import std/tables
import UniColor/core/core
import UniColor/conversion/conversion # `to`, `gamutMap`.
import UniColor/theme/tree
import UniColor/theme/states

type
  InvertOpts* = object
    ## Options for `invert`. `neutralChromaMax` is the OKLCH chroma threshold
    ## separating neutrals/surfaces (below) from accents/interactives (>=).
    ## `surfaceChromaFactor` scales neutral chroma in dark (Radix 0.6).
    ## `accentLift` raises accent lightness in dark (Radix 0.15).
    neutralChromaMax*: float64
    surfaceChromaFactor*: float64
    accentLift*: float64

proc defaultInvertOpts*(): InvertOpts {.raises: [].} =
  ## Default invert options (Radix-derived): chroma threshold 0.02, surface
  ## chroma ×0.6, accent lift +0.15.
  InvertOpts(neutralChromaMax: 0.02, surfaceChromaFactor: 0.6, accentLift: 0.15)

# Build a new color in OKLCH (L, C, h, alpha) and gamut-map it back to `orig`'s
# space. Returns the mapped color or propagates a conversion/gamut error.
proc buildOklch(orig: Color, newL, newC, h: float64): Result[Color,
    ColorError] {.raises: [].} =
  let shifted = color(tagOklch, newL.float32, newC.float32, h.float32,
      orig.alpha())
  if shifted.isErr:
    return err[Color, ColorError](shifted.error)
  shifted.get.gamutMap(orig.spaceTag())

proc invertPrim(c: Color, opts: InvertOpts): Result[Color, ColorError] {.
    raises: [].} =
  let oklR = c.to(tagOklch)
  if oklR.isErr:
    return err[Color, ColorError](oklR.error)
  let o = oklR.get
  let l = o.comp(0).float64
  let c0 = o.comp(1).float64
  let h = o.comp(2).float64
  if c0 < opts.neutralChromaMax:
    # neutral/surface: invert the lightness hierarchy, reduce chroma for dark.
    buildOklch(c, clamp(1.0 - l, 0.0, 1.0), c0 * opts.surfaceChromaFactor, h)
  else:
    # accent/interactive: keep hue + chroma, raise lightness toward dark.
    buildOklch(c, clamp(l + opts.accentLift, 0.0, 1.0), c0, h)

proc invert*(t: Theme, opts: InvertOpts = defaultInvertOpts()): Result[Theme,
    ColorError] {.raises: [].} =
  ## Deterministically invert `t` to the opposite mode. Neutrals flip lightness
  ## and reduce chroma; accents keep hue and gain lightness. The alias
  ## structure (semantics/components) is preserved; only primitive colors
  ## change. Deterministic (no RNG). The original theme is untouched — a fresh
  ## primitive table is built, then `withPrims` carries the alias layers over
  ## unchanged (the `Theme` fields are encapsulated).
  var newPrims: Table[string, Color] = initTable[string, Color]()
  for k, v in pairs(t.prims):
    let xR = invertPrim(v, opts)
    if xR.isErr:
      return err[Theme, ColorError](xR.error)
    newPrims[k] = xR.get
  ok[Theme, ColorError](t.withPrims(newPrims))

proc variant*(t: Theme, level: int, opts: InvertOpts = defaultInvertOpts(
    )): Result[Theme, ColorError] {.raises: [].} =
  ## Parametric multi-level variant: shift every primitive lightness by `level`
  ## tone-steps (`StateShift.stepSize`, default 0.08), full step on
  ## neutrals/surfaces, half step on accents. `level = 0` leaves the theme
  ## unchanged; `level > 0` darkens, `level < 0` lightens. This is the
  ## mechanism; pre-baked families (Catppuccin/Rosé Pine) are reference data
  ## consumed via the golden references (documented spec hole). Deterministic.
  ## The original theme is untouched (immutable copy via `withPrims`).
  let step = defaultStateShift().stepSize
  var newPrims: Table[string, Color] = initTable[string, Color]()
  for k, v in pairs(t.prims):
    let oklR = v.to(tagOklch)
    if oklR.isErr:
      return err[Theme, ColorError](oklR.error)
    let o = oklR.get
    let l = o.comp(0).float64
    let c0 = o.comp(1).float64
    let h = o.comp(2).float64
    let factor = if c0 < opts.neutralChromaMax: 1.0 else: 0.5
    let newL = clamp(l - float64(level) * step * factor, 0.0, 1.0)
    let xR = buildOklch(v, newL, c0, h)
    if xR.isErr:
      return err[Theme, ColorError](xR.error)
    newPrims[k] = xR.get
  ok[Theme, ColorError](t.withPrims(newPrims))
