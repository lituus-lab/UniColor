# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# xyy — xyY descriptor (chromaticity + luminance). Analytical conversion
# (x=X/(X+Y+Z), y=Y/(X+Y+Z), Y=Y) handled in `conversion` (dispatch on famXyy).
# No primaries matrix. Natural range: x,y canonical [0,1], Y [0,+Inf] (HDR).
# Whitepoint D65, redeemable.

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

func xyyDescriptor*(): SpaceDescriptor =
  ## xyY descriptor (chromaticity x,y + luminance Y, D65).
  makeAnalyticDescriptor("xyy", tagXyy, famXyy, ["x", "y", "Y"],
                         [0.0, 0.0, 0.0], [1.0, 1.0, Inf],
                         rkNatural, wpD65, true)

discard registerSpace(xyyDescriptor())
