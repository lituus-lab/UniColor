# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# conversion — XYZ hub, public `to` API, shortest-path, gamut map, clamp, batch.
# toXYZ/fromXYZ hub lives in `hub`; `to.nim` is the public A->B API on top of it.
# This umbrella re-exports the submodules so callers reach them via `conversion`.

import UniColor/conversion/hub
import UniColor/conversion/to
import UniColor/conversion/gamut
import UniColor/conversion/clamp
import UniColor/conversion/batch

export hub
export to
export gamut
export clamp
export batch

const conversionModule* = "1.0.0"
