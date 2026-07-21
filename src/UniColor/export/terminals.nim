# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# export/terminals — terminal-config theme exporters, registered as "alacritty",
# "kitty", "wezterm", "ghostty", "windowsterminal", "foot", "warp", "xresources".
# Each projects the theme's roles into the terminal's ANSI 16-color palette
# vocabulary (black/red/green/yellow/blue/magenta/cyan/white + brights +
# bg/fg/cursor/selection) via a DECLARED role->ANSI-slot mapping, truecolor sRGB
# hex (gamut-mapped: L/h preserved, C reduced to land in gamut).
#
# Terminals are SLOT-BOUNDED (the ANSI 16-color palette is a FIXED slot set, NOT
# extensible like IDE highlight groups — contrast the IDE exporter which is
# lossless). A theme role BEYOND the mapped ANSI slots cannot be carried ->
# `warnInfoLost`. One summary warning (context = format name, message lists the
# unslotted role names), surfaced via the non-silent `exportThemeReported` path;
# `exportTheme` is the string-only convenience that discards warnings. A
# missing/unresolvable mapped role -> its slot is OMITTED (no warning — the color
# was never resolvable, not info loss).
#
# Bright variants REUSE the base role when no brighter variant exists in the
# role vocabulary (documented heuristic — e.g. bright_red = error = red). Warp
# projects FEWER roles (accent/background/foreground only — classic Warp custom
# theme) -> loses MORE on a full theme (documented; the ANSI accents it doesn't
# project are info-lost).
#
# Determinism: slots emitted in fixed ANSI order (0..15), gamut-map is
# deterministic, the header is a literal. Same (theme, opts) -> byte-identical
# output. No RNG, no I/O.
#
# Self-registers via `discard registerExporter(...)`; the facade
# `export/export.nim` imports this module to fire it.
#
# NOTE: `allThemeRoles` + the `lostRoles` helper duplicate ~15 lines from
# base16.nim (kept private there). The duplication is intentional — extracting
# to a shared module would touch base16 (surgical-change principle: don't
# refactor unrelated code for a new sibling module). The projection logic is the
# same shape but the slot vocabulary differs (ANSI vs Base16 slots).
#
# Layer: export (consumer of serialize + registry + conversion +
# palette/unsatisfiable + theme).
import std/algorithm
import std/options
import std/strutils
import std/tables
import UniColor/core/core # Color, tagSrgb.
import UniColor/core/result
import UniColor/core/color_error
import UniColor/conversion/conversion # gamutMap.
import UniColor/theme/tree
import UniColor/palette/unsatisfiable # PaletteWarning / warnInfoLost.
import "UniColor/export/serialize" # hexByte, genHeader.
import "UniColor/export/registry"

# The declared role->ANSI-slot mapping. Index = ANSI color number (0..15).
# Bright variants (8..15) reuse the base role — except blue: regular blue (4) is
# `primary` (the brand anchor, e.g. #0080ff) so the central color IS the blue,
# and bright blue (12) is `info` (a lighter shade) to keep a brighter variant
# available.
const termAnsiRoles: seq[(int, string)] = @[
  (0, "background"), (1, "error"), (2, "success"), (3, "warning"),
  (4, "primary"), (5, "secondary"), (6, "tertiary"), (7, "text.secondary"),
  (8, "surface"), (9, "error"), (10, "success"), (11, "warning"),
  (12, "info"), (13, "secondary"), (14, "tertiary"), (15, "text.primary")]

# Auxiliary (non-ANSI) slots: bg/fg/cursor/selection background. Mapped to roles.
const termAuxRoles: seq[(string, string)] = @[
  ("background", "background"), ("foreground", "text.primary"),
  ("cursor", "text.primary"), ("selection", "surface.variant")]

# The full set of roles projected by the ANSI-bounded formats (the 7 formats
# that emit the 16-color palette; Warp is separate — it projects fewer). Used
# for info-lost detection. Sorted + deduped for deterministic `notin` and message
# order.
const fullTermProjected: seq[string] =
  @["background", "error", "info", "primary", "secondary", "success", "surface",
    "surface.variant", "tertiary", "text.primary", "text.secondary", "warning"]

# Warp projects only these 3 roles (classic Warp custom theme:
# accent/background/foreground).
const warpProjected: seq[string] =
  @["accent", "background", "text.primary"]

proc hex6(c: Color): string {.raises: [].} =
  ## sRGB color -> 6-digit lowercase hex (no `#`). The color is already
  ## gamut-mapped into sRGB by the caller; `hexByte` rounds+clamps each
  ## component. Reuses serialize.hexByte (DRY).
  let (c0, c1, c2) = c.components
  hexByte(c0) & hexByte(c1) & hexByte(c2)

