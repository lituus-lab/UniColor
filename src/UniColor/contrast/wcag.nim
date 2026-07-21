# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# wcag — WCAG 2.2 contrast: relative luminance + ratio [1,21] + thresholds.
#
# `relativeLuminance(c)` converts `c` to sRGB-linear D65 via the conversion hub
# (handles ANY source space: sRGB-encoded, P3, Rec2020, Lab-derived …), then
# applies the W3C coefficients `L = 0.2126·R + 0.7152·G + 0.0722·B` on the
# linear channels. Returns the conversion error (UnknownSpace / InvalidColor)
# if the hub rejects `c`.
# `contrastRatio(fg, bg)` = `(L_lighter + 0.05) / (L_darker + 0.05)`, SYMMETRIC
# in fg/bg (polar symmetry is a documented WCAG 2.x limit — black-on-white ==
# white-on-black == 21:1).
# Thresholds: AA normal 4.5, AA large 3.0, AAA normal 7.0, AAA large 4.5,
# non-text 3.0.
# Out-of-gamut preserved: no clamp before compute — a luminance outside [0,1]
# (e.g. wide-gamut source brighter than sRGB white) propagates and can yield a
# ratio outside [1,21]; the [1,21] bound holds for in-gamut sRGB. float64.
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/conversion/conversion

# W3C relative-luminance coefficients on linearized sRGB.
const WCAG_R* = 0.2126
const WCAG_G* = 0.7152
const WCAG_B* = 0.0722
const OFFSET* = 0.05 # WCAG ratio offset.

# WCAG 2.2 contrast thresholds. Dimensionless ratios (X:1).
const WcagAaNormal* = 4.5
const WcagAaLarge* = 3.0
const WcagAaaNormal* = 7.0
const WcagAaaLarge* = 4.5
const WcagNonText* = 3.0

proc relativeLuminance*(c: Color): Result[float64, ColorError] {.raises: [].} =
  ## WCAG 2.2 relative luminance of `c`. Converts to sRGB-linear D65 via the hub
  ## (so any registered source space is handled), then applies the W3C
  ## coefficients. Out-of-gamut preserved (no clamp). Returns the hub error if
  ## `c`'s space is unregistered / invalid for conversion (e.g. xyY with y=0).
  let linR = c.to(tagSrgbLin)
  if linR.isErr:
    return err[float64, ColorError](linR.error)
  let lin = linR.get
  let l = WCAG_R * lin.comp(0).float64 + WCAG_G * lin.comp(1).float64 +
      WCAG_B * lin.comp(2).float64
  ok[float64, ColorError](l)

proc contrastRatio*(fg, bg: Color): Result[float64, ColorError] {.raises: [].} =
  ## WCAG 2.2 contrast ratio between `fg` and `bg`:
  ## `(L_lighter + 0.05) / (L_darker + 0.05)`, SYMMETRIC in fg/bg. Range [1, 21]
  ## for in-gamut sRGB (white/black = 21:1, identical = 1:1). Propagates a
  ## luminance error from either operand.
  let lfR = relativeLuminance(fg)
  if lfR.isErr:
    return err[float64, ColorError](lfR.error)
  let lbR = relativeLuminance(bg)
  if lbR.isErr:
    return err[float64, ColorError](lbR.error)
  let lf = lfR.get
  let lb = lbR.get
  let hi = if lf > lb: lf else: lb
  let lo = if lf > lb: lb else: lf
  ok[float64, ColorError]((hi + OFFSET) / (lo + OFFSET))
