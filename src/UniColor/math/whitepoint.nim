# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# whitepoint — CIE 1931 2° whitepoints + centralized Bradford chromatic
# adaptation. Any (src, dst) pair is supported via the generic Bradford cone-
# response computation (no ad-hoc pair tables). Whitepoints are parameterizable
# by the spaces layer.

import UniColor/math/matrices

type
  Whitepoint* = Vec3
    ## Whitepoint [X, Y, Z] (Y conventionally = 1.0).

# CIE 1931 2° whitepoints (Lindbloom values, frozen).
const
  wpD65* = Whitepoint [0.95047, 1.00000, 1.08883]
  wpD50* = Whitepoint [0.964296, 1.000000, 0.825105]
  wpA* = Whitepoint [1.09850, 1.00000, 0.35585]
  wpC* = Whitepoint [0.98074, 1.00000, 1.18232]

# Bradford cone-response matrix (frozen) and its inverse (Lindbloom).
const
  bradfordM = [[0.8951000, 0.2664000, -0.1614000],
               [-0.7502000, 1.7135000, 0.0367000],
               [0.0389000, -0.0685000, 1.0296000]]
  bradfordMInv = [[0.9869929, -0.1470543, 0.1599627],
                  [0.4323053, 0.5183603, 0.0492922],
                  [-0.0085287, 0.0400428, 0.9684867]]

func bradfordMatrix*(src, dst: Whitepoint): Mat3 {.raises: [].} =
  ## Bradford chromatic adaptation matrix src -> dst:
  ## M = M_A^-1 · diag(rho_dst / rho_src) · M_A, where rho = M_A · wp.
  let rhoSrc = apply3(bradfordM, src)
  let rhoDst = apply3(bradfordM, dst)
  let diag = [[rhoDst[0] / rhoSrc[0], 0.0, 0.0],
              [0.0, rhoDst[1] / rhoSrc[1], 0.0],
              [0.0, 0.0, rhoDst[2] / rhoSrc[2]]]
  mul3(bradfordMInv, mul3(diag, bradfordM))

func adapt*(xyz: Vec3, src, dst: Whitepoint): Vec3 {.inline, raises: [].} =
  ## Bradford chromatic adaptation of an XYZ from `src` to `dst`.
  ## `adapt(wpSrc, src, dst) ≈ wpDst` (property). NaN propagated.
  apply3(bradfordMatrix(src, dst), xyz)
