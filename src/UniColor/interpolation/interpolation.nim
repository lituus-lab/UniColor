# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# interpolation — per-space interpolation (CSS Color 4 hue arcs), multi-stop
# gradients, PCHIP/cubic splines, and CSS easing primitives. Default space
# OKLCH; cylindrical LCH-family spaces blend L and C linearly and h along the
# chosen `HueMethod` arc (default `hmShorter`). Umbrella re-exporting the
# submodules.

import UniColor/interpolation/space
import UniColor/interpolation/gradient
import UniColor/interpolation/spline
import UniColor/interpolation/easing
import UniColor/interpolation/batch

export space
export gradient
export spline
export easing
export batch

const interpolationModule* = "0.1.0"
