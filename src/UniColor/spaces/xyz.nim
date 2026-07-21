# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# xyz — XYZ descriptor (conversion hub). toXYZ = identity (XYZ is the hub).
# Whitepoint D65 (default; D50 via Bradford adaptation in conversion). Range
# natural unbounded (off-spectral-locus values preserved). Redeemable (identity).

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

func xyzDescriptor*(): SpaceDescriptor =
  ## XYZ descriptor (hub, D65, identity, unbounded natural range).
  makeAnalyticDescriptor("xyz", tagXyz, famXyz, ["X", "Y", "Z"],
                         [NegInf, NegInf, NegInf], [Inf, Inf, Inf],
                         rkNatural, wpD65, true)

discard registerSpace(xyzDescriptor())
