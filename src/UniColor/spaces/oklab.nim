# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# oklab — OKLab (Ottosson) descriptor. The conversion pipeline (linear-sRGB ->
# LMS -> signed cube root -> OKLab) lives in `conversion`; this module only
# holds the two fixed Ottosson matrices as data and registers the descriptor.
# Anchored at D65 (linear-sRGB). The cube root must be signed so negative
# out-of-gamut LMS values are preserved. L in [0,1], a/b unbounded. Achromatic
# when a and b are both ~0.

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

# linear-sRGB -> LMS (Ottosson).
const oklabLms* = [[0.4122214708, 0.5363325363, 0.0514459929],
                   [0.2119034982, 0.6806995451, 0.1073969566],
                   [0.0883024610, 0.2817188376, 0.6299787005]]

# (l', m', s') -> (L, a, b) (Ottosson).
const oklabM* = [[0.2104542553, 0.7936177860, -0.0040720468],
                 [1.9779984951, -2.4285922050, 0.4505937099],
                 [0.0259040371, 0.7827717662, -0.8086757660]]

func oklabDescriptor*(): SpaceDescriptor =
  ## D65 OKLab: L [0,1], a/b unbounded. Achromatic when a and b are both ~0.
  makeAnalyticDescriptor("oklab", tagOklab, famOklab, ["L", "a", "b"],
                         [0.0, NegInf, NegInf], [1.0, Inf, Inf],
                         rkNatural, wpD65, true, achRectAB)

discard registerSpace(oklabDescriptor())
