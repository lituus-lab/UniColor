# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# easing — easing functions (CSS Easing Functions Level 1).
#
# `easing(t, e)` transforms the parameter `t ∈ [0,1]` BEFORE interpolation. Input
# is clamped to [0,1] (NaN preserved via `clampCibled`); the result is the eased
# progress.
#
# This module follows CSS Easing Functions Level 1 (the canonical reference):
#   - linear: t' = t.
#   - ease / easeIn / easeOut / easeInOut: the four fixed cubic-beziers
#     (0.25,0.1,0.25,1) / (0.42,0,1,1) / (0,0,0.58,1) / (0.42,0,0.58,1).
#   - cubicBezier(p1x,p1y,p2x,p2y): the parametric CSS `cubic-bezier`. The x
#     control points (p1x, p2x) MUST lie in [0,1] so B_x is monotone and
#     invertible; the y control points may overshoot [0,1] (CSS allows back /
#     anticipation). B_x(u)=t is solved by Newton-Raphson with a bisection
#     fallback, then t' = B_y(u).
#   - steps(n, position): the CSS `steps` staircase. Four positions:
#       jumpEnd (end, default): right-continuous, jump at the END of each step.
#       jumpStart (start): left-continuous, jump at the START (0 -> 1/n).
#       jumpNone: count-1 jumps, no jump at either end (n>=2; n==1 -> linear).
#       jumpBoth: count+1 jumps at both ends (0 -> 1/(n+1)).
#     `start`/`end` are CSS aliases of `jumpStart`/`jumpEnd`.
#
# Primitives only — `easing(t, e)` + constructors. Wiring easing into
# `interpolate`/`gradient`/`spline` (per-component opt-in) is deferred;
# `InterpOpts` does not yet carry an easing field.
import std/math
import UniColor/core/core
import UniColor/core/numerics

type
  EasingKind* {.pure.} = enum
    ekLinear      ## t' = t
    ekEase        ## fixed cubic-bezier (0.25,0.1,0.25,1)
    ekEaseIn      ## fixed cubic-bezier (0.42,0,1,1)
    ekEaseOut     ## fixed cubic-bezier (0,0,0.58,1)
    ekEaseInOut   ## fixed cubic-bezier (0.42,0,0.58,1)
    ekCubicBezier ## parametric cubic-bezier (CSS `cubic-bezier`)
    ekSteps       ## staircase (CSS `steps`)

  StepPosition* {.pure.} = enum
    spJumpStart ## jump at the start (CSS `jump-start` / `start`); 0 -> 1/n
    spJumpEnd   ## jump at the end (CSS `jump-end` / `end`, default); 0 -> 0
    spJumpNone  ## no jump at either end (CSS `jump-none`); n-1 jumps, n==1 -> linear
    spJumpBoth  ## jump at both ends (CSS `jump-both`); 0 -> 1/(n+1)

  Easing* = object
    ## A tagged easing function. The `ekCubicBezier` branch carries the four
    ## control-point coordinates; `ekSteps` carries the count and position; the
    ## fixed presets need no parameters. Construct via `cubicBezierEasing`/
    ## `stepsEasing` or the `easingLinear`/`easingEase*` constants.
    case kind*: EasingKind
    of ekCubicBezier:
      p1x*: float64
      p1y*: float64
      p2x*: float64
      p2y*: float64
    of ekSteps:
      count*: int
      position*: StepPosition
    else:
      discard

const
  easingLinear* = Easing(kind: ekLinear)
  easingEase* = Easing(kind: ekEase)
  easingEaseIn* = Easing(kind: ekEaseIn)
  easingEaseOut* = Easing(kind: ekEaseOut)
  easingEaseInOut* = Easing(kind: ekEaseInOut)

# Fixed cubic-bezier control points for the named presets (CSS Easing Functions
# Level 1).
const
  easePts = (0.25, 0.1, 0.25, 1.0)
  easeInPts = (0.42, 0.0, 1.0, 1.0)
  easeOutPts = (0.0, 0.0, 0.58, 1.0)
  easeInOutPts = (0.42, 0.0, 0.58, 1.0)

proc cubicBezierEasing*(p1x, p1y, p2x, p2y: float64): Result[Easing,
    ColorError] {.raises: [].} =
  ## Build a `cubic-bezier` easing (CSS Easing Functions Level 1). `p1x` and
  ## `p2x` MUST be in [0,1] (so B_x is monotone/invertible); `p1y`/`p2y` may be
  ## any finite value (y overshoot is allowed). Out-of-range/non-finite x
  ## control points return InvalidOp.
  if isNan(p1x) or isInf(p1x) or isNan(p2x) or isInf(p2x) or isNan(p1y) or
      isInf(p1y) or isNan(p2y) or isInf(p2y):
    return err[Easing, ColorError](colorError(InvalidOp,
        "cubicBezierEasing: non-finite control point", "easing"))
  if p1x < 0.0 or p1x > 1.0 or p2x < 0.0 or p2x > 1.0:
    return err[Easing, ColorError](colorError(InvalidOp,
        "cubicBezierEasing: x control points must be in [0,1]", "easing"))
  ok[Easing, ColorError](Easing(kind: ekCubicBezier, p1x: p1x, p1y: p1y,
      p2x: p2x, p2y: p2y))

