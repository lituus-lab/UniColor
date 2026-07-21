# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# srgb — sRGB descriptor (IEC 61966-2-1). D65 primaries matrix (Lindbloom /
# IEC standard values, frozen). 2.4 piecewise transfer (ref tkSrgb ->
# math/transfer). Encoded [0,1] strict, whitepoint D65, redeemable.
# Registration at load time.

import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

# Linear sRGB -> XYZ matrix (D65, Lindbloom / IEC 61966-2-1, frozen).
const srgbToXyz = [[0.4124564, 0.3575761, 0.1804375],
                   [0.2126729, 0.7151522, 0.0721750],
                   [0.0193339, 0.1191920, 0.9503041]]

func srgbDescriptor*(): SpaceDescriptor =
  ## sRGB descriptor (encoded, 2.4 transfer, D65).
  makeRgbDescriptor("srgb", tagSrgb, famRgbEncoded, wpD65, tkSrgb, 0.0,
      srgbToXyz, true)

# Registration at module load time (import side effect).
discard registerSpace(srgbDescriptor())
