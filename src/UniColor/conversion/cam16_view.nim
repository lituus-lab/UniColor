# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# cam16_view — Material DEFAULT CAM16 viewing conditions, shared by the CAM16
# hub slice (hub.nim) and the HCT solver (hct_solver.nim). Extracted into its
# own module so the HCT solver can read `vc` without importing hub (which would
# cycle: hub imports hct_solver). Port of Google material-color-utilities
# viewing_conditions.ts make() with Material DEFAULT arguments (Apache-2.0).
#
# Frozen to Material DEFAULT: adapting luminance L_A ~ 11.726, backgroundLstar
# 50 -> n = Y_b = 0.18419, surround average (f = 1 -> c = 0.69, n_c = 1),
# discounting illuminant false (d ~ 0.845, rgbD ~ [1.0213, 0.9862, 0.9340]).
# One condition, no configurability.

import std/math

import UniColor/core/numerics # cbrtSigned

type
  ViewingConditions* = object
    n*, aw*, nbb*, ncb*, c*, nc*, fl*, flRoot*, z*: float64
    rgbD*: array[3, float64]

# Material yFromLstar: Y on the [0,100] scale from L*. Uses the CIELAB nonlinearity
# toe (eps = 216/24389, kappa = 24389/27).
func yFromLstar100*(lstar: float64): float64 {.raises: [].} =
  let ft = (lstar + 16.0) / 116.0
  let ft3 = ft * ft * ft
  const e = 216.0 / 24389.0
  const kappa = 24389.0 / 27.0
  if ft3 > e: ft3 * 100.0 else: (116.0 * ft - 16.0) / kappa * 100.0

# Port of viewing_conditions.ts make() with Material DEFAULT arguments. Pure math
# (no global reads), so it is a `func` called once at module load into the `vc` let.
func defaultViewingConditions*(): ViewingConditions {.raises: [].} =
  const wp: array[3, float64] = [95.047, 100.0, 108.883] # D65 on [0,100]
  let rW = 0.401288 * wp[0] + 0.650173 * wp[1] - 0.051461 * wp[2]
  let gW = -0.250268 * wp[0] + 1.204414 * wp[1] + 0.045854 * wp[2]
  let bW = -0.002079 * wp[0] + 0.048952 * wp[1] + 0.953127 * wp[2]
  let surround = 2.0 # average -> f = 1.0
  let f = 0.8 + surround / 10.0
  let c = if f >= 0.9: 0.59 + (0.69 - 0.59) * ((f - 0.9) * 10.0)
          else: 0.525 + (0.59 - 0.525) * ((f - 0.8) * 10.0)
  let nc = f
  let la = (200.0 / PI) * yFromLstar100(50.0) / 100.0 # adapting luminance ~ 11.726
  var d = f * (1.0 - (1.0 / 3.6) * exp((-la - 42.0) / 92.0)) # discounting = false
  if d > 1.0: d = 1.0
  elif d < 0.0: d = 0.0
  result.rgbD = [d * 100.0 / rW + 1.0 - d, d * 100.0 / gW + 1.0 - d,
                 d * 100.0 / bW + 1.0 - d]
  let k = 1.0 / (5.0 * la + 1.0)
  let k4 = k * k * k * k
  let k4f = 1.0 - k4
  result.fl = k4 * la + 0.1 * k4f * k4f * cbrtSigned(5.0 * la)
  let n = yFromLstar100(50.0) / wp[1] # backgroundLstar 50 -> n = 0.18419
  result.n = n
  result.z = 1.48 + sqrt(n)
  result.nbb = 0.725 / pow(n, 0.2)
  result.ncb = result.nbb
  result.c = c
  result.nc = nc
  let rf0 = pow(result.fl * result.rgbD[0] * rW / 100.0, 0.42)
  let gf0 = pow(result.fl * result.rgbD[1] * gW / 100.0, 0.42)
  let bf0 = pow(result.fl * result.rgbD[2] * bW / 100.0, 0.42)
  let rA = 400.0 * rf0 / (rf0 + 27.13)
  let gA = 400.0 * gf0 / (gf0 + 27.13)
  let bA = 400.0 * bf0 / (bf0 + 27.13)
  result.aw = (2.0 * rA + gA + 0.05 * bA) * result.nbb
  result.flRoot = pow(result.fl, 0.25)

func signum*(x: float64): float64 {.inline, raises: [].} =
  if x > 0.0: 1.0 elif x < 0.0: -1.0 else: 0.0

# Computed once at module load. Helper procs in hub.nim/hct_solver.nim read this
# `let` (procs, not funcs — funcs cannot read a module-level let). Reading a let
# never throws, so raises:[] is preserved.
let vc* = defaultViewingConditions()
