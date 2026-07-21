# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# spline — spline interpolation over color stops (CSS Color 4).
#
# `spline(stops, t, opts)` converts the stops to `opts.space`, fits a cubic
# spline through the knots component-wise (PCHIP monotone default, or natural
# cubic opt-in), and returns the value at `t` in `opts.space` (or `target` when
# `gamutMap`). The result carries a non-fatal `warning` when the cubic-natural
# method overshoots the data range — a `SplineResult = { color, warning }`
# carries it alongside the successful color rather than surfacing it as a hard
# `err`.
#
# Methods:
#   - PCHIP (default, Fritsch-Carlson): monotone cubic Hermite. Tangents are
#     the weighted harmonic mean of the adjacent slopes, flattened to 0 at local
#     extrema; endpoints take the slope of their single segment. No overshoot,
#     preserves data monotonicity.
#   - Cubic natural (opt-in): the C² natural cubic (second derivative 0 at the
#     ends, Thomas tridiagonal solve for the interior). Smoother but NOT
#     monotonicity-preserving — it can overshoot the data range, reported as a
#     non-fatal warning.
#
# Spec hole: CSS Color 4 does not define splining the angular hue of
# cylindrical (Jch) spaces. L/J and C (and Cartesian comps) are splined by the
# chosen method; the hue (component 2 of polar spaces) is interpolated LINEARLY
# between the two segment knots via `interpHue` — a naive angular spline would
# wrap. PCHIP on polar L/C is still monotone-safe.
import std/options
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/core/numerics
import UniColor/spaces/spaces
import UniColor/conversion/conversion
import UniColor/interpolation/hue
import UniColor/interpolation/gradient

const OVERSHOOT_EPS = 1.0e-6

type
  SplineMethod* {.pure.} = enum
    smPchip ## monotone cubic Hermite (default) — no overshoot, preserves data
            ## monotonicity
    smCubicNatural ## natural cubic — may overshoot (opt-in, warning on overshoot)

  SplineResult* = object
    ## Output of `spline`: the splined color plus an optional non-fatal warning.
    ## `warning` is `some` only when `smCubicNatural` overshoots the data range;
    ## `none` for PCHIP (which never overshoots) or when cubic natural happens
    ## not to.
    color*: Color
    warning*: Option[ColorError]

  SplineOpts* = object
    ## Options for `spline`. Mirrors the blend-relevant fields of `InterpOpts`/
    ## `GradientOpts` plus the spline method selector.
    space*: SpaceTag = tagOklch ## interpolation space (default OKLCH)
    hue*: HueMethod = hmShorter ## hue method for cylindrical spaces (default shorter)
    spline*: SplineMethod = smPchip ## spline method (default PCHIP monotone)
    premultiplied*: bool = false ## premultiplied alpha opt-in
    gamutMap*: bool = false ## gamut-map the result into `target`; result in `target`
    target*: SpaceTag = tagSrgb ## destination gamut for `gamutMap` (default sRGB)
    clampT*: bool = true ## clamp t to [first_pos, last_pos] (default); false =
                           ## extrapolation

func isPolarJch(d: SpaceDescriptor): bool =
  ## [L/J, C, h] cylindrical layout (hue at component 2). Same set as
  ## `space.isPolarJch`.
  d.family in {famLch, famOklch, famCam16, famHct}