proc allThemeRoles(t: Theme): seq[string] {.raises: [].} =
  ## Every role key across the three layers (primitives + semantics +
  ## components), SORTED for a deterministic warning message. (Duplicated from
  ## base16 — see module note.)
  var seen: seq[string]
  for k, _ in t.prims.pairs: seen.add(k)
  for k, _ in t.sems.pairs: seen.add(k)
  for k, _ in t.comps.pairs: seen.add(k)
  seen.sort()
  seen

proc lostRoles(theme: Theme, projected: openArray[string]): seq[string] {.
    raises: [].} =
  ## Theme roles NOT in the projected slot set (info-lost), in sorted
  ## `allThemeRoles` order.
  result = @[]
  for role in allThemeRoles(theme):
    if role notin projected: result.add(role)

proc termInfoLostWarning(formatName: string,
    lost: openArray[string]): Option[PaletteWarning] {.raises: [].} =
  ## One summary `warnInfoLost` if any role is lost (non-silent). `none`
  ## otherwise.
  if lost.len > 0:
    some(PaletteWarning(code: warnInfoLost,
        message: $(lost.len) & " role(s) not projected into " & formatName &
            " slots (colors lost in this format): " & lost.join(", "),
        context: formatName))
  else:
    none(PaletteWarning)

type TermPalette = object
  ## Resolved terminal palette: 16 ANSI colors + 4 aux (bg/fg/cursor/selection)
  ## as 6-hex (no `#`). Empty string = slot absent (role missing/unresolvable) ->
  ## the caller omits it.
  ansi: array[16, string]
  bg, fg, cursor, selection: string

proc resolveTermPalette(theme: Theme): TermPalette {.raises: [].} =
  ## Resolve every mapped role to sRGB 6-hex once (gamut-mapped).
  ## Absent/unresolvable/gamutMap-fail -> empty string (slot omitted). gamutMap
  ## to sRGB essentially never fails for resolvable colors; a failure is treated
  ## as absent (skip), not an error — documented, no crash.
  for (idx, role) in termAnsiRoles:
    let rR = theme.resolve(role)
    if rR.isOk:
      let gR = gamutMap(rR.get, tagSrgb)
      if gR.isOk: result.ansi[idx] = hex6(gR.get)
  for (slot, role) in termAuxRoles:
    let rR = theme.resolve(role)
    if rR.isOk:
      let gR = gamutMap(rR.get, tagSrgb)
      if gR.isOk:
        case slot
        of "background": result.bg = hex6(gR.get)
        of "foreground": result.fg = hex6(gR.get)
        of "cursor": result.cursor = hex6(gR.get)
        of "selection": result.selection = hex6(gR.get)
        else: discard

proc hasHex(s: string): bool = s.len > 0

proc withHash(hex: string): string = "#" & hex # prefix `#` (formats that quote it)

proc report(outStr: string, warning: Option[PaletteWarning]): Result[
    ExportReport, ColorError] {.raises: [].} =
  ## Build the ExportReport from the output string + optional info-lost warning.
  var ws: seq[PaletteWarning]
  if warning.isSome: ws.add(warning.get)
  ok[ExportReport, ColorError](ExportReport(output: outStr, warnings: ws))

# --- Alacritty — YAML colors --------------------------------------------
proc alacrittyRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let tp = resolveTermPalette(theme)
  var lines: seq[string]
  lines.add("# " & genHeader("alacritty", SerializeOpts(target: tagSrgb,
      legacySrgb: true)))
  lines.add("colors:")
  lines.add("  primary:")
  if tp.bg.hasHex: lines.add("    background: '" & withHash(tp.bg) & "'")
  if tp.fg.hasHex: lines.add("    foreground: '" & withHash(tp.fg) & "'")
  lines.add("  cursor:")
  if tp.fg.hasHex: lines.add("    text: '" & withHash(tp.fg) & "'")
  if tp.cursor.hasHex: lines.add("    cursor: '" & withHash(tp.cursor) & "'")
  lines.add("  selection:")
  if tp.fg.hasHex: lines.add("    text: '" & withHash(tp.fg) & "'")
  if tp.selection.hasHex:
    lines.add("    background: '" & withHash(tp.selection) & "'")
  const ansiNames = ["black", "red", "green", "yellow", "blue", "magenta",
                     "cyan", "white"]
  lines.add("  normal:")
  for i in 0 .. 7:
    if tp.ansi[i].hasHex:
      lines.add("    " & ansiNames[i] & ":   '" & withHash(tp.ansi[i]) & "'")
  lines.add("  bright:")
  for i in 8 .. 15:
    if tp.ansi[i].hasHex:
      lines.add("    " & ansiNames[i - 8] & ":   '" & withHash(tp.ansi[i]) &
          "'")
  report(lines.join("\n"), termInfoLostWarning("alacritty",
      lostRoles(theme, fullTermProjected)))

