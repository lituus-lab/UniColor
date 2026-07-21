# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# cam16 — CAM16 & CAM16-UCS descriptors. CAM16 is polar (J/C/h), CAM16-UCS is
# its rectangular uniform form (J'/a'/b') for deltaE_CAM16-UCS. The
# forward/inverse equations (cone response, adaptation gain, J/C/h) live in
# `conversion`. CAM16 depends on viewing conditions (L_A adapting luminance,
# Y_b background, surround average/dim/dark). The built-in descriptors use
# default viewing conditions (resolved when `conversion` implements CAM16 —
# Material HCT convention); custom viewing conditions will be user-registered
# variants. Both D65, redeemable, achromatic via C~0 (CAM16) or a',b'~0 (UCS).

import std/math
import UniColor/core/space_tag
import UniColor/math/whitepoint
import UniColor/spaces/descriptor
import UniColor/spaces/registry

func cam16Descriptor*(): SpaceDescriptor =
  ## CAM16 (D65, J/C/h). J [0,100], C >= 0, h [0,360). Achromatic when C ~ 0.
  makeAnalyticDescriptor("cam16", tagCam16, famCam16, ["J", "C", "h"],
                         [0.0, 0.0, 0.0], [100.0, Inf, 360.0],
                         rkNatural, wpD65, true, achPolarChroma)

func cam16UcsDescriptor*(): SpaceDescriptor =
  ## CAM16-UCS (D65, J'/a'/b'). J' [0,100], a'/b' signed unbounded. Achromatic
  ## when a'=b'=0.
  makeAnalyticDescriptor("cam16-ucs", tagCam16Ucs, famCam16Ucs, ["J'", "a'",
      "b'"], [0.0, NegInf, NegInf], [100.0, Inf, Inf],
                         rkNatural, wpD65, true, achRectAB)

discard registerSpace(cam16Descriptor())
discard registerSpace(cam16UcsDescriptor())
