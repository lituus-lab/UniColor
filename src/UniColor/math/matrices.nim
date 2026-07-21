# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# matrices — Mat3 (3x3 float64): product, transpose, inverse, apply, det.
# Pure float64 (color conversion transits in float64). Mat4 is not implemented:
# alpha is straight and never matrix-transformed, so no consumer (YAGNI).

import UniColor/core/numerics
import UniColor/core/color_error
import UniColor/core/result

type
  Vec3* = array[3, float64]
    ## 3-float64 vector (XYZ, LMS, primaries, whitepoint).
  Mat3* = array[3, array[3, float64]]
    ## 3x3 float64 matrix, indexed `[row][col]` (row-major).

func identity3*(): Mat3 {.inline, raises: [].} =
  ## 3x3 identity.
  [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]

func transpose3*(m: Mat3): Mat3 {.raises: [].} =
  ## Transpose: (m^T)[i][j] = m[j][i].
  for i in 0 ..< 3:
    for j in 0 ..< 3:
      result[i][j] = m[j][i]

func mul3*(a, b: Mat3): Mat3 {.raises: [].} =
  ## Matrix product a·b (row-major). NaN propagated.
  for i in 0 ..< 3:
    for j in 0 ..< 3:
      var s = 0.0
      for k in 0 ..< 3:
        s += a[i][k] * b[k][j]
      result[i][j] = s

func apply3*(m: Mat3, v: Vec3): Vec3 {.raises: [].} =
  ## Matrix·vector product (m·v).
  for i in 0 ..< 3:
    var s = 0.0
    for k in 0 ..< 3:
      s += m[i][k] * v[k]
    result[i] = s

func det3*(m: Mat3): float64 {.raises: [].} =
  ## 3x3 determinant (Sarrus rule). NaN propagated.
  let
    a = m[0][0]
    b = m[0][1]
    c = m[0][2]
    d = m[1][0]
    e = m[1][1]
    f = m[1][2]
    g = m[2][0]
    h = m[2][1]
    i = m[2][2]
  a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)

func inverse3*(m: Mat3): Result[Mat3, ColorError] {.raises: [].} =
  ## 3x3 inverse by cofactors: inv = adj(m) / det(m). Returns
  ## `err(NumericalError)` if the matrix is singular (|det| < TOL_NUMERIC_ABS)
  ## or any entry is non-finite (NaN or ±Inf).
  for i in 0 ..< 3:
    for j in 0 ..< 3:
      if not isFinite(m[i][j]):
        return err[Mat3, ColorError](
          colorError(NumericalError, "inverse3: non-finite entry", "matrices"))
  let d = det3(m)
  if isNan(d) or abs(d) < TOL_NUMERIC_ABS:
    return err[Mat3, ColorError](
      colorError(NumericalError, "inverse3: singular matrix", "matrices"))
  let
    a = m[0][0]
    b = m[0][1]
    c = m[0][2]
    dd = m[1][0]
    e = m[1][1]
    f = m[1][2]
    g = m[2][0]
    h = m[2][1]
    i = m[2][2]
  # Cofactors, then transpose (adjugate) divided by det.
  let invD = 1.0 / d
  result = ok[Mat3, ColorError]([
    [(e * i - f * h) * invD, (c * h - b * i) * invD, (b * f - c * e) * invD],
    [(f * g - dd * i) * invD, (a * i - c * g) * invD, (c * dd - a * f) * invD],
    [(dd * h - e * g) * invD, (b * g - a * h) * invD, (a * e - b * dd) * invD]
  ])