# --- Kitty — conf colorN ------------------------------------------------
proc kittyRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let tp = resolveTermPalette(theme)
  var lines: seq[string]
  lines.add("# " & genHeader("kitty", SerializeOpts(target: tagSrgb,
      legacySrgb: true)))
  if tp.bg.hasHex: lines.add("background " & withHash(tp.bg))
  if tp.fg.hasHex: lines.add("foreground " & withHash(tp.fg))
  if tp.cursor.hasHex: lines.add("cursor " & withHash(tp.cursor))
  if tp.fg.hasHex: lines.add("cursor_text_color " & withHash(tp.fg))
  if tp.selection.hasHex:
    lines.add("selection_background " & withHash(tp.selection))
  if tp.fg.hasHex: lines.add("selection_foreground " & withHash(tp.fg))
  for i in 0 .. 15:
    if tp.ansi[i].hasHex: lines.add("color" & $i & " " & withHash(tp.ansi[i]))
  report(lines.join("\n"), termInfoLostWarning("kitty",
      lostRoles(theme, fullTermProjected)))

# --- WezTerm — Lua color_schemes ----------------------------------------
proc weztermRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let tp = resolveTermPalette(theme)
  var lines: seq[string]
  lines.add("-- " & genHeader("wezterm", SerializeOpts(target: tagSrgb,
      legacySrgb: true)))
  lines.add("return {")
  lines.add("  name = 'UniColor',")
  if tp.bg.hasHex: lines.add("  background = '" & withHash(tp.bg) & "',")
  if tp.fg.hasHex: lines.add("  foreground = '" & withHash(tp.fg) & "',")
  if tp.cursor.hasHex: lines.add("  cursor_bg = '" & withHash(tp.cursor) & "',")
  if tp.fg.hasHex: lines.add("  cursor_fg = '" & withHash(tp.fg) & "',")
  if tp.selection.hasHex:
    lines.add("  selection_bg = '" & withHash(tp.selection) & "',")
  if tp.fg.hasHex: lines.add("  selection_fg = '" & withHash(tp.fg) & "',")
  lines.add("  ansi = {")
  const ansiCmts = ["black", "red", "green", "yellow", "blue", "magenta",
                    "cyan", "white"]
  for i in 0 .. 7:
    if tp.ansi[i].hasHex:
      lines.add("    '" & withHash(tp.ansi[i]) & "', -- " & ansiCmts[i])
  lines.add("  },")
  lines.add("  brights = {")
  for i in 8 .. 15:
    if tp.ansi[i].hasHex:
      lines.add("    '" & withHash(tp.ansi[i]) & "', -- " & ansiCmts[i - 8])
  lines.add("  },")
  lines.add("}")
  report(lines.join("\n"), termInfoLostWarning("wezterm",
      lostRoles(theme, fullTermProjected)))

# --- Ghostty — conf palette ---------------------------------------------
proc ghosttyRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let tp = resolveTermPalette(theme)
  var lines: seq[string]
  lines.add("# " & genHeader("ghostty", SerializeOpts(target: tagSrgb,
      legacySrgb: true)))
  if tp.bg.hasHex: lines.add("background = " & withHash(tp.bg))
  if tp.fg.hasHex: lines.add("foreground = " & withHash(tp.fg))
  if tp.cursor.hasHex: lines.add("cursor-color = " & withHash(tp.cursor))
  if tp.selection.hasHex:
    lines.add("selection-background = " & withHash(tp.selection))
  lines.add("palette = [")
  for i in 0 .. 15:
    if tp.ansi[i].hasHex: lines.add("  " & $i & "=" & withHash(tp.ansi[i]))
  lines.add("]")
  report(lines.join("\n"), termInfoLostWarning("ghostty",
      lostRoles(theme, fullTermProjected)))

# --- Windows Terminal — JSON scheme -------------------------------------
const wtNormalKeys = ["black", "red", "green", "yellow", "blue", "purple",
                      "cyan", "white"] # Windows Terminal uses "purple" not "magenta".
const wtBrightKeys = ["brightBlack", "brightRed", "brightGreen", "brightYellow",
                      "brightBlue", "brightPurple", "brightCyan", "brightWhite"]

