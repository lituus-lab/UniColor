# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# core — Color, ColorError, numerics, result, space_tag, parse_color, batch, simd.
#   numerics    — frozen tolerances, targeted clamp, signed cbrt, NaN/Inf, f32<->f64.
#   color_error — ColorError (context) + ColorErrorKind (SemVer-stable, UcError mirror).
#   result      — minimal Result[T, E] (predictable failures).
#   space_tag   — SpaceTag distinct int32 + ABI-stable built-in tags + user ids.
#   color       — immutable Color value type, tagged by space.
#   parse_color — CSS Color 4 string -> Color parser.
#   batch       — BatchOpts (vector/batch APIs surface).
#   simd        — portable SIMD128 lane abstraction.
import UniColor/core/numerics
import UniColor/core/color_error
import UniColor/core/result
import UniColor/core/space_tag
import UniColor/core/color
import UniColor/core/parse_color
import UniColor/core/batch
import UniColor/core/simd
import UniColor/core/schema
export numerics
export color_error
export result
export space_tag
export color
export parse_color
export batch
export simd
export schema

## `Color` construction, parsing, and field access.
runnableExamples:
  let red = color(tagSrgb, 0.80'f32, 0.20'f32, 0.20'f32).get
  doAssert red.spaceTag == tagSrgb
  doAssert red.comp(0) == 0.80'f32
  let (c0, c1, c2) = red.components
  doAssert c2 == 0.20'f32
  doAssert red.isOpaque
  let parsed = parseColor("oklch(0.65 0.18 250)").get
  doAssert parsed.spaceTag == tagOklch
  # Out-of-gamut components are preserved (no clamp):
  let wide = color(tagSrgb, 1.5'f32, 0.0'f32, 0.0'f32).get
  doAssert wide.comp(0) == 1.5'f32

const coreModule* = "0.1.0"