func pchipTangents(xs, ys: openArray[float64]): seq[float64] =
  ## Fritsch-Carlson monotone tangents at each knot. Interior knots use the
  ## weighted harmonic mean of the two adjacent slopes (flattened to 0 at local
  ## extrema where the slopes differ in sign); endpoints take their single
  ## segment's slope (monotone-safe: always within the Fritsch-Carlson [0, 3Δ]
  ## band). n=2 -> both ends equal the lone slope (Hermite then reduces to the
  ## linear blend). n=1 -> all 0 (constant).
  let n = xs.len
  result = newSeq[float64](n)
  if n <= 1:
    return
  if n == 2:
    let m = (ys[1] - ys[0]) / (xs[1] - xs[0])
    result[0] = m
    result[1] = m
    return
  var d = newSeq[float64](n - 1)
  for i in 0 ..< n - 1:
    d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])
  for i in 1 ..< n - 1:
    if d[i - 1] * d[i] <= 0.0:
      result[i] = 0.0 # local extremum -> flat (preserves the turn without overshoot)
    else:
      let h0 = xs[i] - xs[i - 1]
      let h1 = xs[i + 1] - xs[i]
      let w1 = 2.0 * h1 + h0 # weight on d[i-1]
      let w2 = h1 + 2.0 * h0 # weight on d[i]
      result[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i]) # weighted harmonic mean
  result[0] = d[0] # endpoint = its segment's slope (monotone-safe)
  result[n - 1] = d[n - 2]

func cubicNaturalSecondDerivs(xs, ys: openArray[float64]): seq[float64] =
  ## Second derivatives of the C² natural cubic (m[0] = m[n-1] = 0). Interior
  ## values come from the tridiagonal system h[i-1]·m[i-1] + 2(h[i-1]+h[i])·m[i]
  ## + h[i]·m[i+1] = 6·((y[i+1]-y[i])/h[i] - (y[i]-y[i-1])/h[i-1]), solved by the
  ## Thomas algorithm. n<=2 -> all 0 (the single segment degenerates to a line).
  let n = xs.len
  result = newSeq[float64](n)
  if n <= 2:
    return
  var h = newSeq[float64](n - 1)
  for i in 0 ..< n - 1:
    h[i] = xs[i + 1] - xs[i]
  let m = n - 2 # interior unknowns (knots 1 .. n-2)
  if m == 0:
    return
  var a = newSeq[float64](m) # sub-diagonal (h[i-1])
  var b = newSeq[float64](m) # diagonal 2(h[i-1]+h[i])
  var c = newSeq[float64](m) # super-diagonal (h[i])
  var d = newSeq[float64](m) # rhs
  for k in 0 ..< m:
    let i = k + 1
    a[k] = h[i - 1]
    b[k] = 2.0 * (h[i - 1] + h[i])
    c[k] = h[i]
    d[k] = 6.0 * ((ys[i + 1] - ys[i]) / h[i] - (ys[i] - ys[i - 1]) / h[i - 1])
  # The natural boundaries m[0]=0 and m[n-1]=0 make the first/last coupling terms
  # vanish, so the tridiagonal over the interior unknowns is exactly (a, b, c, d).
  var cp = newSeq[float64](m)
  var dp = newSeq[float64](m)
  cp[0] = c[0] / b[0]
  dp[0] = d[0] / b[0]
  for k in 1 ..< m:
    let denom = b[k] - a[k] * cp[k - 1]
    cp[k] = c[k] / denom
    dp[k] = (d[k] - a[k] * dp[k - 1]) / denom
  var sol = newSeq[float64](m)
  sol[m - 1] = dp[m - 1]
  for k in countdown(m - 2, 0):
    sol[k] = dp[k] - cp[k] * sol[k + 1]
  for k in 0 ..< m:
    result[k + 1] = sol[k]
  # result[0] and result[n-1] stay 0 (natural)

func evalPchip(x, x0, x1, y0, y1, m0, m1: float64): float64 =
  ## Cubic Hermite on segment [x0, x1] with end values y0, y1 and tangents m0, m1.
  let h = x1 - x0
  let u = (x - x0) / h
  let u2 = u * u
  let u3 = u2 * u
  let h00 = 2.0 * u3 - 3.0 * u2 + 1.0
  let h10 = u3 - 2.0 * u2 + u
  let h01 = -2.0 * u3 + 3.0 * u2
  let h11 = u3 - u2
  h00 * y0 + h10 * m0 * h + h01 * y1 + h11 * m1 * h