proc stepsEasing*(count: int, position = spJumpEnd): Result[Easing,
    ColorError] {.raises: [].} =
  ## Build a `steps(n, position)` easing (CSS Easing Functions Level 1). `count`
  ## MUST be >= 1; `position` selects the jump pattern (default `jumpEnd`/`end`).
  ## Returns InvalidOp on a bad count. `jump-none` with count 1 yields a 0-jump
  ## (linear) function.
  if count < 1:
    return err[Easing, ColorError](colorError(InvalidOp,
        "stepsEasing: count must be >= 1", "easing"))
  ok[Easing, ColorError](Easing(kind: ekSteps, count: count,
      position: position))

func bezierComp(u, p1, p2: float64): float64 =
  ## Cubic-bezier ordinate for one axis with control points p1, p2 (P0=0, P3=1):
  ## B(u) = 3(1-u)²u·p1 + 3(1-u)u²·p2 + u³.
  let mt = 1.0 - u
  3.0 * mt * mt * u * p1 + 3.0 * mt * u * u * p2 + u * u * u

func bezierDerivX(u, p1x, p2x: float64): float64 =
  ## dB_x/du = 3(1-u)²·p1x + 6(1-u)u·(p2x-p1x) + 3u²·(1-p2x).
  let mt = 1.0 - u
  3.0 * mt * mt * p1x + 6.0 * mt * u * (p2x - p1x) + 3.0 * u * u * (1.0 - p2x)

func solveBezierX(t, p1x, p2x: float64): float64 =
  ## Solve B_x(u) = t for u ∈ [0,1] (Newton-Raphson, bisection fallback). B_x is
  ## monotone increasing (p1x, p2x ∈ [0,1]), so the root is unique. Returns u
  ## with B_x(u) ≈ t.
  if t <= 0.0:
    return 0.0
  if t >= 1.0:
    return 1.0
  var u = t # initial guess (B_x is roughly identity for smooth control points)
  for _ in 0 ..< 8:
    let x = bezierComp(u, p1x, p2x) - t
    if abs(x) < 1.0e-9:
      return u
    let dx = bezierDerivX(u, p1x, p2x)
    if abs(dx) < 1.0e-9:
      break # derivative ~0 (degenerate) -> fall back to bisection
    let nu = u - x / dx
    if nu < 0.0 or nu > 1.0:
      break # left the bracket -> fall back to bisection
    u = nu
  # Bisection fallback (robust even when Newton leaves the bracket or stalls).
  var lo = 0.0
  var hi = 1.0
  u = t
  for _ in 0 ..< 60:
    let x = bezierComp(u, p1x, p2x)
    if abs(x - t) < 1.0e-9:
      return u
    if x < t:
      lo = u
    else:
      hi = u
    u = (lo + hi) * 0.5
  u

func stepsAt(t: float64, count: int, position: StepPosition): float64 =
  ## CSS `steps(n, position)` output for clamped progress `t`.
  let n = float64(count)
  case position
  of spJumpEnd:
    result = min(1.0, floor(t * n) / n) # jump at end; t=0 -> 0, t=1 -> 1
  of spJumpStart:
    result = min(1.0, (floor(t * n) + 1.0) / n) # jump at start; t=0 -> 1/n
  of spJumpNone:
    if count <= 1:
      result = t # 0 jumps -> linear
    else:
      result = min(1.0, floor(t * n) / float64(count - 1)) # n-1 jumps, no end jumps
  of spJumpBoth:
    let j = n + 1.0
    # n+1 jumps at 0, 1/n, ..., 1 (step index floor(t*n), like the other
    # branches); t=0 -> 1/(n+1), t=1 -> 1.
    result = min(1.0, (floor(t * n) + 1.0) / j)

func easingCubicBezier(t: float64, p1x, p1y, p2x, p2y: float64): float64 =
  ## cubic-bezier: solve B_x(u)=t, return B_y(u).
  let u = solveBezierX(t, p1x, p2x)
  bezierComp(u, p1y, p2y)

proc easing*(t: float64, e: Easing): float64 {.raises: [].} =
  ## Easing function. Transforms progress `t` (clamped to [0,1], NaN preserved)
  ## into eased progress `t'`. Deterministic. Endpoints: `easing(1, e) == 1`
  ## for every valid easing; `easing(0, e) == 0` for linear/ease*/cubicBezier/
  ## jumpEnd/jumpNone (jumpStart maps 0 -> 1/n, jumpBoth maps 0 -> 1/(n+1) — both
  ## jump at the start, per CSS).
  let tc = clampCibled(t, 0.0, 1.0) # clamp input to [0,1]; NaN preserved
  case e.kind
  of ekLinear:
    result = tc
  of ekEase:
    result = easingCubicBezier(tc, easePts[0], easePts[1], easePts[2], easePts[3])
  of ekEaseIn:
    result = easingCubicBezier(tc, easeInPts[0], easeInPts[1], easeInPts[2],
        easeInPts[3])
  of ekEaseOut:
    result = easingCubicBezier(tc, easeOutPts[0], easeOutPts[1], easeOutPts[2],
        easeOutPts[3])
  of ekEaseInOut:
    result = easingCubicBezier(tc, easeInOutPts[0], easeInOutPts[1],
        easeInOutPts[2], easeInOutPts[3])
  of ekCubicBezier:
    result = easingCubicBezier(tc, e.p1x, e.p1y, e.p2x, e.p2y)
  of ekSteps:
    result = stepsAt(tc, e.count, e.position)
