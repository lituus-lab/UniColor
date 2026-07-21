# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# linear — linear sRGB descriptor. Same primaries as sRGB (identical matrix),
# but no transfer (tkNone) and unbounded natural range. Whitepoint D65,
# redeemable. Usage: luminous interpolation, compositing (before gamma
# re-encoding).

import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry
import UniColor/spaces/srgb # shares the primaries matrix

func srgbLinearDescriptor*(): SpaceDescriptor =
  ## Linear-sRGB descriptor (no transfer, natural range, sRGB primaries).
  makeRgbDescriptor("srgb-linear", tagSrgbLin, famRgbLinear, wpD65, tkNone, 0.0,
                    srgbDescriptor().toXYZ, true)

discard registerSpace(srgbLinearDescriptor())
