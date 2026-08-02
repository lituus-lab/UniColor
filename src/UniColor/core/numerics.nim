# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# numerics — frozen tolerances, targeted clamp, signed cbrt, NaN/Inf, f32<->f64.
# No fast-math. Frozen RNE (roundTiesToEven). Pure funcs, raises:[].

import std/math

# Named tolerances frozen per major. Change = major + MIGRATIONS. Regression
# beyond = CI failure.
const
  TOL_JND* = 0.02           # ΔE_OK — gamut map JND (CSS Color 4 binary search).
  TOL_ROUNDTRIP* = 0.001    # reversible round-trip all-pairs (ΔE/L2).
  TOL_EQUAL* = 1.0e-4       # canonical equality, graph consistency
                            # (short-path == multi-bond).
  TOL_NUMERIC_ABS* = 1.0e-9 # cross-platform/threads regression (absolute).
  TOL_NUMERIC_REL* = 1.0e-6 # regression (relative).
  EPS_LAB* = 6.0 / 29.0     # CIELAB ε = 6/29 — chromaticity function threshold
                            # (no approx).

func clampTargeted*(v, lo, hi: float64): float64 {.inline, raises: [].} =
  ## Clamp to explicit output bounds (never blanket). Preserves NaN: a NaN is
  ## neither clamped nor masked.
  if isNaN(v):
    return v
  if v < lo:
    lo
  elif v > hi:
    hi
  else:
    v

func cbrtSigned*(x: float64): float64 {.inline, raises: [].} =
  ## Signed cbrt — preserves the sign of negative components (OKLab Ottosson).
  ## `math.cbrt` is correctly rounded and sign-preserving; wrapped to name the
  ## invariant.
  math.cbrt(x)

func isNan*(x: float64): bool {.inline, raises: [].} =
  ## Detects NaN.
  math.isNaN(x)

func isInf*(x: float64): bool {.inline, raises: [].} =
  ## Detects Inf (positive or negative) — treated as NaN for chromatic components.
  let c = classify(x)
  c == fcInf or c == fcNegInf

func isFinite*(x: float64): bool {.inline, raises: [].} =
  ## Finite = neither NaN nor Inf (useful for bounds validation).
  not isNan(x) and not isInf(x)

func toF32*(x: float64): float32 {.inline, raises: [].} =
  ## float64 -> float32 demotion (frozen RNE).
  float32(x)

func toF64*(x: float32): float64 {.inline, raises: [].} =
  ## float32 -> float64 promotion at the computation threshold.
  float64(x)

func nearlyEqual*(a, b: float64, absTol = TOL_NUMERIC_ABS,
                  relTol = TOL_NUMERIC_REL): bool {.raises: [].} =
  ## abs+rel numeric equality. NaN-aware: any NaN input -> false (NaN != NaN,
  ## propagation preserved). Infinities: true only for the same infinity
  ## (`Inf == Inf`, `-Inf == -Inf`); any other pair containing infinity is false.
  if isNan(a) or isNan(b):
    return false
  if isInf(a) or isInf(b):
    return a == b
  let diff = abs(a - b)
  if diff <= absTol:
    return true
  let largest = max(abs(a), abs(b))
  largest > 0.0 and diff <= relTol * largest
