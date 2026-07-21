# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# hsv_hsl_hwb — HSV, HSL, HWB descriptors. Cylindrical forms derived from an
# encoded RGB parent (sRGB by default); the conversion module dispatches on
# family to do HSV/HSL/HWB <-> sRGB. They carry no primaries matrix
# (toXYZ/fromXYZ stay identity). H is angular [0,360), the other channels are
# [0,1]. Achromatic: HSV/HSL are neutral when saturation ~0 (component 1), so
# achPolarChroma; HWB neutrality depends on W+B (normalized in conversion), so
# it has no predicate here.

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

func hsvDescriptor*(): SpaceDescriptor =
  ## HSV: H [0,360), S [0,1], V [0,1]. Achromatic when S ~ 0.
  makeAnalyticDescriptor("hsv", tagHsv, famHsv, ["H", "S", "V"],
                         [0.0, 0.0, 0.0], [360.0, 1.0, 1.0],
                         rkStrict, wpD65, true, achPolarChroma)

func hslDescriptor*(): SpaceDescriptor =
  ## HSL: H [0,360), S [0,1], L [0,1] (HSL lightness, not L* or OKL). Achromatic
  ## when S ~ 0.
  makeAnalyticDescriptor("hsl", tagHsl, famHsl, ["H", "S", "L"],
                         [0.0, 0.0, 0.0], [360.0, 1.0, 1.0],
                         rkStrict, wpD65, true, achPolarChroma)

func hwbDescriptor*(): SpaceDescriptor =
  ## HWB: H [0,360), W [0,1] (whiteness), B [0,1] (blackness). W+B>1 is
  ## normalized by conversion (CSS Color 4); achromaticity is not a simple
  ## channel test, so no predicate.
  makeAnalyticDescriptor("hwb", tagHwb, famHwb, ["H", "W", "B"],
                         [0.0, 0.0, 0.0], [360.0, 1.0, 1.0],
                         rkStrict, wpD65, true, achNone)

discard registerSpace(hsvDescriptor())
discard registerSpace(hslDescriptor())
discard registerSpace(hwbDescriptor())
