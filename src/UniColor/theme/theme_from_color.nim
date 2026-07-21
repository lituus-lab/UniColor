# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# theme/theme_from_color — derive a complete UI/editor `Theme` from a single
# brand color. `themeFromColor(base)` builds a FLAT theme of 26 primitive tokens
# whose names ARE the 26 canonical roles consumed by the export formats (union
# of the base16/base24 slot mappings and the IDE role mappings). Flat (no
# semantics/components) so `theme.resolve(role)` returns the primitive directly
# AND so the theme has no extra role names that an info-lost check would flag
# beyond the genuinely unslottable ones.
#
# Determinism: every color derives from `base` via fixed engine primitives
# (neutralScale/goldenAngle/harmonies) or fixed OKLCH literals (status). No RNG,
# no iteration-order dependence (fixed role lists). Same `base` -> byte-
# identical theme.
#
# Status hues are FIXED (not derived from `base`): error/warning/success/info
# must stay recognizable regardless of brand (a red error on a red brand must
# still read as error). This is a documented design choice; the brand-driven
# alternative would produce ambiguous status colors.
import UniColor/core/core
import UniColor/conversion/conversion # `gamutMap`.
import UniColor/palette/direct # goldenAngle, triadic, complement.
import UniColor/palette/tonal # neutralScale, nmTinted.
import UniColor/palette/types
import UniColor/theme/tree

# The 8 neutral roles in DARK->LIGHT order (matches `neutralScale`'s ramp
# direction: index 0 is L=0.20 darkest, index 7 is L=0.95 lightest). Mapping a
# dark->light ramp onto a light UI theme: darkest = text.primary, lightest =
# background.
const neutralRoles = ["text.primary", "text.secondary", "text.muted",
    "text.disabled", "overlay", "surface.variant", "surface", "background"]

# The 10 syntax roles, in `goldenAngle` output order (base hue, then golden-
# angle siblings). Each gets a distinct hue at fixed L/C so syntax categories
# stay separable.
const syntaxRoles = ["syntax.variable", "syntax.constant", "syntax.type",
    "syntax.string", "syntax.operator", "syntax.function", "syntax.keyword",
    "syntax.comment",
    "syntax.number", "syntax.namespace"]

proc statusColor(l, c, h: float32): Result[Color, ColorError] {.raises: [].} =
  ## Fixed-OKLCH status color, gamut-mapped to sRGB for display.
  let r = color(tagOklch, l, c, h)
  if r.isErr: return err[Color, ColorError](r.error)
  gamutMap(r.get, tagSrgb)

proc themeFromColor*(base: Color, dark: bool = false): Result[Theme,
    ColorError] {.raises: [].} =
  ## Derive a complete 26-role theme from `base` (the brand/primary color).
  ## Neutrals from a tinted neutral ramp, syntax accents from a golden-angle
  ## qualitative palette, status from fixed semantic hues, brand from `base` +
  ## its triadic/complement harmonies. `dark` reverses the neutral role mapping
  ## so the dark theme's `background` is the darkest ramp tone (L≈0.20 — a
  ## visibly brand-tinted navy, NOT pure black) and `text.primary` is the
  ## lightest. The symmetric `invert` is NOT used for dark here: the inverse of
  ## a near-white light bg quantizes to sRGB #000001 (pure black — the brand
  ## tint vanishes, and invert's chroma×0.6 collapses the dark neutral ramp to
  ## near-black). The reversed ramp keeps both endpoints in the sRGB-visible
  ## band, so the dark bg reads as a real tinted dark, matching how
  ## Material/Tailwind dark themes are built. Status and brand accents are
  ## mode-independent. Syntax lightness IS mode-aware: the light theme's
  ## surface is near-white (L≈0.86), so mid-L (0.65) syntax reads at only ~2:1
  ## there (below WCAG AA); dark syntax (L=0.40) restores AA-normal on the
  ## light surface, while the dark theme raises light syntax (L=0.72, ~5:1 on
  ## its L≈0.30 surface) so BOTH modes reach AA-normal for normal-size code.
  ## Returns the first engine error (never silent). Deterministic.
  var prims: seq[ThemeToken] = @[]

  # Neutrals (8) — tinted ramp of the base hue, L 0.20->0.95. LIGHT: map
  # dark->light to the role list (text.primary = darkest, background = lightest
  # near-white). DARK: reverse (background = darkest L≈0.20 tinted navy,
  # text.primary = lightest) so the dark bg is not pure black.
  let nR = neutralScale(base, neutralRoles.len, nmTinted, tagSrgb)
  if nR.isErr: return err[Theme, ColorError](nR.error)
  let ncs = nR.get.colors
  for i, role in neutralRoles:
    if i < ncs.len:
      let idx = if dark: neutralRoles.len - 1 - i else: i
      prims.add(ThemeToken(name: role, color: ncs[idx]))

  # Syntax accents (10) — golden-angle around the base hue, fixed C=0.12.
  # Lightness is mode-aware (see proc doc): light themes get dark tokens
  # (L=0.40, AA-normal on the near-white surface), dark themes get light tokens
  # (L=0.72, AA-normal on the L≈0.30 surface).
  let synL = if dark: 0.72 else: 0.40
  let gR = goldenAngle(base, syntaxRoles.len, synL, 0.12)
  if gR.isErr: return err[Theme, ColorError](gR.error)
  let gcs = gR.get.colors
  for i, role in syntaxRoles:
    if i < gcs.len:
      prims.add(ThemeToken(name: role, color: gcs[i]))

  # Status (4) — fixed semantic OKLCH hues (brand-independent, see module doc).
  # Gamut-mapped sRGB.
  let statuses = [("error", 0.60'f32, 0.20'f32, 25.0'f32),
                  ("warning", 0.75'f32, 0.17'f32, 75.0'f32),
                  ("success", 0.62'f32, 0.17'f32, 145.0'f32),
                  ("info", 0.65'f32, 0.15'f32, 250.0'f32)]
  for (role, l, c, h) in statuses:
    let sR = statusColor(l, c, h)
    if sR.isErr: return err[Theme, ColorError](sR.error)
    prims.add(ThemeToken(name: role, color: sR.get))

  # Brand (4) — primary = base (sRGB-gamut-mapped); secondary/tertiary = triadic
  # siblings; accent = complement. Distinct brand accents derived from `base`.
  let primR = gamutMap(base, tagSrgb)
  if primR.isErr: return err[Theme, ColorError](primR.error)
  prims.add(ThemeToken(name: "primary", color: primR.get))
  let triR = triadic(base)
  if triR.isErr: return err[Theme, ColorError](triR.error)
  let tcs = triR.get.colors
  if tcs.len >= 3:
    prims.add(ThemeToken(name: "secondary", color: tcs[1]))
    prims.add(ThemeToken(name: "tertiary", color: tcs[2]))
  let compR = complement(base)
  if compR.isErr: return err[Theme, ColorError](compR.error)
  let ccs = compR.get.colors
  if ccs.len >= 2:
    prims.add(ThemeToken(name: "accent", color: ccs[1]))

  theme(prims, [], [])
