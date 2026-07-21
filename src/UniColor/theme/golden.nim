# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# golden — reference theme builders from EXTERNAL published palettes (Tailwind
# v3, Radix Colors). These are GOLDEN reference themes: the primitive colors
# are the verbatim published hex values of real systems, NOT values
# manufactured to fit the code. If a resolved role mismatches its published
# hex, this module (the impl) is fixed, not the oracle.
#
# Two systems are shipped because they are FIXED published palettes — a direct
# table lookup reproduces them bit-for-bit. Material 3 is ALGORITHMIC (HCT
# tonal generation + scheme roles, not a fixed table); reproducing it exactly
# is generation territory and is deferred here (documented spec hole, not a
# golden lot).
#
# Role→primitive mapping is the spec hole (the spec does not pin a mapping).
# Each builder pins it using its system's documented conventions:
#   - Tailwind (light): neutrals from the `slate` scale, accent from `blue`,
#     danger from `red`.
#   - Radix (blue, light): steps 1-2 app bg, 4 border, 9 solid (primary),
#     11 low-contrast text, 12 high-contrast text.
#
# Hex values are written as `0xRR, 0xGG, 0xBB` int literals so the published
# truth stays visible in the source (no string parsing, no raise).
# Deterministic.
import UniColor/core/core
import UniColor/theme/tree

# Build a primitive `Color` from sRGB components in the 0-255 range (comps
# stored gamma-encoded in [0,1]). Callers pass the published hex as `0xRR` etc.
proc srgb255(r, g, b: int): Color {.raises: [].} =
  color(tagSrgb, r.float32 / 255.0'f32, g.float32 / 255.0'f32,
      b.float32 / 255.0'f32).get

# Tailwind v3 reference theme (light). Primitives are the published Tailwind
# slate/blue/red hex values. Semantics map UI roles to the slate scale
# (backgrounds, text, border) and blue/red for accent/danger. Components alias
# semantic roles.
proc tailwindTheme*(): Result[Theme, ColorError] {.raises: [].} =
  ## Build the Tailwind v3 reference theme (light). Primitives are the published
  ## Tailwind slate/blue/red hex values; semantics map UI roles; components
  ## alias semantic roles. Deterministic. External truth (golden reference).
  let prims = [
    ThemeToken(name: "slate.50", color: srgb255(0xf8, 0xfa, 0xfc)),
    ThemeToken(name: "slate.100", color: srgb255(0xf1, 0xf5, 0xf9)),
    ThemeToken(name: "slate.200", color: srgb255(0xe2, 0xe8, 0xf0)),
    ThemeToken(name: "slate.500", color: srgb255(0x64, 0x74, 0x8b)),
    ThemeToken(name: "slate.900", color: srgb255(0x0f, 0x17, 0x2a)),
    ThemeToken(name: "blue.500", color: srgb255(0x3b, 0x82, 0xf6)),
    ThemeToken(name: "red.500", color: srgb255(0xef, 0x44, 0x44))
  ]
  let sems = [
    ThemeToken(name: "background", alias: "slate.50"),
    ThemeToken(name: "surface", alias: "slate.100"),
    ThemeToken(name: "border", alias: "slate.200"),
    ThemeToken(name: "text.primary", alias: "slate.900"),
    ThemeToken(name: "text.muted", alias: "slate.500"),
    ThemeToken(name: "primary", alias: "blue.500"),
    ThemeToken(name: "danger", alias: "red.500")
  ]
  let comps = [ThemeToken(name: "button.bg", alias: "primary")]
  theme(prims, sems, comps)

# Radix Colors reference theme (blue, light). Primitives are the published Radix
# blue 12-step hex values; the role mapping follows the Radix convention: 1-2
# app bg, 4 border, 9 solid (primary), 11 low-contrast text, 12 high-contrast
# text.
proc radixTheme*(): Result[Theme, ColorError] {.raises: [].} =
  ## Build the Radix Colors reference theme (blue, light). Primitives are the
  ## published Radix blue 12-step hex values; semantics follow the Radix role
  ## convention (1-2 app bg, 4 border, 9 solid, 11 low-contrast text, 12
  ## high-contrast text). Deterministic. External truth (golden reference).
  let prims = [
    ThemeToken(name: "blue.1", color: srgb255(0xfb, 0xfd, 0xff)),
    ThemeToken(name: "blue.2", color: srgb255(0xf5, 0xfa, 0xff)),
    ThemeToken(name: "blue.4", color: srgb255(0xe1, 0xf0, 0xff)),
    ThemeToken(name: "blue.9", color: srgb255(0x00, 0x91, 0xff)),
    ThemeToken(name: "blue.11", color: srgb255(0x00, 0x6a, 0xdc)),
    ThemeToken(name: "blue.12", color: srgb255(0x00, 0x25, 0x4d))
  ]
  let sems = [
    ThemeToken(name: "background", alias: "blue.1"),
    ThemeToken(name: "surface", alias: "blue.2"),
    ThemeToken(name: "border", alias: "blue.4"),
    ThemeToken(name: "primary", alias: "blue.9"),
    ThemeToken(name: "text.muted", alias: "blue.11"),
    ThemeToken(name: "text.primary", alias: "blue.12")
  ]
  let comps = [ThemeToken(name: "button.bg", alias: "primary")]
  theme(prims, sems, comps)
