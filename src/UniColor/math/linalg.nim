# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# linalg — dot, norm, normalize, deterministic lerp. Vec3 shared from matrices.

import std/math
import UniColor/core/numerics
import UniColor/math/matrices

func dot*(a, b: Vec3): float64 {.inline, raises: [].} =
  ## Dot product a·b.
  a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

func norm*(v: Vec3): float64 {.inline, raises: [].} =
  ## Euclidean norm ‖v‖.
  sqrt(dot(v, v))

func normalize*(v: Vec3): Vec3 {.raises: [].} =
  ## Unit vector v/‖v‖. A near-zero norm returns v unchanged (zero stays zero,
  ## no NaN or div-by-zero). NaN propagated.
  let n = norm(v)
  if isNan(n) or n < TOL_NUMERIC_ABS:
    return v
  let inv = 1.0 / n
  [v[0] * inv, v[1] * inv, v[2] * inv]

func lerp*(a, b, t: float64): float64 {.inline, raises: [].} =
  ## Deterministic linear interpolation: a + (b - a) * t. t=0 -> a, t=1 -> b.
  ## Endpoints returned directly so an inf/NaN a or b survives at the bounds
  ## (otherwise (b - a) * 0 = NaN would mask it).
  if t == 0.0:
    return a
  if t == 1.0:
    return b
  a + (b - a) * t
