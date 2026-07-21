# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# to — public conversion API on top of the XYZ hub.
#
# A->B = toXYZ(c) + fromXYZ(xyz, B), composed end-to-end in float64 through the
# hub (single deterministic final rounding to float32). Two entry points share
# one body:
#   - `to(c, targetTag)` resolves the target at runtime via the registry (cold
#     path); UnknownSpace if the target is not registered.
#   - `to[Target](c)` takes a static SpaceTag so each call site monomorphizes and
#     inlines for spaces known at compile time (zero-cost hot path). Call as
#     `to[tagOklch](c)` (method syntax `c.to[tagOklch]` parses as indexing).
# Alpha is preserved: the hub `fromXYZ` defaults alpha to 1.0 (XYZ carries no
# alpha), so `to` reattaches the source color's alpha on the result. Errors from
# the hub (UnknownSpace, InvalidOp, InvalidColor) surface unchanged.

import UniColor/core/color
import UniColor/conversion/hub

# Runtime target: the target tag is resolved against the registry inside
# `fromXYZ`. Returns UnknownSpace for an unregistered target, InvalidOp for a
# wired-source to a not-yet-wired target family (e.g. CMYK).
proc to*(c: Color, target: SpaceTag): Result[Color, ColorError] {.raises: [].} =
  # Exact pairs (Lab<->LCH, OKLab<->OKLCH, sRGB<->sRGB-linear, HSV<->HSL<->HWB)
  # take a direct short-path that bypasses the XYZ hub — exact, no double round.
  if isShortPath(c.spaceTag, target):
    return shortPath(c, target)
  let xyzR = toXYZ(c)
  if xyzR.isErr:
    return err[Color, ColorError](xyzR.error)
  let destR = fromXYZ(xyzR.get, target)
  if destR.isErr:
    return err[Color, ColorError](destR.error)
  let d = destR.get
  # Hub fromXYZ builds the result with alpha=1.0 (XYZ carries no alpha). Reattach
  # the source alpha so conversion is lossless on the alpha channel.
  color(target, d.comp(0), d.comp(1), d.comp(2), c.alpha())

# Static target: `Target` is a compile-time SpaceTag, so each call site
# monomorphizes and inlines — no target-tag dispatch at the call site. The body
# delegates to the runtime `to` (the compiler specializes it for the known
# target).
proc to*[Target: static[SpaceTag]](c: Color): Result[Color,
    ColorError] {.raises: [].} =
  to(c, Target)
