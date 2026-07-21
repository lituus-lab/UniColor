# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# gradient — multi-stop color gradient (CSS Color 4 multi-stop + premultiplied
# alpha + gamut map of intermediate stops).
#
# `gradient(stops, t, opts)` finds the segment containing `t`, computes the
# local parameter `u` within that segment, and delegates the per-space blend
# (hue method, premultiplied alpha, gamut map) to `interpolate` (space.nim).
# Stops carry an explicit position in [0,1] and must be sorted non-decreasing —
# CSS sorts/clamps stops, but this API makes the sorted contract explicit and
# surfaces a violation as InvalidOp rather than silently reordering.
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/core/numerics
import UniColor/interpolation/space

type
  ColorStop* = object
    ## A single gradient stop: a color and its position in [0,1].
    color*: Color
    pos*: float32

  GradientOpts* = object
    ## Options for `gradient`. Mirrors the blend-relevant fields of `InterpOpts`
    ## plus gradient-specific clamping.
    space*: SpaceTag = tagOklch ## interpolation space (default OKLCH)
    hue*: HueMethod = hmShorter ## hue method for cylindrical spaces (default shorter)
    premultiplied*: bool = false ## premultiplied alpha opt-in
    gamutMap*: bool = false ## gamut-map the result into `target`; result in `target`
    target*: SpaceTag = tagSrgb ## destination gamut for `gamutMap` (default sRGB)
    clampT*: bool = true ## clamp t to [first_pos, last_pos] (default); false =
                           ## extrapolation

proc toInterpOpts(opts: GradientOpts, clampT: bool): InterpOpts =
  ## Build the per-segment `InterpOpts`. `clampT` is threaded from the gradient
  ## so that extrapolation (clampT=false) reaches `interpolate` unchanged.
  result = InterpOpts(space: opts.space, hue: opts.hue, clampT: clampT,
      premultiplied: opts.premultiplied, gamutMap: opts.gamutMap,
      target: opts.target)

proc gradient*(stops: openArray[ColorStop], t: float32,
    opts: GradientOpts): Result[Color, ColorError] {.raises: [].} =
  ## Multi-stop linear gradient (CSS Color 4). Returns the blend at `t` in
  ## `opts.space`, or in `opts.target` when `opts.gamutMap`. Empty stops,
  ## unsorted positions, or positions outside [0,1] return InvalidOp. NaN/Inf
  ## positions return InvalidOp. `interpolate` errors (UnknownSpace,
  ## InvalidColor) propagate unchanged.
  if stops.len == 0:
    return err[Color, ColorError](colorError(InvalidOp, "gradient: empty stops",
        "gradient"))
  # Validate positions: finite, in [0,1], non-decreasing.
  for i in 0 ..< stops.len:
    let p = stops[i].pos.float64
    if isNan(p) or isInf(p):
      return err[Color, ColorError](colorError(InvalidOp,
          "gradient: non-finite stop position", "gradient"))
    if p < 0.0 or p > 1.0:
      return err[Color, ColorError](colorError(InvalidOp,
          "gradient: stop position out of [0,1]", "gradient"))
    if i > 0 and p < stops[i - 1].pos.float64:
      return err[Color, ColorError](colorError(InvalidOp,
          "gradient: stop positions must be sorted non-decreasing", "gradient"))
  let pFirst = stops[0].pos.float64
  let pLast = stops[stops.len - 1].pos.float64
  # Clamp t to [first_pos, last_pos] by default; NaN preserved by clampCibled.
  let tt = if opts.clampT: clampCibled(t.float64, pFirst, pLast) else: t.float64
  let io = toInterpOpts(opts, opts.clampT)
  # Single stop: that stop at every t (blended with itself -> converted to opts.space).
  if stops.len == 1:
    return interpolate(stops[0].color, stops[0].color, 0.0'f32, io)
  # Segment index: stops[i].pos <= tt < stops[i+1].pos for interior tt; the
  # boundary cases (tt <= first, tt >= last) clamp to the first / last segment
  # so extrapolation (clampT false) extends the boundary segment rather than
  # returning a constant.
  var i = 0
  if tt <= pFirst:
    i = 0
  elif tt >= pLast:
    i = stops.len - 2
  else:
    for j in 1 ..< stops.len - 1:
      if stops[j].pos.float64 <= tt:
        i = j
      else:
        break
  let pi = stops[i].pos.float64
  let pj = stops[i + 1].pos.float64
  let u = if pj > pi: (tt - pi) / (pj - pi) else: 0.0
  interpolate(stops[i].color, stops[i + 1].color, toF32(u), io)
