# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# space — per-space color interpolation. `interpolate(a, b, t, opts)` converts
# both endpoints to `opts.space` via the hub, blends linearly in that space, and
# returns the result IN `opts.space` (caller may reconvert). Cylindrical
# LCH-family spaces ([L/J, C, h]) blend L/J and C linearly and h along the
# shorter arc (CSS Color 4 `shorter`, default); hue normalized to [0,360) on
# output. Premultiplied alpha is opt-in; hue math lives in `hue` and the
# achromatic rule is applied here.
import std/options
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/core/numerics
import UniColor/spaces/spaces
import UniColor/conversion/conversion
import UniColor/interpolation/hue
export hue

type
  InterpOpts* = object
    ## Options for `interpolate`.
    space*: SpaceTag = tagOklch ## interpolation space (default OKLCH)
    hue*: HueMethod = hmShorter ## hue method for cylindrical spaces (default shorter)
    clampT*: bool = true        ## clamp t to [0,1] (default); false = extrapolation opt-in
    premultiplied*: bool = false ## premultiplied alpha opt-in: premul non-hue comps
                                ## by alpha, blend, un-premul; default straight alpha
    gamutMap*: bool = false     ## gamut-map the result into `target`; on -> result in
                                ## `target`, off (default) -> result stays in `space`
    target*: SpaceTag = tagSrgb ## destination gamut for `gamutMap` (default sRGB)

func isPolarJch(d: SpaceDescriptor): bool =
  ## True for cylindrical spaces with layout [L/J, C, h] (hue at component 2).
  ## Covers LCH, OKLCH, CAM16, HCT. HSV/HSL (hue at component 0) are out of
  ## this module's interpolation scope (CSS Color 4 does not list them as
  ## interpolation spaces).
  d.family in {famLch, famOklch, famCam16, famHct}

func blendComp(va, vb, aa, ab, tt, alphaBlend: float64, premul: bool): float64 =
  ## Blend one component from `va` (at alpha `aa`) to `vb` (at alpha `ab`) at
  ## parameter `tt`. Straight (default): lerp. Premultiplied: lerp the
  ## alpha-premultiplied values, then un-premultiply by the blended alpha (0 if
  ## the blended alpha is 0). Hue is NEVER passed through here — it is angular,
  ## not an intensity, so premultiplied does not apply to it (the caller handles
  ## hue separately via `interpHue`).
  if premul:
    let pa = va * aa
    let pb = vb * ab
    let p = pa + (pb - pa) * tt
    result = if alphaBlend > 0.0: p / alphaBlend else: 0.0
  else:
    result = va + (vb - va) * tt

proc interpolate*(a, b: Color, t: float32, opts: InterpOpts): Result[Color,
    ColorError] {.raises: [].} =
  ## Linear per-space interpolation (CSS Color 4). Converts `a` and `b` to
  ## `opts.space`, blends linearly in that space, returns the result IN
  ## `opts.space` (or in `opts.target` when `opts.gamutMap`). Cylindrical
  ## LCH-family spaces blend L/J and C linearly and h along the `opts.hue` arc
  ## (default `shorter`), hue normalized to [0,360). Alpha is blended linearly;
  ## `opts.premultiplied` (opt-in) blends the non-hue components premultiplied
  ## then un-premultiplies. `t` is clamped to [0,1] when `opts.clampT` (default);
  ## NaN in `t` is preserved by `clampTargeted`. Hub/gamut errors (UnknownSpace,
  ## InvalidOp, InvalidColor) propagate unchanged.
  let dOpt = spaceByTag(opts.space)
  if dOpt.isNone:
    return err[Color, ColorError](colorError(UnknownSpace,
        "interpolate: space not registered", spaceName(opts.space)))
  let d = dOpt.get
  # t handling: clamp by default; NaN preserved by clampTargeted.
  let tt = if opts.clampT: clampTargeted(t.float64, 0.0, 1.0) else: t.float64
  let caR = to(a, opts.space)
  if caR.isErr:
    return err[Color, ColorError](caR.error)
  let cbR = to(b, opts.space)
  if cbR.isErr:
    return err[Color, ColorError](cbR.error)
  let ca = caR.get
  let cb = cbR.get
  let aA = ca.alpha().float64
  let aB = cb.alpha().float64
  let alphaF = aA + (aB - aA) * tt
  let alpha = toF32(alphaF)
  var built: Result[Color, ColorError]
  if isPolarJch(d):
    # [L/J, C, h]: lightness and chroma (premultiplied when opts.premultiplied),
    # hue along the chosen arc. Achromatic rule: an achromatic bound's hue is
    # indeterminate -> adopts the other's; both achromatic -> h=0 (arbitrary).
    # Hue is NOT premultiplied (angular, not intensity) — only L/J and C are.
    let l = blendComp(ca.comp(0).float64, cb.comp(0).float64, aA, aB, tt,
        alphaF, opts.premultiplied)
    let c = blendComp(ca.comp(1).float64, cb.comp(1).float64, aA, aB, tt,
        alphaF, opts.premultiplied)
    let h1 = ca.comp(2).float64
    let h2 = cb.comp(2).float64
    let achA = isAchromatic(ca)
    let achB = isAchromatic(cb)
    var h: float64
    if achA and achB:
      h = 0.0 # both achromatic: result achromatic, hue arbitrary -> 0
    elif achA:
      h = interpHue(h2, h2, tt, opts.hue) # a adopts b's hue
    elif achB:
      h = interpHue(h1, h1, tt, opts.hue) # b adopts a's hue
    else:
      h = interpHue(h1, h2, tt, opts.hue)
    built = color(opts.space, toF32(l), toF32(c), toF32(h), alpha)
  else:
    # Cartesian (sRGB, linear, Lab, OKLab, CAM16-UCS, XYZ, ...): all 3 channels
    # blended (premultiplied when opts.premultiplied), alpha straight or premul.
    var comps: array[3, float32]
    for i in 0 ..< 3:
      comps[i] = toF32(blendComp(ca.comp(i).float64, cb.comp(i).float64, aA,
          aB, tt, alphaF, opts.premultiplied))
    built = color(opts.space, comps[0], comps[1], comps[2], alpha)
  if built.isErr:
    return err[Color, ColorError](built.error)
  if opts.gamutMap:
    return gamutMap(built.get, opts.target) # returns in `target` space
  ok[Color, ColorError](built.get)
