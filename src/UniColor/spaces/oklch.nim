# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# oklch — OKLCH, the polar form of OKLab: C = sqrt(a*a+b*b), h = atan2(b,a) in
# degrees. h is undefined when C is 0; the conversion module normalizes that to
# 0 by convention. D65 (matches OKLab). L [0,1], C >= 0, h [0,360). Achromatic
# when C ~ 0.

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

func oklchDescriptor*(): SpaceDescriptor =
  ## D65 OKLCH: L/C/h. Achromatic when chroma C is ~0.
  makeAnalyticDescriptor("oklch", tagOklch, famOklch, ["L", "C", "h"],
                         [0.0, 0.0, 0.0], [1.0, Inf, 360.0],
                         rkNatural, wpD65, true, achPolarChroma)

discard registerSpace(oklchDescriptor())
