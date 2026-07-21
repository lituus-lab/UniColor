# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# cmyk — CMYK descriptor. 4 chromatic channels (C,M,Y,K) in [0,1]. Derived from
# RGB via simple subtractive model (R=(1-C)(1-K), ...); ICC profiles substitute
# a LUT at conversion time. Non-redeemable: RGB->CMYK->RGB loses information
# (K subtraction, profile), so no round-trip invariant. Achromaticity
# (C=M=Y=0, any K) is not a simple channel test, so no predicate here. Note:
# Color holds 3 chromatic channels, so CMYK values live in a future ColorX
# type; the descriptor is still registered as data.

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

func cmykDescriptor*(): SpaceDescriptor =
  ## CMYK (D65, C/M/Y/K in [0,1], non-redeemable, no achromatic predicate).
  makeAnalyticDescriptor("cmyk", tagCmyk, famCmyk, ["C", "M", "Y", "K"],
                         [0.0, 0.0, 0.0, 0.0], [1.0, 1.0, 1.0, 1.0],
                         rkStrict, wpD65, false, achNone)

discard registerSpace(cmykDescriptor())
