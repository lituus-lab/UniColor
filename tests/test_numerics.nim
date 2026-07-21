# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import std/math
import UniColor

suite "numerics — frozen tolerances":
  test "TOL_JND is the CSS Color 4 gamut-map JND":
    check TOL_JND == 0.02
  test "TOL_ROUNDTRIP is ~0.001":
    check abs(TOL_ROUNDTRIP - 0.001) < 1e-9
  test "TOL_EQUAL is ~1e-4":
    check abs(TOL_EQUAL - 1.0e-4) < 1e-12
  test "EPS_LAB is exactly 6/29 (no approx)":
    check EPS_LAB == 6.0 / 29.0

suite "clampCibled — targeted, never blanket":
  test "keeps in-range value unchanged":
    check clampCibled(0.5, 0.0, 1.0) == 0.5
    check clampCibled(5.0, 0.0, 10.0) == 5.0
  test "clamps below low bound":
    check clampCibled(-0.5, 0.0, 1.0) == 0.0
  test "clamps above high bound":
    check clampCibled(1.5, 0.0, 1.0) == 1.0
  test "preserves NaN — propagation, no masking":
    check isNan(clampCibled(NaN, 0.0, 1.0))

suite "cbrtSigned — preserves sign (OKLab Ottosson)":
  test "positive cube root":
    check cbrtSigned(27.0) == 3.0
  test "negative preserves sign (not cbrt(abs))":
    check cbrtSigned(-8.0) == -2.0
  test "zero is zero":
    check cbrtSigned(0.0) == 0.0
  test "round-trip cbrt(x)^3 ~= x for signed values":
    for x in [-10.0, -1.0, -0.125, 0.0, 0.125, 1.0, 10.0]:
      let c = cbrtSigned(x)
      check nearlyEqual(c * c * c, x, 1e-9, 1e-9)

suite "NaN/Inf helpers — Inf treated as NaN":
  test "isNan detects NaN only":
    check isNan(NaN)
    check not isNan(1.0)
  test "isInf detects both infinities":
    check isInf(Inf)
    check isInf(-Inf)
    check not isInf(1.0)
  test "isFinite excludes NaN and Inf":
    check isFinite(1.0)
    check not isFinite(NaN)
    check not isFinite(Inf)

suite "f32<->f64 helpers — store f32, compute f64":
  test "toF32 demotes with RNE":
    check toF32(0.5) == 0.5'f32
  test "toF64 promotes":
    check toF64(0.5'f32) == 0.5
  test "round-trip within f32 precision":
    for x in [0.1, 0.5, 1.0 / 3.0, 0.999, 2.0]:
      check nearlyEqual(toF64(toF32(x)), x, 1e-6, 1e-6)

suite "nearlyEqual — TOL_NUMERIC abs+rel":
  test "equal values are nearly equal":
    check nearlyEqual(1.0, 1.0)
  test "tiny abs difference within absTol":
    check nearlyEqual(1.0, 1.0 + 1e-12)
  test "large gap is not nearly equal":
    check not nearlyEqual(1.0, 2.0)
  test "relative tolerance handles large magnitudes":
    check nearlyEqual(1.0e6, 1.0e6 + 1.0, 1e-9, 1e-6)
  test "NaN is not nearly equal to anything (propagation preserved)":
    check not nearlyEqual(NaN, NaN)
    check not nearlyEqual(NaN, 1.0)
  test "same infinity is nearly equal":
    check nearlyEqual(Inf, Inf)
    check nearlyEqual(-Inf, -Inf)
  test "opposite infinities are not nearly equal":
    check not nearlyEqual(Inf, -Inf)
  test "infinity vs finite is not nearly equal":
    check not nearlyEqual(Inf, 1.0)
    check not nearlyEqual(1.0, Inf)
    check not nearlyEqual(-Inf, 1.0)
