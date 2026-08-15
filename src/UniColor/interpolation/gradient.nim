# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# gradient — multi-stop color gradient (CSS Color 4). `gradient(stops, t,
# opts)` finds the segment containing `t`, computes the local parameter `u`,
# and delegates the per-space blend (hue method, premultiplied alpha, gamut
# map) to `interpolate`. Stops carry an explicit [0,1] position and must be
# sorted non-decreasing; a violation surfaces as InvalidOp.
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/core/numerics
import UniColor/conversion/to
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

  PreparedGradient* = object
    ## Validated immutable gradient stops reusable across scalar samples.
    stops: seq[ColorStop]
    opts: GradientOpts

proc toInterpOpts(opts: GradientOpts, clampT: bool): InterpOpts =
  ## Build the per-segment `InterpOpts`. `clampT` is threaded from the gradient
  ## so that extrapolation (clampT=false) reaches `interpolate` unchanged.
  result = InterpOpts(space: opts.space, hue: opts.hue, clampT: clampT,
      premultiplied: opts.premultiplied, gamutMap: opts.gamutMap,
      target: opts.target)

proc validateStops(stops: openArray[ColorStop], operation: string):
    Result[bool, ColorError] {.raises: [].} =
  if stops.len == 0:
    return err[bool, ColorError](colorError(InvalidOp,
        operation & ": empty stops", operation))
  for i in 0 ..< stops.len:
    let position = stops[i].pos.float64
    if isNan(position) or isInf(position):
      return err[bool, ColorError](colorError(InvalidOp,
          operation & ": non-finite stop position", operation))
    if position < 0.0 or position > 1.0:
      return err[bool, ColorError](colorError(InvalidOp,
          operation & ": stop position out of [0,1]", operation))
    if i > 0 and position < stops[i - 1].pos.float64:
      return err[bool, ColorError](colorError(InvalidOp,
          operation & ": stop positions must be sorted non-decreasing",
          operation))
  ok[bool, ColorError](true)

proc sampleStops(stops: openArray[ColorStop], opts: GradientOpts,
    t: float32): Result[Color, ColorError] {.raises: [].} =
  let
    first = stops[0].pos.float64
    last = stops[^1].pos.float64
    target = if opts.clampT:
      clampTargeted(t.float64, first, last) else: t.float64
    interpolationOpts = toInterpOpts(opts, opts.clampT)
  if stops.len == 1:
    return interpolate(stops[0].color, stops[0].color, 0.0'f32,
      interpolationOpts)
  # Rightmost stop wins at a position shared by several stops (a hard stop),
  # at the endpoints as well as inside: the loop advances past every stop the
  # target has reached, and a zero-width segment resolves to its right end.
  # Below the first stop the segment stays 0, so extrapolation (clampT false)
  # still extends the boundary segment rather than returning a constant.
  var segment = 0
  for index in 1 ..< stops.len - 1:
    if stops[index].pos.float64 <= target:
      segment = index
    else:
      break
  let
    left = stops[segment].pos.float64
    right = stops[segment + 1].pos.float64
    local =
      if right > left: (target - left) / (right - left)
      elif target >= right: 1.0
      else: 0.0
  interpolate(stops[segment].color, stops[segment + 1].color, toF32(local),
    interpolationOpts)

proc prepareGradient*(stops: openArray[ColorStop],
    opts: GradientOpts): Result[PreparedGradient, ColorError] {.raises: [].} =
  ## Validate and retain an independent stop sequence for allocation-free
  ## repeated sampling.
  let valid = validateStops(stops, "prepareGradient")
  if valid.isErr:
    return err[PreparedGradient, ColorError](valid.error)
  var retained = newSeqOfCap[ColorStop](stops.len)
  for stop in stops:
    let converted = stop.color.to(opts.space)
    if converted.isErr:
      return err[PreparedGradient, ColorError](converted.error)
    retained.add ColorStop(color: converted.get, pos: stop.pos)
  ok[PreparedGradient, ColorError](PreparedGradient(stops: retained,
      opts: opts))

proc sample*(gradient: PreparedGradient,
    t: float32): Result[Color, ColorError] {.raises: [].} =
  ## Sample a previously validated gradient without allocating or revalidating
  ## its stop sequence.
  if gradient.stops.len == 0:
    return err[Color, ColorError](colorError(InvalidOp,
        "sample: uninitialized prepared gradient", "sample"))
  sampleStops(gradient.stops, gradient.opts, t)

proc gradient*(stops: openArray[ColorStop], t: float32,
    opts: GradientOpts): Result[Color, ColorError] {.raises: [].} =
  ## Multi-stop linear gradient (CSS Color 4). Returns the blend at `t` in
  ## `opts.space`, or in `opts.target` when `opts.gamutMap`. Empty stops,
  ## unsorted positions, or positions outside [0,1] return InvalidOp. NaN/Inf
  ## positions return InvalidOp. `interpolate` errors (UnknownSpace,
  ## InvalidColor) propagate unchanged. Stops sharing a position form a hard
  ## stop: at exactly that position the rightmost of them wins.
  let valid = validateStops(stops, "gradient")
  if valid.isErr:
    return err[Color, ColorError](valid.error)
  sampleStops(stops, opts, t)
