# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# gamut — gamut mapping to a bounded destination (CSS Color 4).
#
# Implements the CSS Color 4 gamut-mapping algorithm (W3C csswg-drafts #9715 /
# #10226): reduce chroma in OKLCH (preserving L and h) until the clipped result
# is within one JND (deltaEOK <= 0.02) of the candidate, then return the clipped
# color in the destination gamut. Bounded by a binary search on chroma (min=0,
# max=origin chroma, eps=1e-4).
#
# Bounded vs unbounded destination is DATA-DRIVEN from the registry descriptor: a
# destination has gamut limits iff it is redeemable AND every chromatic channel
# has finite bounds (compMin/compMax). Spaces with any unbounded channel (XYZ,
# xyY, Lab, LCH, OKLab, OKLCH, ICtCp, JzAzBz, CAM16, CAM16-UCS, HCT, linear RGB)
# have no gamut to map to — CSS step 1 converts and returns unchanged
# (gamutMap == `to`). Non-redeemable bounded spaces (CMYK) also fall through to
# `to`, which surfaces InvalidOp honestly.

import std/math
import std/options
import UniColor/core/core
import UniColor/spaces/spaces
import UniColor/conversion/to

# CSS Color 4 fixed parameters: JND threshold and binary-search convergence.
const
  JND* = TOL_JND     # 0.02 — deltaEOK below which two colors are perceptually
                     # identical.
  gamutEps* = 1.0e-4 # chroma binary-search convergence (CSS step 9/18).

# inGamut tolerance: a converted component within this slack of a bound counts as
# in gamut, so float noise at an exact boundary (1.0000000001) does not trigger
# an unnecessary chroma reduction. Tighter than gamutEps; the golden vectors are
# strictly inside or well outside.
const inGamutSlack = 1.0e-6

func hasGamutLimits(d: SpaceDescriptor): bool {.inline, raises: [].} =
  ## A destination has gamut limits iff it is redeemable AND every chromatic
  ## channel has finite bounds. Unbounded spaces (XYZ, Lab, OKLab, linear RGB,
  ## ...) and non-redeemable bounded spaces (CMYK) have no gamut to map to ->
  ## CSS step 1 (convert and return).
  if not d.redeemable:
    return false
  for i in 0 ..< d.chromaticCount:
    if d.compMin[i] == NegInf or d.compMax[i] == Inf:
      return false
  true

proc inGamut(oklchColor: Color, d: SpaceDescriptor, target: SpaceTag): bool {.
    raises: [].} =
  ## CSS step 5: convert the OKLCH candidate to the destination and check every
  ## chromatic component against the descriptor bounds (with a small slack for
  ## float noise at bounds).
  let r = to(oklchColor, target)
  if r.isErr:
    return false
  let cv = r.get
  for i in 0 ..< d.chromaticCount:
    let v = cv.comp(i).float64
    if v < d.compMin[i] - inGamutSlack or v > d.compMax[i] + inGamutSlack:
      return false
  true

