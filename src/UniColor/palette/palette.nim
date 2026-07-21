# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# palette — Palette value type + generation registry. Umbrella re-exporting the
# submodules so callers reach them via `UniColor/palette/palette`.
import UniColor/palette/types
import UniColor/palette/direct
import UniColor/palette/optim
import UniColor/palette/kmeans
import UniColor/palette/constraints
import UniColor/palette/unsatisfiable
import UniColor/palette/tonal
import UniColor/palette/safe

export types
export direct
export optim
export kmeans
export constraints
export unsatisfiable
export tonal
export safe

## Immutable `Palette` value type tagged by structure, plus deterministic
## generators (golden angle, harmonies, k-means, simulated annealing, genetic)
## and the safe-palette references (okabeIto / viridis / colorBrewer). `seed` is
## the sole source of randomness; `seed = 0` is canonical for the generators.
runnableExamples:
  import UniColor/core/core
  let red = color(tagSrgb, 0.80'f32, 0.20'f32, 0.20'f32).get
  let blue = color(tagOklch, 0.65'f32, 0.18'f32, 250.0'f32).get
  let pal = palette(palUnordered, [red, blue], intentQualitative, 0'i64).get
  doAssert pal.len == 2
  doAssert pal.tag == palUnordered
  # Golden-angle qualitative palette (seed-independent, exact hues in OKLCH):
  let g = goldenAngle(blue, 5, 0.65, 0.16).get
  doAssert g.len == 5
  # Two-color complementary harmony (base + h±180°):
  doAssert complement(blue).get.len == 2
  # CVD-safe reference palette (8 colors, Okabe-Ito) — embedded in palette/safe:
  doAssert okabeIto().len == 8

const paletteModule* = "0.1.0"
