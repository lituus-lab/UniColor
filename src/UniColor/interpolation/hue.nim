# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# hue — CSS Color 4 hue interpolation math. Pure hue math (no color/achromatic
# knowledge). Given h1, h2 (taken mod 360), the signed delta from h1 to h2:
#   shorter:    [-180, 180]             (shortest signed arc)
#   longer:     (-360,-180] ∪ [180,360) (complement of shorter)
#   increasing: [0, 360)                (always forward)
#   decreasing: (-360, 0]               (always backward)
# The achromatic rule is applied in `interpolate` (space.nim), which owns the
# colors and `isAchromatic`.
import std/math

type
  HueMethod* {.pure.} = enum
    ## CSS Color 4 hue interpolation method.
    hmShorter    ## shortest arc (default)
    hmLonger     ## longest arc
    hmIncreasing ## increasing direction modulo 360
    hmDecreasing ## decreasing direction modulo 360

func hueMod(x, y: float64): float64 =
  ## Positive modulo for y > 0 (result in [0, y)). Nim's `mod` is integer-only,
  ## so the float hue math uses this.
  result = x - floor(x / y) * y

func normHue*(h: float64): float64 =
  ## Normalize a hue to [0, 360).
  result = hueMod(h, 360.0)

func hueDelta*(hm: HueMethod, h1, h2: float64): float64 =
  ## Signed arc from h1 to h2 under the chosen CSS Color 4 method. Range:
  ## shorter [-180,180], longer (-360,-180]∪[180,360), increasing [0,360),
  ## decreasing (-360,0]. This is the exact §13.4 pseudo-code. Hues are
  ## normalized to [0,360) FIRST, so 0 and 360 are the same angle: the hub may
  ## return either representation for a hue of exactly 0, and the delta must
  ## not depend on it.
  let raw = normHue(h2) - normHue(h1)
  case hm
  of hmShorter:
    var d = raw
    if d > 180.0:
      d -= 360.0
    elif d < -180.0:
      d += 360.0
    result = d
  of hmLonger:
    var d = raw
    if d > 0.0 and d < 180.0:
      d -= 360.0
    elif d > -180.0 and d <= 0.0:
      d += 360.0
    result = d
  of hmIncreasing:
    var d = raw
    if d < 0.0:
      d += 360.0
    result = d
  of hmDecreasing:
    var d = raw
    if d > 0.0:
      d -= 360.0
    result = d

func interpHue*(h1, h2, t: float64, hm: HueMethod): float64 =
  ## Hue at parameter `t` along the `hm` arc from h1 to h2, normalized to
  ## [0,360). `interpHue(h1, h2, 0, hm) == normHue(h1)` and
  ## `interpHue(h1, h2, 1, hm) == normHue(h1 + hueDelta(hm, h1, h2))`
  ## (== h2 mod 360). Callers apply the achromatic rule: pass the adopted hue
  ## as BOTH bounds when one bound is achromatic.
  result = normHue(h1 + hueDelta(hm, h1, h2) * t)
