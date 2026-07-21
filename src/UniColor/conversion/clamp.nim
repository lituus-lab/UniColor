# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# clamp — targeted per-channel clip at the destination's explicit output bounds.
#
# Distinct from `gamutMap` (conversion/gamut.nim): `clamp` converts `c` to
# `target` and clamps each chromatic channel to the target descriptor bounds via
# `clampCibled` (NaN preserved, not masked). It is the "targeted, never blanket"
# clip — ONLY out-of-bounds channels are touched; in-bounds channels pass through
# unchanged (== the raw converted value). Unbounded destinations (XYZ, Lab,
# OKLab, linear RGB, ...) have no explicit bounds, so `clampCibled(v, -Inf,
# +Inf)` is a no-op and `clamp(c, target) == to(c, target)`. Conversion itself
# never clamps (out-of-gamut preserved); clamp is the explicit op the user
# chooses at export/encoding (default export = gamutMap, clamp optional).
#
# Naive per-channel clip can shift L and h perceptually (no OKLCH chroma
# reduction); gamutMap is the perceptually faithful (L-preserving within JND)
# alternative.

import std/options
import UniColor/core/core
import UniColor/spaces/spaces
import UniColor/conversion/to

proc clamp*(c: Color, target: SpaceTag): Result[Color, ColorError] {.raises: [].} =
  ## Targeted clamp: convert `c` to `target` and clamp each chromatic channel to
  ## the target descriptor bounds. In-bounds channels pass through unchanged
  ## (only out-of-bounds channels are touched); unbounded channels are no-ops.
  ## NaN is preserved by `clampCibled` (visible, not masked) — a NaN reaching the
  ## `color` constructor is detected at bounds as InvalidColor. Alpha is
  ## preserved. Errors from `to` (UnknownSpace, InvalidOp for CMYK, InvalidColor)
  ## propagate unchanged.
  let dOpt = spaceByTag(target)
  if dOpt.isNone:
    return err[Color, ColorError](colorError(UnknownSpace,
        "clamp: target not registered", spaceName(target)))
  let d = dOpt.get
  let alpha = c.alpha()
  let r = to(c, target)
  if r.isErr:
    return err[Color, ColorError](r.error)
  let cv = r.get
  # Clamp each chromatic channel to its descriptor bounds. Bounded redeemable
  # destinations reachable here are 3-chromatic (sRGB/P3/HSV/HSL/HWB/YCbCr); CMYK
  # (4-chromatic, non-redeemable) returns InvalidOp above before this loop, so
  # the 3-slot array is safe.
  var comps: array[3, float32]
  for i in 0 ..< d.chromaticCount:
    comps[i] = toF32(clampCibled(cv.comp(i).float64, d.compMin[i], d.compMax[i]))
  # Surface InvalidColor honestly if a NaN/Inf reached the constructor; `.get`
  # here would read the inactive case-object field (UB) on the err path.
  let built = color(target, comps[0], comps[1], comps[2], alpha)
  if built.isErr:
    return err[Color, ColorError](built.error)
  ok[Color, ColorError](built.get)
