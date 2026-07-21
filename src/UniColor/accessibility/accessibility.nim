# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# accessibility — a11y metrics registry + CVD. Umbrella re-exporting the
# submodules so callers reach them via `UniColor/accessibility/accessibility`.
import UniColor/accessibility/metrics
import UniColor/accessibility/cvd
import UniColor/accessibility/correction
import UniColor/accessibility/safe
import UniColor/accessibility/dynamic
import UniColor/accessibility/constraint

export metrics
export cvd
export correction
export safe
export dynamic
export constraint

## Accessibility layer: WCAG role / APCA size contrast verdicts, CVD simulation
## (Machado 2009) + confusability audit, the CVD-safe reference palette registry
## (okabeIto / viridis / colorBrewerSet1) with verifiable safety, explicit
## OKLCH correction primitives, and dynamic `adjustForContrast` (minimal OKLCH
## lightness shift to pass a contrast threshold). Best-effort, never silent.
runnableExamples:
  import UniColor/core/core
  import UniColor/palette/palette
  # CVD-safe reference palette (8 colors, Okabe-Ito):
  let pal = safePalette("okabeIto", 8).get
  doAssert pal.len == 8
  # Pairwise confusability audit under 3 dichromacies (ΔE_OK >= JND):
  let cols = pal.colors
  doAssert isCvdSafe(cols)
  # Dynamic contrast: lift a dark fg's OKLCH lightness until WCAG AA passes on
  # white bg:
  let dark = color(tagSrgb, 0.10'f32, 0.10'f32, 0.10'f32).get
  let white = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
  let adj = adjustForContrast(dark, white, 4.5).get
  doAssert adj.met

const accessibilityModule* = "0.1.0"