func evalCubic(x, x0, h, y0, y1, m0, m1: float64): float64 =
  ## Natural cubic on segment [x0, x0+h] with end second derivatives m0, m1.
  let u = x - x0
  let a = y0
  let b = (y1 - y0) / h - h * (2.0 * m0 + m1) / 6.0
  let c = m0 / 2.0
  let d = (m1 - m0) / (6.0 * h)
  a + b * u + c * u * u + d * u * u * u

func evalSplineAt(mKind: SplineMethod, xs, ys: openArray[float64],
    xEval: float64, seg: int): float64 =
  ## Spline of `ys` over knots `xs` evaluated at `xEval` within segment `seg`.
  ## n=1 -> the lone knot; n=2 -> linear (both methods reduce to it); n>=2 ->
  ## per-method segment eval.
  if xs.len <= 1:
    return ys[0]
  case mKind
  of smPchip:
    let m = pchipTangents(xs, ys)
    evalPchip(xEval, xs[seg], xs[seg + 1], ys[seg], ys[seg + 1], m[seg], m[seg + 1])
  of smCubicNatural:
    let m2 = cubicNaturalSecondDerivs(xs, ys)
    let h = xs[seg + 1] - xs[seg]
    evalCubic(xEval, xs[seg], h, ys[seg], ys[seg + 1], m2[seg], m2[seg + 1])

