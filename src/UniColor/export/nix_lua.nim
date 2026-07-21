# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# export/nix_lua — programming-language theme exporters, registered as "nix"
# (Nix expression — NixOS/Home-Manager attrset) and "lua" (Lua table —
# Neovim/awesome/Hammerspoon config). Each is a LOSSLESS token-tree dump: every
# resolved theme role is emitted (serializeTheme ordered
# primitive->semantic->component, sorted within layer), gamut-mapped into the
# export target space and rendered via the shared `formatColorCss` (OKLCH
# default `oklch(L C h)` / sRGB legacy `#rrggbb`). No `warnInfoLost` — Nix/Lua
# project the FULL tree (every role), like CSS-vars/Tailwind. `warnings` is
# always `@[]`.
#
# Dotted role names (e.g. `text.primary`) need QUOTING in both languages — a Nix
# attrset key and a Lua table key can't contain a bare `.`:
#   - Nix : `"text.primary" = "<color>";` (quoted string key).
#   - Lua : `["text.primary"] = "<color>",` (bracket-quoted string key).
# Bare keys (no dot) are emitted quoted too, for a uniform single rule (simpler
# than per-key quoting logic — every key is a string, deterministic).
#
# Determinism: the serialize layer orders tokens deterministically (layer-grouped
# + sorted, independent of hash-table insertion order) and gamut-maps them; the
# header is a literal. Same (theme, opts) -> byte-identical output. No RNG, no
# I/O.
#
# Self-registers via `discard registerExporter(...)`; the facade
# `export/export.nim` imports this module to fire it.
#
# Layer: export (consumer of serialize + registry + theme).
import std/strutils
import UniColor/core/core # Color, SpaceTag, tagSrgb, tagOklch.
import UniColor/core/result
import UniColor/core/color_error
import UniColor/theme/tree
import "UniColor/export/serialize"
import "UniColor/export/registry"

# Nix — attrset. Header as a `#` line comment; each role `"key" = "<color>";`
# (quoted string key, `=` assignment, the color as a quoted string value, `;`
# terminator). Lossless: every role from serializeTheme is emitted.
proc nixRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let target = if opts.legacySrgb: tagSrgb else: tagOklch
  let sopts = SerializeOpts(target: target, legacySrgb: opts.legacySrgb)
  let sR = serializeTheme(theme, sopts)
  if sR.isErr:
    return err[ExportReport, ColorError](sR.error)
  let s = sR.get
  var lines: seq[string]
  lines.add("# " & genHeader("nix", sopts)) # Nix line comment.
  lines.add("{")
  for rc in s:
    lines.add("  \"" & rc.role & "\" = \"" & formatColorCss(rc.color,
        opts.legacySrgb) & "\";")
  lines.add("}")
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: @[]))

# Lua — table. Header as a `--` line comment; `return { ... }` with each role
# `["key"] = "<color>",` (bracket-quoted string key, `=` assignment, the color
# as a quoted string value, `,` separator). Lossless: every role emitted.
proc luaRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let target = if opts.legacySrgb: tagSrgb else: tagOklch
  let sopts = SerializeOpts(target: target, legacySrgb: opts.legacySrgb)
  let sR = serializeTheme(theme, sopts)
  if sR.isErr:
    return err[ExportReport, ColorError](sR.error)
  let s = sR.get
  var lines: seq[string]
  lines.add("-- " & genHeader("lua", sopts)) # Lua line comment.
  lines.add("return {")
  for rc in s:
    lines.add("  [\"" & rc.role & "\"] = \"" & formatColorCss(rc.color,
        opts.legacySrgb) & "\",")
  lines.add("}")
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: @[]))

# Bootstrap — register "nix" and "lua". Fired by
# `import "UniColor/export/nix_lua"`.
discard registerExporter(Exporter(name: "nix", render: nixRender))
discard registerExporter(Exporter(name: "lua", render: luaRender))