proc clipColor(oklchColor: Color, d: SpaceDescriptor, target: SpaceTag,
                alpha: float32): Color {.raises: [].} =
  ## CSS step 10: convert the OKLCH candidate to the destination and clamp each
  ## chromatic component to its descriptor bounds. Returns a Color in the
  ## destination space with the source alpha reattached. Bounds are finite
  ## (caller guarantees a bounded destination).
  let r = to(oklchColor, target)
  # Bounded redeemable destination is convertible from OKLCH via the hub; the
  # Result is Ok in practice. On an unexpected error, fall back to a neutral
  # in-gamut color so the search continues without crashing (never observed for
  # wired bounded spaces).
  if r.isErr:
    return color(target, 0.0'f32, 0.0'f32, 0.0'f32, alpha).get
  let cv = r.get
  var comps: array[3, float32]
  for i in 0 ..< d.chromaticCount:
    let v = cv.comp(i).float64
    let lo = d.compMin[i]
    let hi = d.compMax[i]
    let clamped = if v < lo: lo elif v > hi: hi else: v
    comps[i] = toF32(clamped)
  color(target, comps[0], comps[1], comps[2], alpha).get

proc deltaEOK(a, b: Color): float64 {.raises: [].} =
  ## CSS step 7: deltaEOK = Euclidean distance between `a` and `b` in OKLab
  ## (sqrt(dL^2 + da^2 + db^2)). Both colors are converted to OKLab via the hub.
  let ao = to(a, tagOklab)
  let bo = to(b, tagOklab)
  if ao.isErr or bo.isErr:
    return Inf # reject the candidate (search shrinks toward 0); never observed
               # in practice.
  let av = ao.get
  let bv = bo.get
  let dl = av.comp(0).float64 - bv.comp(0).float64
  let da = av.comp(1).float64 - bv.comp(1).float64
  let db = av.comp(2).float64 - bv.comp(2).float64
  sqrt(dl * dl + da * da + db * db)

proc gamutMap*(c: Color, target: SpaceTag): Result[Color,
    ColorError] {.raises: [].} =
  ## Gamut-map `c` into the bounded destination `target` per CSS Color 4.
  ## Returns a Color in `target`. Unbounded/non-redeemable destinations return
  ## `to(c, target)` unchanged (CSS step 1; InvalidOp surfaces for CMYK). L and h
  ## are preserved; chroma is reduced only as far as needed. Alpha is preserved.
  let dOpt = spaceByTag(target)
  if dOpt.isNone:
    return err[Color, ColorError](colorError(UnknownSpace,
        "gamutMap: target not registered", spaceName(target)))
  let d = dOpt.get
  let alpha = c.alpha()
  # Step 1: no gamut limits -> convert and return unchanged.
  if not hasGamutLimits(d):
    return to(c, target)
  # Step 2: origin in OKLCH (L, C, h).
  let oklR = to(c, tagOklch)
  if oklR.isErr:
    return err[Color, ColorError](oklR.error)
  let okl = oklR.get
  let L = okl.comp(0).float64
  let C = okl.comp(1).float64
  let h = okl.comp(2).float64
  # Step 3: L >= 100% -> white (oklab(1 0 0)) in the destination.
  if L >= 1.0:
    let w = color(tagOklab, 1.0'f32, 0.0'f32, 0.0'f32, alpha)
    return to(w.get, target)
  # Step 4: L <= 0% -> black (oklab(0 0 0)) in the destination.
  if L <= 0.0:
    let b = color(tagOklab, 0.0'f32, 0.0'f32, 0.0'f32, alpha)
    return to(b.get, target)
  # Step 6: already in gamut -> relative colorimetric, return the converted
  # origin unchanged.
  if inGamut(okl, d, target):
    return to(okl, target)
  # Steps 11-14: initial clip of the full-chroma candidate; accept if within JND.
  var current = okl
  var clipped = clipColor(current, d, target, alpha)
  var e = deltaEOK(clipped, current)
  if e < JND:
    return ok[Color, ColorError](clipped)
  # Steps 15-18: binary search on chroma in [0, origin C], preserving L and h.
  var mn = 0.0
  var mx = C
  var minInGamut = true
  while mx - mn > gamutEps:
    let chroma = (mn + mx) * 0.5
    current = color(tagOklch, toF32(L), toF32(chroma), toF32(h), alpha).get
    # Step 18.3: still in gamut at this chroma -> push the lower bound up.
    if minInGamut and inGamut(current, d, target):
      mn = chroma
      continue
    # Step 18.4: out of gamut (or no longer trusting in-gamut) -> clip and
    # measure deltaEOK.
    clipped = clipColor(current, d, target, alpha)
    e = deltaEOK(clipped, current)
    if e < JND:
      # Step 18.4.3.1: within epsilon of JND -> good enough, accept the clipped
      # result.
      if JND - e < gamutEps:
        return ok[Color, ColorError](clipped)
      # Step 18.4.3.2: accept this chroma as the new lower bound, keep searching
      # down.
      minInGamut = false
      mn = chroma
      continue
    # Step 18.4.4: too far from the candidate -> reduce the upper bound.
    mx = chroma
  # Step 19: converged -> return the last clipped result.
  ok[Color, ColorError](clipped)
