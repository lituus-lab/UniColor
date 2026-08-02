# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# theme — Theme token tree + roles + tonalScale. Umbrella re-exporting the
# submodules so callers reach them via `UniColor/theme/theme`.
import UniColor/theme/tree
import UniColor/theme/roles
import UniColor/theme/inherit
import UniColor/theme/states
import UniColor/theme/invert
import UniColor/theme/tonal_share
import UniColor/theme/golden
import UniColor/theme/theme_from_color

export tree
export roles
export inherit
export states
export invert
export tonal_share
export golden
export theme_from_color

## Immutable 3-layer token tree (primitive -> semantic -> component), resolvable
## by role (exact, with fallback, or with state tone shift), plus the golden
## reference themes (Tailwind, Radix), tonal-share / re-skin tools, deterministic
## invert / variant, and `themeFromColor` (derive a full theme from one brand
## color).
runnableExamples:
  import UniColor/core/core
  let blue = color(tagOklch, 0.65'f32, 0.18'f32, 250.0'f32).get
  let red = color(tagSrgb, 0.80'f32, 0.20'f32, 0.20'f32).get
  let prims = [ThemeToken(name: "primary", color: blue),
               ThemeToken(name: "red", color: red)]
  let sems = [ThemeToken(name: "text/primary", alias: "red")]
  let comps = [ThemeToken(name: "button/bg", alias: "primary")]
  let t = theme(prims, sems, comps).get
  # Component -> semantic -> primitive resolution chain:
  doAssert t.resolve("button/bg").get == blue
  doAssert t.resolve("text/primary").get == red
  doAssert t.hasRole("primary")
  # Golden reference theme (Tailwind v3 primitives):
  doAssert tailwindTheme().get.count > 0

const themeModule* = "1.0.0"
