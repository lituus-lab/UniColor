# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# lch — CIELCH, the polar form of CIELAB: C = sqrt(a*a+b*b), h = atan2(b,a) in
# degrees. h is undefined when C is 0; the conversion module normalizes that to
# 0 by convention. D50 (matches Lab). L [0,100], C >= 0, h [0,360). Achromatic
# when C ~ 0.

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

func lchDescriptor*(): SpaceDescriptor =
  ## D50 CIELCH: L/C/h. Achromatic when chroma C is ~0.
  makeAnalyticDescriptor("lch", tagLch, famLch, ["L", "C", "h"],
                         [0.0, 0.0, 0.0], [100.0, Inf, 360.0],
                         rkNatural, wpD50, true, achPolarChroma)

discard registerSpace(lchDescriptor())
