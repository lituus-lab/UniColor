# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# hdr — ICtCp & JzAzBz descriptors. Both are HDR perceptual spaces; the
# conversion pipelines (ICtCp: linear-Rec2020 -> LMS -> PQ -> ICtCp matrix;
# JzAzBz: XYZ -> LMS -> Safdar perceptual quantizer -> JzAzBz matrix) live in
# `conversion`. ICtCp carries transferKind=tkPq (PQ BT.2100); JzAzBz uses a
# custom quantizer (not a standard transfer), so tkNone and conversion
# dispatches on famJzazbz. Both D65, redeemable (invertible), achromatic when
# the two chroma channels are ~0. Constants and matrices for the pipelines are
# added when `conversion` implements them.

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

func ictcpDescriptor*(): SpaceDescriptor =
  ## ICtCp (D65, PQ transfer, I/Ct/Cp). I is ~[0,1] but HDR allows >1, so
  ## unbounded above; Ct/Cp signed. Achromatic when Ct=Cp=0.
  makeAnalyticDescriptor("ictcp", tagIctcp, famIctcp, ["I", "Ct", "Cp"],
                         [0.0, NegInf, NegInf], [Inf, Inf, Inf],
                         rkNatural, wpD65, true, achRectAB, tkPq)

func jzazbzDescriptor*(): SpaceDescriptor =
  ## JzAzBz (D65, Jz/Az/Bz, Safdar 2017). Jz ~[0,1] + HDR unbounded; Az/Bz
  ## signed. Achromatic when Az=Bz=0. Signed cbrt in the pipeline preserves
  ## out-of-gamut negatives.
  makeAnalyticDescriptor("jzazbz", tagJzazbz, famJzazbz, ["Jz", "Az", "Bz"],
                         [0.0, NegInf, NegInf], [Inf, Inf, Inf],
                         rkNatural, wpD65, true, achRectAB)

discard registerSpace(ictcpDescriptor())
discard registerSpace(jzazbzDescriptor())
