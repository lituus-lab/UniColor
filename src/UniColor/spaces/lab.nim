# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# lab — CIELAB (CIE 1976) descriptor. Whitepoint D50 per CIE convention; the
# conversion module adapts D65<->D50 via Bradford. L* is bounded [0,100],
# a*/b* are unbounded so out-of-gamut values survive. The analytic transform
# (epsilon 6/29) lives in `conversion`, not here — this module only registers
# the descriptor.

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

func labDescriptor*(): SpaceDescriptor =
  ## D50 CIELAB: L [0,100], a/b unbounded. Achromatic when a and b are both ~0.
  makeAnalyticDescriptor("lab", tagLab, famLab, ["L", "a", "b"],
                         [0.0, NegInf, NegInf], [100.0, Inf, Inf],
                         rkNatural, wpD50, true, achRectAB)

discard registerSpace(labDescriptor())
