# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# hct — HCT descriptor. Material's color space: H (hue from CAM16), C (chroma
# from CAM16), T (tone = CIELAB L*). Conversion has no closed form and is
# solved iteratively (Newton) to reconcile CAM16 H,C with Lab L*, so round-trip
# holds only to a tolerance — hence non-redeemable. The solver lives in
# `conversion`. D65, achromatic when C ~ 0. View params follow CAM16 (default
# Material viewing conditions, resolved in `conversion`).

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

func hctDescriptor*(): SpaceDescriptor =
  ## HCT (D65, H/C/T). H [0,360), C >= 0, T [0,100]. Non-redeemable (iterative
  ## solver). Achromatic when C ~ 0.
  makeAnalyticDescriptor("hct", tagHct, famHct, ["H", "C", "T"],
                         [0.0, 0.0, 0.0], [360.0, Inf, 100.0],
                         rkNatural, wpD65, false, achPolarChroma)

discard registerSpace(hctDescriptor())
