# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# export/ide — IDE theme exporters, registered as "neovim", "helix", "vscode",
# "jetbrains". Each projects the theme's syntax + UI + status roles into the
# IDE's highlight-group/scope vocabulary via a DECLARED role->token mapping,
# truecolor sRGB hex (gamut-mapped to sRGB: L/h preserved, C reduced to land in
# gamut). IDE formats are LOSSLESS in the slot sense (highlight groups are
# extensible): a theme role with no IDE mapping is simply OMITTED (no
# `warnInfoLost` — contrast with Base16/terminal which are slot-bounded and DO
# warn). A missing/unresolvable role -> its token is omitted (no warning — the
# color was never resolvable).
#
# Formats (all deterministic: fixed token order, gamut-map, literal header; same
# (theme, opts) -> byte-identical):
#   - neovim   : Lua `vim.api.nvim_set_hl(0, "Group", { fg = "#rrggbb" })`.
#   - helix    : TOML `"highlight.name" = "#rrggbb"` top-level keys.
#   - vscode   : JSON theme { "//": header, "name", "colors", "tokenColors" }.
#   - jetbrains: XML `<scheme ...><!-- header --><option name="TOKEN"
#                value="rrggbb" /></scheme>` (option values are 6-hex with NO
#                `#`, JetBrains convention).
#
# Self-registers via `discard registerExporter(...)`; the facade
# `export/export.nim` imports this module to fire it.
#
# Layer: export (consumer of serialize + registry + conversion + theme).
import std/strutils
import std/options
import std/tables
import UniColor/core/core # Color, tagSrgb.
import UniColor/core/result
import UniColor/core/color_error
import UniColor/conversion/conversion # gamutMap.
import UniColor/theme/tree
import "UniColor/export/serialize" # formatColorCss, genHeader.
import "UniColor/export/registry"

# A resolved theme role rendered as sRGB hex. `withHash` true -> `#rrggbb`
# (neovim/helix/vscode); false -> `rrggbb` (jetbrains XML option value). `none`
# if the role is absent or unresolvable (the caller omits the token — IDE is
# lossless, no warning).
proc resolveHex(theme: Theme, role: string, withHash: bool): Option[string] {.
    raises: [].} =
  let rR = theme.resolve(role)
  if rR.isErr:
    return none(string)
  let gR = gamutMap(rR.get, tagSrgb)
  if gR.isErr:
    return none(string)
  let s = formatColorCss(gR.get, true) # "#rrggbb" (c is sRGB after gamutMap).
  some(if withHash: s else: s[1 ..^ 1])

# --- Neovim — Lua nvim_set_hl -------------------------------------------
# (nvim group, role, field). field "fg"/"bg" selects which side of the highlight
# carries the color.
const neovimTokens: seq[(string, string, string)] = @[
  ("Normal", "background", "bg"), ("Normal", "text.primary", "fg"),
  ("NormalNC", "background", "bg"), ("CursorLine", "surface", "bg"),
  ("Visual", "surface.variant", "bg"), ("Search", "surface.variant", "bg"),
  ("Comment", "syntax.comment", "fg"), ("Keyword", "syntax.keyword", "fg"),
  ("String", "syntax.string", "fg"), ("Function", "syntax.function", "fg"),
  ("Identifier", "syntax.variable", "fg"), ("Constant", "syntax.constant",
      "fg"),
  ("Type", "syntax.type", "fg"), ("Operator", "syntax.operator", "fg"),
  ("Number", "syntax.number", "fg"), ("Special", "syntax.namespace", "fg"),
  ("NonText", "text.muted", "fg"), ("Error", "error", "fg"),
  ("Todo", "warning", "fg")]

proc neovimRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  var lines: seq[string]
  lines.add("-- " & genHeader("neovim", SerializeOpts(target: tagSrgb,
      legacySrgb: true)))
  # Group entries by nvim group (first-appearance order) and merge fields into
  # ONE nvim_set_hl call per group (e.g. Normal carries both bg=background and
  # fg=text.primary). Deterministic.
  var groupOrder: seq[string]
  var groupFields: Table[string, seq[(string, string)]]       # field -> hex.
  for (group, role, field) in neovimTokens:
    let hR = resolveHex(theme, role, true)
    if hR.isSome:
      if group notin groupOrder:
        groupOrder.add(group)
        groupFields[group] = @[]
      var fields = groupFields.getOrDefault(group)
      fields.add((field, hR.get))
      groupFields[group] = fields
  for group in groupOrder:
    var parts: seq[string]
    for (field, hex) in groupFields.getOrDefault(group):
      parts.add(field & " = \"" & hex & "\"")
    lines.add("vim.api.nvim_set_hl(0, \"" & group & "\", { " & parts.join(
        ", ") & " })")
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: @[]))

