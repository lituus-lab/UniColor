# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# ycbcr — YCbCr descriptor. Y [0,1] (luma), Cb/Cr [-0.5,0.5] (full-range
# canonical). Default standard is BT.709 (HD); BT.601 and BT.2020 are matrix
# variants the conversion module selects. Redeemable for full-range (the 3x3
# luma/chroma matrix is invertible); limited-range + 4:2:0 subsampling (image
# layer) breaks round-trip and is documented as lossy. Achromatic when Cb=Cr=0
# (neutral luma).

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

func ycbcrDescriptor*(): SpaceDescriptor =
  ## YCbCr (D65, Y/Cb/Cr, full-range BT.709 default, redeemable, achromatic if
  ## Cb=Cr=0).
  makeAnalyticDescriptor("ycbcr", tagYcbcr, famYcbcr, ["Y", "Cb", "Cr"],
                         [0.0, -0.5, -0.5], [1.0, 0.5, 0.5],
                         rkStrict, wpD65, true, achRectAB)

discard registerSpace(ycbcrDescriptor())