proc spline*(stops: openArray[ColorStop], t: float32,
    opts: SplineOpts): Result[SplineResult, ColorError] {.raises: [].} =
  ## Spline interpolation over color stops (CSS Color 4). Returns the splined
  ## value at `t` in `opts.space` (or `target` when `gamutMap`), plus a non-fatal
  ## `warning` when `smCubicNatural` overshoots the data range. PCHIP never
  ## warns. Polar (Jch) hues are interpolated linearly between the segment knots
  ## (spec hole — see module header). Empty stops, non-finite / out-of-[0,1] /
  ## unsorted positions return InvalidOp; hub/`to`/`gamutMap` errors
  ## (UnknownSpace, InvalidColor) propagate unchanged.
  if stops.len == 0:
    return err[SplineResult, ColorError](colorError(InvalidOp,
        "spline: empty stops", "spline"))
  for i in 0 ..< stops.len:
    let p = stops[i].pos.float64
    if isNan(p) or isInf(p):
      return err[SplineResult, ColorError](colorError(InvalidOp,
          "spline: non-finite stop position", "spline"))
    if p < 0.0 or p > 1.0:
      return err[SplineResult, ColorError](colorError(InvalidOp,
          "spline: stop position out of [0,1]", "spline"))
    if i > 0 and p < stops[i - 1].pos.float64:
      return err[SplineResult, ColorError](colorError(InvalidOp,
          "spline: stop positions must be sorted non-decreasing", "spline"))
  let dOpt = spaceByTag(opts.space)
  if dOpt.isNone:
    return err[SplineResult, ColorError](colorError(UnknownSpace,
        "spline: space not registered", spaceName(opts.space)))
  let d = dOpt.get
  let polar = isPolarJch(d)
  let n = stops.len
  # Gather knots in opts.space: positions, per-component values, alphas (and hues for polar).
  var xs = newSeq[float64](n)
  var comps = newSeq[array[3, float64]](n)
  var alphas = newSeq[float64](n)
  var hues = newSeq[float64](n)
  for i in 0 ..< n:
    let cR = to(stops[i].color, opts.space)
    if cR.isErr:
      return err[SplineResult, ColorError](cR.error)
    let c = cR.get
    xs[i] = stops[i].pos.float64
    for k in 0 ..< 3:
      comps[i][k] = c.comp(k).float64
    alphas[i] = c.alpha().float64
    if polar:
      hues[i] = c.comp(2).float64
  if opts.premultiplied:
    # Premultiply the non-hue components by their knot alpha (hue is angular —
    # never premul). Un-premultiply after splining by the splined alpha.
    let lastK = if polar: 2 else: 3
    for i in 0 ..< n:
      for k in 0 ..< lastK:
        comps[i][k] = comps[i][k] * alphas[i]
  # Per-component knot sequences.
  var ysK: array[3, seq[float64]]
  for k in 0 ..< 3:
    ysK[k] = newSeq[float64](n)
    for i in 0 ..< n:
      ysK[k][i] = comps[i][k]
  var ysAlpha = newSeq[float64](n)
  for i in 0 ..< n:
    ysAlpha[i] = alphas[i]
  let pFirst = xs[0]
  let pLast = xs[n - 1]
  let tt = if opts.clampT: clampCibled(t.float64, pFirst, pLast) else: t.float64
  # Segment containing tt (boundary cases clamp to the first/last segment so
  # extrapolation extends the boundary segment rather than returning a constant).
  var seg = 0
  if n >= 2:
    if tt <= pFirst:
      seg = 0
    elif tt >= pLast:
      seg = n - 2
    else:
      for j in 1 ..< n - 1:
        if xs[j] <= tt:
          seg = j
        else:
          break
  var splinedComps: array[3, float64]
  var splinedAlpha: float64
  if n == 1:
    splinedComps = comps[0]
    splinedAlpha = alphas[0]
  else:
    let lastK = if polar: 2 else: 3
    for k in 0 ..< lastK:
      splinedComps[k] = evalSplineAt(opts.spline, xs, ysK[k], tt, seg)
    if polar:
      # Hue: linear along the chosen arc between the segment knots (not splined).
      let hh = xs[seg + 1] - xs[seg]
      let u = if hh > 0.0: (tt - xs[seg]) / hh else: 0.0
      splinedComps[2] = interpHue(hues[seg], hues[seg + 1], u, opts.hue)
    splinedAlpha = evalSplineAt(opts.spline, xs, ysAlpha, tt, seg)
  # Un-premultiply (premultiplied opt-in) by the splined alpha; 0 alpha -> 0.
  var finalComps = splinedComps
  if opts.premultiplied:
    let lastK = if polar: 2 else: 3
    for k in 0 ..< lastK:
      finalComps[k] = if splinedAlpha > 0.0: splinedComps[k] /
          splinedAlpha else: 0.0
    # polar hue (comp 2) was never premultiplied — keep splinedComps[2] (already in place).
  # Overshoot warning (cubic natural only): any splined non-hue component
  # leaving its knot range signals the non-monotone overshoot. PCHIP is skipped
  # (it is shape-preserving by construction).
  var warning: Option[ColorError] = none[ColorError]()
  if opts.spline == smCubicNatural and n >= 2:
    let lastK = if polar: 2 else: 3
    for k in 0 ..< lastK:
      var yMin = comps[0][k]
      var yMax = comps[0][k]
      for i in 1 ..< n:
        if comps[i][k] < yMin:
          yMin = comps[i][k]
        if comps[i][k] > yMax:
          yMax = comps[i][k]
      if splinedComps[k] < yMin - OVERSHOOT_EPS or splinedComps[k] > yMax + OVERSHOOT_EPS:
        warning = some[ColorError](colorError(NumericalError,
            "spline: cubic natural overshoots the data range (non-fatal, opt-in)",
            "spline", Severity.Warning))
        break
  let built = color(opts.space, toF32(finalComps[0]), toF32(finalComps[1]),
      toF32(finalComps[2]), toF32(splinedAlpha))
  if built.isErr:
    return err[SplineResult, ColorError](built.error)
  var col = built.get
  if opts.gamutMap:
    let g = gamutMap(col, opts.target)
    if g.isErr:
      return err[SplineResult, ColorError](g.error)
    col = g.get
  ok[SplineResult, ColorError](SplineResult(color: col, warning: warning))
