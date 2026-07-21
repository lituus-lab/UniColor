# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# export/base16 — Base16/Base24 scheme exporters, registered as "base16" (16
# slots) and "base24" (24 slots). Base16/Base24 are DECLARATIVE scheme formats
# (16/24 stylized slots): the exporter projects the theme's token tree into a
# FIXED slot set via a DECLARED role->slot mapping — not a continuous token dump
# like CSS vars/Tailwind.
#   - base00-07 <- neutrals (bg/surfaces/text shades);
#   - base08-0F <- syntax accents (variable/constant/type/string/operator/...
#     keyword/comment);
#   - base24 base10-17 <- status (error/warning/success/info) + brand
#     (primary/secondary/tertiary/accent).
# Colors are sRGB hex — Base16 is an sRGB format (no OKLCH option;
# `opts.legacySrgb` is ignored, always sRGB gamut-mapped via `gamutMap`).
#
# Info loss: a theme with roles BEYOND the 16/24 slots cannot carry them — those
# roles' colors are lost in this format. The non-silent path is
# `exportThemeReported` (returns `ExportReport` with one `warnInfoLost` warning
# summarizing the unslotted roles); `exportTheme` is the string-only convenience
# that discards warnings. A theme that fits the slots (every role is a mapped
# slot role) emits NO warning.
#
# Missing mapped role -> the slot is not emitted (no derivation — derivation is
# YAGNI here). A slot's role that fails to resolve (dangling alias) -> the slot
# is skipped; not an info-loss (the color was never resolvable), so no warning.
#
# Determinism: slots emitted in FIXED base00..base0F/base17 order (independent
# of theme insertion order); gamut-map is deterministic; the header is a
# literal. Same (theme, opts) -> byte-identical output. No RNG, no I/O.
#
# `base16Slots`/`base24ExtraSlots` are public (the (slot, role) projection in
# emit order). The Base16 IMPORTER cannot reference them: the DAG places
# `import` BELOW `export`, so import -> export is forbidden. The importer
# DUPLICATES the inverse slot->role maps in `import/formats_base16.nim`; drift
# is caught by the round-trip test (export -> import -> re-export slot map
# equal). Self-registers via `discard registerExporter(...)`; the facade
# `export/export.nim` imports this module to fire it.
#
# Layer: export (consumer of serialize + registry + palette/unsatisfiable +
# theme).
import std/algorithm
import std/strutils
import std/tables
import UniColor/core/core # Color, tagSrgb.
import UniColor/core/result
import UniColor/core/color_error
import UniColor/conversion/conversion # gamutMap.
import UniColor/theme/tree
import UniColor/palette/unsatisfiable # PaletteWarning / warnInfoLost.
import "UniColor/export/serialize" # hexByte, genHeader, ucExportVersion.
import "UniColor/export/registry"

# The declared role->slot mapping. Order = fixed slot emission order. A slot
# whose role is absent from the theme is skipped (not emitted). These 16 + 8 =
# 24 names are the ONLY theme roles projected; any other theme role is
# info-lost.
const base16Slots*: seq[(string, string)] = @[
  ("base00", "background"), ("base01", "surface"), ("base02",
      "surface.variant"),
  ("base03", "text.muted"), ("base04", "text.disabled"), ("base05",
      "text.primary"),
  ("base06", "text.secondary"), ("base07", "overlay"),
  ("base08", "syntax.variable"), ("base09", "syntax.constant"),
  ("base0A", "syntax.type"), ("base0B", "syntax.string"), ("base0C",
      "syntax.operator"),
  ("base0D", "primary"), ("base0E", "syntax.keyword"), ("base0F",
      "syntax.comment")]

const base24ExtraSlots*: seq[(string, string)] = @[
  ("base10", "error"), ("base11", "warning"), ("base12", "success"),
  ("base13", "info"),
  ("base14", "syntax.function"), ("base15", "secondary"), ("base16",
      "tertiary"),
  ("base17", "accent")]

proc hex6(c: Color): string {.raises: [].} =
  ## A sRGB color -> 6-digit lowercase hex (no `#`), the canonical Base16 YAML
  ## color form. The color is already gamut-mapped into sRGB by the caller;
  ## `hexByte` rounds+clamps each component.
  let (c0, c1, c2) = c.components
  hexByte(c0) & hexByte(c1) & hexByte(c2)

proc allThemeRoles(t: Theme): seq[string] {.raises: [].} =
  ## Every role key across the three layers (primitives + semantics +
  ## components). Used to find roles NOT projected into any slot (info-lost).
  ## Hash-table iteration order is NOT stable, so the result is SORTED for a
  ## deterministic warning message (independent of insertion order).
  var seen: seq[string]
  for k, _ in t.prims.pairs: seen.add(k)
  for k, _ in t.sems.pairs: seen.add(k)
  for k, _ in t.comps.pairs: seen.add(k)
  seen.sort()
  seen

proc slotRolesSet(slots: openArray[(string, string)]): seq[string] {.
    raises: [].} =
  ## The set of mapped role names for a slot table (sorted, for deterministic
  ## lookup).
  result = @[]
  for (_, role) in slots:
    result.add(role)
  result.sort()

proc baseRender(theme: Theme, opts: ExportOpts, formatName: string,
    slots: openArray[(string, string)]): Result[ExportReport,
        ColorError] {.raises: [].} =
  ## Shared render for base16/base24: project `theme` into `slots`, gamut-mapped
  ## to sRGB hex, emit a Base16 scheme YAML. Returns the report (output + one
  ## `warnInfoLost` if any theme role is not slotted). `opts.legacySrgb` is
  ## ignored — Base16 is always sRGB.
  var lines: seq[string]
  # Header as a YAML comment (genHeader returns a bare string; the format wraps
  # it in `# ` here).
  lines.add("# " & genHeader(formatName, SerializeOpts(target: tagSrgb,
      legacySrgb: true)))
  lines.add("scheme: \"UniColor\"")
  lines.add("author: \"UniColor " & ucExportVersion & "\"")
  # Project each slot in fixed order; skip slots whose role is absent or
  # unresolvable.
  for (slotName, roleName) in slots:
    let rR = theme.resolve(roleName)
    if rR.isErr:
      continue # missing/unresolvable role -> slot skipped (no warning).
    let gR = gamutMap(rR.get, tagSrgb)
    if gR.isErr:
      return err[ExportReport, ColorError](gR.error)
    lines.add(slotName & ": \"" & hex6(gR.get) & "\"")
  # Info-lost: theme roles not in the slot mapping. One summary warning
  # (context = format name, message lists the unslotted role names) — non-silent.
  var warnings: seq[PaletteWarning]
  let slotted = slotRolesSet(slots)
  var lost: seq[string]
  for role in allThemeRoles(theme):
    if role notin slotted:
      lost.add(role)
  if lost.len > 0:
    warnings.add(PaletteWarning(code: warnInfoLost,
        message: $(lost.len) & " role(s) not projected into " & formatName &
            " slots (colors lost in this format): " & lost.join(", "),
        context: formatName))
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: warnings))

proc base16Render(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  baseRender(theme, opts, "base16", base16Slots)

proc base24Render(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  baseRender(theme, opts, "base24", base16Slots & base24ExtraSlots)

# Bootstrap — register "base16" and "base24". Fired by
# `import "UniColor/export/base16"`.
discard registerExporter(Exporter(name: "base16", render: base16Render))
discard registerExporter(Exporter(name: "base24", render: base24Render))