proc windowsterminalRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let tp = resolveTermPalette(theme)
  var lines: seq[string]
  lines.add("{")
  lines.add("  \"//\": \"" & genHeader("windowsterminal", SerializeOpts(
      target: tagSrgb, legacySrgb: true)) & "\",")
  lines.add("  \"name\": \"UniColor\",")
  if tp.bg.hasHex: lines.add("  \"background\": \"" & withHash(tp.bg) & "\",")
  if tp.fg.hasHex: lines.add("  \"foreground\": \"" & withHash(tp.fg) & "\",")
  if tp.cursor.hasHex:
    lines.add("  \"cursorColor\": \"" & withHash(tp.cursor) & "\",")
  if tp.selection.hasHex:
    lines.add("  \"selectionBackground\": \"" & withHash(tp.selection) & "\",")
  # 16 named ANSI keys (normal then bright); last entry has no trailing comma.
  var entries: seq[string]
  for i in 0 .. 7:
    if tp.ansi[i].hasHex:
      entries.add("  \"" & wtNormalKeys[i] & "\": \"" & withHash(tp.ansi[i]) &
          "\"")
  for i in 8 .. 15:
    if tp.ansi[i].hasHex:
      entries.add("  \"" & wtBrightKeys[i - 8] & "\": \"" & withHash(tp.ansi[
          i]) & "\"")
  if entries.len > 0:
    lines.add(entries.join(",\n")) # comma-separated, last entry no trailing comma.
  lines.add("}")
  report(lines.join("\n"), termInfoLostWarning("windowsterminal",
      lostRoles(theme, fullTermProjected)))

# --- Foot — ini [colors]. Foot uses 6-hex with NO `#` -------------------
proc footRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let tp = resolveTermPalette(theme)
  var lines: seq[string]
  lines.add("# " & genHeader("foot", SerializeOpts(target: tagSrgb,
      legacySrgb: true)))
  lines.add("[colors]")
  if tp.bg.hasHex: lines.add("background=" & tp.bg) # foot: no `#`.
  if tp.fg.hasHex: lines.add("foreground=" & tp.fg)
  for i in 0 .. 7:
    if tp.ansi[i].hasHex: lines.add("regular" & $i & "=" & tp.ansi[i])
  for i in 8 .. 15:
    if tp.ansi[i].hasHex: lines.add("bright" & $(i - 8) & "=" & tp.ansi[i])
  report(lines.join("\n"), termInfoLostWarning("foot",
      lostRoles(theme, fullTermProjected)))

# --- Warp — YAML custom theme (accent/background/foreground/details).
# Projects FEWER roles. --------------------------------------------------
proc warpRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let tp = resolveTermPalette(theme)
  var lines: seq[string]
  lines.add("# " & genHeader("warp", SerializeOpts(target: tagSrgb,
      legacySrgb: true)))
  # accent = the theme `accent` role (resolved separately — not in TermPalette aux).
  let accR = theme.resolve("accent")
  if accR.isOk:
    let gR = gamutMap(accR.get, tagSrgb)
    if gR.isOk: lines.add("accent:     '" & withHash(hex6(gR.get)) & "'")
  if tp.bg.hasHex: lines.add("background: '" & withHash(tp.bg) & "'")
  if tp.fg.hasHex: lines.add("foreground: '" & withHash(tp.fg) & "'")
  # `details` is a string not a color — 'darker' for dark themes, 'lighter' for
  # light. Default 'darker' (documented heuristic; deriving from bg L would
  # require parsing the hex — YAGNI here).
  lines.add("details:    'darker'")
  report(lines.join("\n"), termInfoLostWarning("warp",
      lostRoles(theme, warpProjected)))

# --- Xresources — X resources -------------------------------------------
proc xresourcesRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let tp = resolveTermPalette(theme)
  var lines: seq[string]
  lines.add("! " & genHeader("xresources", SerializeOpts(target: tagSrgb,
      legacySrgb: true))) # `!` is the Xresources comment prefix.
  if tp.bg.hasHex: lines.add("*.background:  " & withHash(tp.bg))
  if tp.fg.hasHex: lines.add("*.foreground:  " & withHash(tp.fg))
  if tp.cursor.hasHex: lines.add("*.cursorColor: " & withHash(tp.cursor))
  for i in 0 .. 15:
    if tp.ansi[i].hasHex:
      lines.add("*.color" & $i & ":  " & withHash(tp.ansi[i]))
  report(lines.join("\n"), termInfoLostWarning("xresources",
      lostRoles(theme, fullTermProjected)))

# Bootstrap — register the eight terminal exporters. Fired by
# `import "UniColor/export/terminals"`.
discard registerExporter(Exporter(name: "alacritty", render: alacrittyRender))
discard registerExporter(Exporter(name: "kitty", render: kittyRender))
discard registerExporter(Exporter(name: "wezterm", render: weztermRender))
discard registerExporter(Exporter(name: "ghostty", render: ghosttyRender))
discard registerExporter(Exporter(name: "windowsterminal",
    render: windowsterminalRender))
discard registerExporter(Exporter(name: "foot", render: footRender))
discard registerExporter(Exporter(name: "warp", render: warpRender))
discard registerExporter(Exporter(name: "xresources", render: xresourcesRender))
