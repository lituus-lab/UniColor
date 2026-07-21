# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# export/css — CSS-vars exporter, registered as "css". Emits
# `:root { --role: <color>; ... }` from the theme's resolved tokens, gamut-mapped
# at export by the serialize layer: OKLCH default (CSS Color 4 `oklch(L C h)`),
# or sRGB legacy (`#rrggbb` hex) when `opts.legacySrgb`. `opts.prefix` sets the
# var prefix (default `--`). `opts.dark` emits a
# `@media (prefers-color-scheme: dark)` block.
#
# Determinism: the serialize layer orders tokens deterministically
# (layer-grouped + sorted) and gamut-maps them; the header is a literal. Same
# (theme, opts) -> byte-identical output. No RNG, no I/O.
#
# Self-registers via a module-level `discard registerExporter(...)` side effect;
# the facade `export/export.nim` imports this module to fire it.
#
# Layer: export (consumer of serialize + registry + theme).
import std/strutils
import std/options
import UniColor/core/core # Color, SpaceTag, tagSrgb, tagOklch.
import UniColor/core/result
import UniColor/core/color_error
import UniColor/theme/tree
import "UniColor/export/serialize"
import "UniColor/export/registry"

proc cssBlock(t: Theme, opts: ExportOpts): Result[string,
    ColorError] {.raises: [].} =
  ## One `:root { ... }` block for `t`, gamut-mapped into the target space and
  ## rendered as CSS vars. Returns the block text (no header) or the underlying
  ## serialize error.
  let target = if opts.legacySrgb: tagSrgb else: tagOklch
  let sopts = SerializeOpts(target: target, legacySrgb: opts.legacySrgb)
  let sR = serializeTheme(t, sopts)
  if sR.isErr:
    return err[string, ColorError](sR.error)
  let s = sR.get
  var lines: seq[string]
  lines.add(":root {")
  for rc in s:
    lines.add("  " & opts.prefix & rc.role & ": " & formatColorCss(rc.color,
        opts.legacySrgb) & ";")
  lines.add("}")
  ok[string, ColorError](lines.join("\n"))

proc cssRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  ## Registered render: header + light `:root` block + optional
  ## `@media (prefers-color-scheme: dark)` block. CSS vars is a LOSSLESS
  ## projection (every resolved token is emitted), so `warnings` is empty here
  ## — `warnInfoLost` only arises from lossy formats (Base16/terminal).
  let sopts = SerializeOpts(target: if opts.legacySrgb: tagSrgb else: tagOklch,
      legacySrgb: opts.legacySrgb)
  var outParts: seq[string]
  outParts.add("/* " & genHeader("css", sopts) & " */")
  let lightR = cssBlock(theme, opts)
  if lightR.isErr:
    return err[ExportReport, ColorError](lightR.error)
  outParts.add(lightR.get)
  if opts.dark.isSome:
    let darkR = cssBlock(opts.dark.get, opts)
    if darkR.isErr:
      return err[ExportReport, ColorError](darkR.error)
    outParts.add("@media (prefers-color-scheme: dark) {\n" & darkR.get & "\n}")
  ok[ExportReport, ColorError](ExportReport(output: outParts.join("\n"),
      warnings: @[]))

# Bootstrap — register "css". Fired by `import "UniColor/export/css"`.
discard registerExporter(Exporter(name: "css", render: cssRender))
