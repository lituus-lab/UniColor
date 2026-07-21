# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# hue — CSS Color 4 hue interpolation math.
#
# The four hue methods as signed arcs from h1 to h2, plus normalization to
# [0,360). Pure hue math: it knows nothing about colors or achromaticity. The
# achromatic rule (an achromatic bound adopts the other's hue; 0 if both
# achromatic) is applied in `interpolate` (space.nim), which owns the colors
# and `isAchromatic`.
#
# Reference: CSS Color 4 §13.4 hue interpolation. Given h1, h2 (any reals,
# taken mod 360) the signed delta from h1 to h2 is:
#   shorter:    delta in [-180, 180]            (the shortest signed arc)
#   longer:     delta in (-360,-180] ∪ [180,360) (the complement of shorter)
#   increasing: delta in [0, 360)               (always wraps forward)
#   decreasing: delta in (-360, 0]              (always wraps backward)
# Edge cases (verified by hand against the reference):
#   h1 == h2:        shorter=0, longer=360 (full turn), increasing=0, decreasing=0.
#   delta == +180:   shorter/longer/increasing -> +180 ; decreasing -> -180.
#   delta == -180:   shorter/longer/decreasing -> -180 ; increasing -> +180.
# `shorter` is antisymmetric (shorter(h1,h2) == -shorter(h2,h1)); the ±180
# boundary keeps the sign of the raw delta, so 180 -> 0 takes the -180 arc
# (midpoint 90), not +180.
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