# --- Helix — TOML highlight keys ----------------------------------------
const helixTokens: seq[(string, string)] = @[
  ("\"ui.background\"", "background"), ("\"ui.text\"", "text.primary"),
  ("\"ui.text.dim\"", "text.muted"), ("\"ui.cursorline\"", "surface"),
  ("\"ui.selection\"", "surface.variant"), ("\"ui.linenr\"", "text.muted"),
  ("\"ui.statusline\"", "surface"),
  ("\"syntax.keyword\"", "syntax.keyword"),
  ("\"syntax.string\"", "syntax.string"),
  ("\"syntax.function\"", "syntax.function"),
  ("\"syntax.variable\"", "syntax.variable"),
  ("\"syntax.constant\"", "syntax.constant"),
  ("\"syntax.type\"", "syntax.type"),
  ("\"syntax.operator\"", "syntax.operator"),
  ("\"syntax.comment\"", "syntax.comment"),
  ("\"syntax.number\"", "syntax.number"),
  ("\"syntax.namespace\"", "syntax.namespace"),
  ("\"diagnostic.error\"", "error"), ("\"diagnostic.warning\"", "warning"),
  ("\"diagnostic.info\"", "info"), ("\"diff.plus\"", "success")]

proc helixRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  var lines: seq[string]
  lines.add("# " & genHeader("helix", SerializeOpts(target: tagSrgb,
      legacySrgb: true)))
  for (key, role) in helixTokens:
    let hR = resolveHex(theme, role, true)
    if hR.isSome:
      lines.add(key & " = \"" & hR.get & "\"")
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: @[]))

# --- VSCode — JSON theme ------------------------------------------------
const vscodeColors: seq[(string, string)] = @[
  ("editor.background", "background"),
  ("editor.foreground", "text.primary"),
  ("editorLineNumber.foreground", "text.muted"),
  ("editor.selectionBackground", "surface.variant"),
  ("editorCursor.foreground", "text.primary"),
  ("statusBar.background", "surface")]

const vscodeScopes: seq[(string, string)] = @[
  ("keyword", "syntax.keyword"), ("string", "syntax.string"),
  ("function", "syntax.function"), ("variable", "syntax.variable"),
  ("constant", "syntax.constant"), ("storage.type", "syntax.type"),
  ("keyword.operator", "syntax.operator"), ("comment", "syntax.comment"),
  ("constant.numeric", "syntax.number"), ("entity.name.namespace",
      "syntax.namespace")]

proc vscodeRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  var lines: seq[string]
  lines.add("{")
  lines.add("  \"//\": \"" & genHeader("vscode", SerializeOpts(target: tagSrgb,
      legacySrgb: true)) & "\",")
  lines.add("  \"name\": \"UniColor\",")
  lines.add("  \"colors\": {")
  var colorEntries: seq[string]
  for (key, role) in vscodeColors:
    let hR = resolveHex(theme, role, true)
    if hR.isSome:
      colorEntries.add("    \"" & key & "\": \"" & hR.get & "\"")
  lines.add(colorEntries.join(",\n"))
  lines.add("  },")
  lines.add("  \"tokenColors\": [")
  var tokenEntries: seq[string]
  for (scope, role) in vscodeScopes:
    let hR = resolveHex(theme, role, true)
    if hR.isSome:
      # Built segment-by-segment to avoid a long `& ident` chain that nimpretty
      # collapses into `&hR.get` (address-of) at the wrap boundary.
      var e = "    { \"scope\": \""
      e.add(scope)
      e.add("\", \"settings\": { \"foreground\": \"")
      e.add(hR.get)
      e.add("\" } }")
      tokenEntries.add(e)
  lines.add(tokenEntries.join(",\n"))
  lines.add("  ]")
  lines.add("}")
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: @[]))

# --- JetBrains — XML scheme (.icls) -------------------------------------
const jetbrainsTokens: seq[(string, string)] = @[
  ("BACKGROUND", "background"), ("FOREGROUND", "text.primary"),
  ("TEXT", "text.primary"), ("CARET_COLOR", "text.primary"),
  ("SELECTION_BACKGROUND", "surface.variant"),
  ("LINE_NUMBERS_COLOR", "text.muted"),
  ("KEYWORD", "syntax.keyword"), ("STRING", "syntax.string"),
  ("FUNCTION_CALL", "syntax.function"), ("FUNCTION_DECLARATION",
      "syntax.function"),
  ("LOCAL_VARIABLE", "syntax.variable"), ("CONSTANT", "syntax.constant"),
  ("CLASS_NAME", "syntax.type"), ("OPERATION_SIGN", "syntax.operator"),
  ("COMMENT", "syntax.comment"), ("NUMBER", "syntax.number"),
  ("ERROR_ATTRIBUTES", "error"), ("WARNING_ATTRIBUTES", "warning")]

proc jetbrainsRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  var lines: seq[string]
  # Header comment FIRST (before the root <scheme> element — valid XML, and the
  # generation header on line 1 for traceability, consistent with the other
  # formats).
  lines.add("<!-- " & genHeader("jetbrains", SerializeOpts(target: tagSrgb,
      legacySrgb: true)) & " -->")
  lines.add("<scheme name=\"UniColor\" version=\"142\" group=\"UniColor\">")
  for (token, role) in jetbrainsTokens:
    let hR = resolveHex(theme, role, false) # JetBrains option value = 6-hex NO '#'.
    if hR.isSome:
      lines.add("  <option name=\"" & token & "\" value=\"" & hR.get & "\" />")
  lines.add("</scheme>")
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: @[]))

# Bootstrap — register the four IDE exporters. Fired by
# `import "UniColor/export/ide"`.
discard registerExporter(Exporter(name: "neovim", render: neovimRender))
discard registerExporter(Exporter(name: "helix", render: helixRender))
discard registerExporter(Exporter(name: "vscode", render: vscodeRender))
discard registerExporter(Exporter(name: "jetbrains", render: jetbrainsRender))
