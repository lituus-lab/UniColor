# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/options
import std/unittest
import UniColor

proc near(a, b: float64, tol = 1.0e-2): bool = abs(a - b) <= tol

test "interpolation module compiles and is reachable":
  check interpolationModule == "1.0.0"

suite "hue helpers":
  test "normHue wraps to [0,360)":
    check near(normHue(370.0), 10.0, 1.0e-9)
    check near(normHue(-10.0), 350.0, 1.0e-9)
    check near(normHue(360.0), 0.0, 1.0e-9)
  test "hueDelta shorter stays within +/-180":
    check abs(hueDelta(hmShorter, 10.0, 50.0)) <= 180.0
    # 350 -> 20: shorter arc is forward (+30), not backward (-330).
    check near(hueDelta(hmShorter, 350.0, 20.0), 30.0, 1.0e-9)
  test "interpHue hits endpoints":
    check near(interpHue(10.0, 50.0, 0.0, hmShorter), 10.0, 1.0e-9)
    check near(interpHue(10.0, 50.0, 1.0, hmShorter), 50.0, 1.0e-9)
    check near(interpHue(10.0, 50.0, 0.5, hmShorter), 30.0, 1.0e-9)

suite "interpolate":
  test "endpoints recover inputs (in-space, hub tolerance)":
    let a = color(tagOklab, 0.5'f32, 0.1'f32, -0.1'f32).get
    let b = color(tagOklab, 0.7'f32, -0.1'f32, 0.1'f32).get
    let opts = InterpOpts(space: tagOklab)
    let r0 = interpolate(a, b, 0.0'f32, opts).get
    let r1 = interpolate(a, b, 1.0'f32, opts).get
    for i in 0 ..< 3:
      check near(r0.comp(i).float64, a.comp(i).float64)
      check near(r1.comp(i).float64, b.comp(i).float64)
  test "cartesian midpoint is the linear average":
    let a = color(tagOklab, 0.5'f32, 0.1'f32, -0.1'f32).get
    let b = color(tagOklab, 0.7'f32, -0.1'f32, 0.1'f32).get
    let r = interpolate(a, b, 0.5'f32, InterpOpts(space: tagOklab)).get
    check near(r.comp(0).float64, 0.6)
    check near(r.comp(1).float64, 0.0)
    check near(r.comp(2).float64, 0.0)
  test "clampT clamps out-of-range t":
    let a = color(tagOklab, 0.5'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagOklab, 0.7'f32, 0.0'f32, 0.0'f32).get
    let opts = InterpOpts(space: tagOklab) # clampT = true default.
    let below = interpolate(a, b, -0.5'f32, opts).get
    let above = interpolate(a, b, 1.5'f32, opts).get
    check near(below.comp(0).float64, a.comp(0).float64)
    check near(above.comp(0).float64, b.comp(0).float64)
  test "oklch hue interpolates along the shorter arc":
    let a = color(tagOklch, 0.6'f32, 0.1'f32, 10.0'f32).get
    let b = color(tagOklch, 0.6'f32, 0.1'f32, 50.0'f32).get
    let r = interpolate(a, b, 0.5'f32, InterpOpts(space: tagOklch)).get
    check near(r.comp(2).float64, 30.0)
  test "shorter arc wraps across the 0/360 seam":
    let a = color(tagOklch, 0.6'f32, 0.1'f32, 350.0'f32).get
    let b = color(tagOklch, 0.6'f32, 0.1'f32, 20.0'f32).get
    let r = interpolate(a, b, 0.5'f32, InterpOpts(space: tagOklch)).get
    check near(r.comp(2).float64, 5.0, 5.0e-3)

suite "gradient":
  test "two-stop midpoint":
    let a = color(tagOklab, 0.5'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagOklab, 0.7'f32, 0.0'f32, 0.0'f32).get
    let stops = [ColorStop(color: a, pos: 0.0'f32),
                 ColorStop(color: b, pos: 1.0'f32)]
    let r = gradient(stops, 0.5'f32, GradientOpts(space: tagOklab)).get
    check near(r.comp(0).float64, 0.6)
  test "duplicate endpoint positions resolve to the rightmost stop":
    # A shared position is a hard stop; at exactly that position the rightmost
    # stop wins, at the endpoints just as it already does inside the ramp.
    let a = color(tagOklab, 0.1'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagOklab, 0.2'f32, 0.0'f32, 0.0'f32).get
    let c = color(tagOklab, 0.3'f32, 0.0'f32, 0.0'f32).get
    let opts = GradientOpts(space: tagOklab)
    let atStart = [ColorStop(color: a, pos: 0.0'f32),
                   ColorStop(color: b, pos: 0.0'f32),
                   ColorStop(color: c, pos: 1.0'f32)]
    check near(gradient(atStart, 0.0'f32, opts).get.comp(0).float64, 0.2)
    check near(prepareGradient(atStart, opts).get.sample(0.0'f32)
      .get.comp(0).float64, 0.2)
    let atEnd = [ColorStop(color: a, pos: 0.0'f32),
                 ColorStop(color: b, pos: 1.0'f32),
                 ColorStop(color: c, pos: 1.0'f32)]
    check near(gradient(atEnd, 1.0'f32, opts).get.comp(0).float64, 0.3)
    check near(prepareGradient(atEnd, opts).get.sample(1.0'f32)
      .get.comp(0).float64, 0.3)
  test "empty stops is InvalidOp":
    let stops: seq[ColorStop] = @[]
    check gradient(stops, 0.5'f32, GradientOpts()).error.kind == InvalidOp
  test "unsorted positions are InvalidOp":
    let a = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    let stops = [ColorStop(color: a, pos: 1.0'f32),
                 ColorStop(color: b, pos: 0.0'f32)]
    check gradient(stops, 0.5'f32, GradientOpts()).error.kind == InvalidOp
  test "prepared gradients match scalar gradients and retain their stops":
    let a = color(tagOklab, 0.4'f32, 0.1'f32, -0.1'f32).get
    let b = color(tagOklab, 0.6'f32, 0.0'f32, 0.0'f32).get
    let c = color(tagOklab, 0.8'f32, -0.1'f32, 0.1'f32).get
    var stops = @[ColorStop(color: a, pos: 0.0'f32),
      ColorStop(color: b, pos: 0.5'f32),
      ColorStop(color: c, pos: 1.0'f32)]
    let opts = GradientOpts(space: tagOklab)
    let prepared = prepareGradient(stops, opts).get
    stops[1] = ColorStop(color: a, pos: 0.25'f32)
    let original = [ColorStop(color: a, pos: 0.0'f32),
      ColorStop(color: b, pos: 0.5'f32),
      ColorStop(color: c, pos: 1.0'f32)]
    for t in [0.0'f32, 0.2'f32, 0.5'f32, 0.9'f32, 1.0'f32]:
      check prepared.sample(t).get == gradient(original, t, opts).get
  test "prepared gradients convert mixed-space stops once":
    let a = color(tagSrgb, 0.2'f32, 0.3'f32, 0.4'f32).get
    let b = color(tagOklab, 0.7'f32, 0.05'f32, -0.08'f32).get
    let stops = [ColorStop(color: a, pos: 0.0'f32),
      ColorStop(color: b, pos: 1.0'f32)]
    let opts = GradientOpts(space: tagOklch)
    let prepared = prepareGradient(stops, opts).get
    for t in [0.0'f32, 0.25'f32, 0.75'f32, 1.0'f32]:
      check prepared.sample(t).get == gradient(stops, t, opts).get
  test "prepared gradients reject invalid stops once":
    let empty: seq[ColorStop] = @[]
    check prepareGradient(empty, GradientOpts()).error.kind == InvalidOp
    check PreparedGradient().sample(0.5'f32).error.kind == InvalidOp

suite "spline":
  test "two-stop PCHIP is linear at the midpoint":
    let a = color(tagOklab, 0.5'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagOklab, 0.7'f32, 0.0'f32, 0.0'f32).get
    let stops = [ColorStop(color: a, pos: 0.0'f32),
                 ColorStop(color: b, pos: 1.0'f32)]
    let r = spline(stops, 0.5'f32, SplineOpts(space: tagOklab)).get
    check near(r.color.comp(0).float64, 0.6)
  test "PCHIP never warns":
    let a = color(tagOklab, 0.5'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagOklab, 0.7'f32, 0.0'f32, 0.0'f32).get
    let stops = [ColorStop(color: a, pos: 0.0'f32),
                 ColorStop(color: b, pos: 1.0'f32)]
    let r = spline(stops, 0.5'f32, SplineOpts()).get
    check r.warning.isNone
  test "empty stops is InvalidOp":
    let stops: seq[ColorStop] = @[]
    check spline(stops, 0.5'f32, SplineOpts()).error.kind == InvalidOp
  test "duplicate positions are InvalidOp":
    let a = color(tagOklab, 0.5'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagOklab, 0.7'f32, 0.0'f32, 0.0'f32).get
    let stops = [ColorStop(color: a, pos: 0.5'f32),
                 ColorStop(color: b, pos: 0.5'f32)]
    check spline(stops, 0.5'f32, SplineOpts()).error.kind == InvalidOp

suite "easing":
  test "linear easing is identity":
    check near(easing(0.0, easingLinear), 0.0, 1.0e-9)
    check near(easing(0.5, easingLinear), 0.5, 1.0e-9)
    check near(easing(1.0, easingLinear), 1.0, 1.0e-9)
  test "cubic-bezier endpoints are 0 and 1":
    let e = cubicBezierEasing(0.25, 0.1, 0.25, 1.0).get
    check near(easing(0.0, e), 0.0, 1.0e-6)
    check near(easing(1.0, e), 1.0, 1.0e-6)
  test "cubic-bezier rejects x outside [0,1]":
    check cubicBezierEasing(1.5, 0.1, 0.25, 1.0).error.kind == InvalidOp
  test "steps easing rejects count < 1":
    check stepsEasing(0).error.kind == InvalidOp
  test "steps easing jump-end hits endpoints":
    let e = stepsEasing(2, spJumpEnd).get
    check near(easing(0.0, e), 0.0, 1.0e-9)
    check near(easing(1.0, e), 1.0, 1.0e-9)
  test "steps easing jump-both jumps at 0 and 1":
    # n=4 -> 5 jumps at 0, 1/4, 2/4, 3/4, 1; t=0 -> 1/5, t=1 -> 1.
    let e = stepsEasing(4, spJumpBoth).get
    check near(easing(0.0, e), 0.2, 1.0e-9)
    check near(easing(0.5, e), 0.6, 1.0e-9)
    check near(easing(1.0, e), 1.0, 1.0e-9)

suite "interpolateBatch":
  test "batch matches scalar at each t":
    let a = color(tagOklab, 0.5'f32, 0.1'f32, -0.1'f32).get
    let b = color(tagOklab, 0.7'f32, -0.1'f32, 0.1'f32).get
    let ts = [0.0'f32, 0.25'f32, 0.5'f32, 0.75'f32, 1.0'f32]
    let opts = InterpOpts(space: tagOklab)
    let r = interpolateBatch(a, b, ts, opts).get
    check r.len == ts.len
    for i in 0 ..< ts.len:
      let s = interpolate(a, b, ts[i], opts).get
      for j in 0 ..< 3:
        check near(r[i].comp(j).float64, s.comp(j).float64, 1.0e-6)
