# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# contrast — perceptual distance metrics (ΔE76/94/2000/CMC/OK/ITP/Jz/CAM16-UCS)
# and contrast metrics (WCAG 2.2 ratio, APCA, BridgePCA), behind a dispatched
# registry. Direct metrics read the operands in their reference space; the
# `distance` / `contrast` dispatchers convert through the hub.

import UniColor/contrast/deltae
import UniColor/contrast/cmc
import UniColor/contrast/ok
import UniColor/contrast/hdr
import UniColor/contrast/cam16ucs
import UniColor/contrast/wcag
import UniColor/contrast/apca
import UniColor/contrast/bridgepca
import UniColor/contrast/registry
import UniColor/contrast/batch

export deltae
export cmc
export ok
export hdr
export cam16ucs
export wcag
export apca
export bridgepca
export registry
export batch

runnableExamples:
  import UniColor/core/core
  # ΔE_OK reads comps as OKLab directly — build the colors in OKLab:
  let a = color(tagOklab, 0.50'f32, 0.10'f32, 0.05'f32).get
  let b = color(tagOklab, 0.50'f32, -0.10'f32, -0.05'f32).get
  doAssert deltaE_ok(a, b) > 0.0
  # The dispatched API converts through the hub (any source space):
  doAssert distance(a, b, "deltaE_ok").get > 0.0
  # WCAG 2.2 contrast ratio (1..21, symmetric in fg/bg):
  let red = color(tagSrgb, 0.80'f32, 0.20'f32, 0.20'f32).get
  let white = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
  doAssert contrastRatio(red, white).get > 1.0

const contrastModule* = "0.1.0"
