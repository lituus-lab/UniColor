# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# import/formats_ide — IDE-theme importers. PARTIAL coverage: 2 of 4 IDE
# formats are registered here — "vscode" (JSON theme) and "helix" (TOML
# highlight keys). The mirror of export/ide.
#
# DEFERRED (documented missing slots — same inverse token->role map, only the
# PER-FORMAT PARSING differs = mechanical follow-up, NOT a design gap):
# "neovim" (Lua nvim_set_hl calls) and "jetbrains" (XML <option> elements,
# 6-hex NO '#'). They reuse `assembleIde` + the inverse maps defined here; a
# follow-up adds their per-format extractors.
#
# LOSSLESS mirror (export/ide declares IDE lossless in the slot sense — the
# highlight vocabulary is extensible, so a role with no mapping is OMITTED
# without `warnInfoLost`, unlike base16/terminals which ARE slot-bounded and DO
# warn). The import is the faithful inverse: it recovers exactly the roles the
# export emitted (a subset of the token map) and emits NO warning — the
# round-trip is byte-identical, nothing concrete is dropped (contrast with CSS
# where a dark @media block is real dropped information, and base16/terminals
# where the fixed slot set is lossy). The import still CANNOT recover roles
# beyond the token map, but the export never emitted them, so the cycle loses
# nothing.
#
# DUPLICATE-ROLE DEDUP: the export's token maps have multiple tokens mapping to
# the SAME role (vscode "editor.foreground" + "editorCursor.foreground" ->
# "text.primary"; helix "ui.cursorline" + "ui.statusline" -> "surface"). The
# export emits the SAME hex for the overlapping tokens (one role -> one color).
# The import collects into a `Table[string, Color]` (last-wins, deterministic —
# overlapping tokens carry the same hex in a UniColor export, so no real
# conflict) BEFORE reconstruct, because `theme()` rejects duplicate role names.
#
# `schemaVersion` is OPTIONAL (UniColor header guard, mirrors base16/terminals/
# CSS): the header lives inside a format-native comment (`#` for helix TOML,
# `"//":` for vscode JSON); `readSchemaVersion` reads the version ONLY when the
# `UniColor` guard substring is present (works inside any comment syntax). When
# present, `checkSchema` gates (obsolete/future/malformed -> `err ImportFailed`).
# When absent, no gate.
#
# Golden (byte-identical round-trip): the export iterates tokens in FIXED order,
# resolving each role via a Table lookup (order-independent) -> the output
# depends only on the role->color MAPPING. So if the import reconstructs the
# same mapping, `exportTheme(importTheme(exportTheme(t, fmt), fmt), fmt) ==
# exportTheme(t, fmt)` — byte-identical (sRGB hex round-trips through
# parseHex/hexByte; gamutMap sRGB->sRGB is identity).
#
# Parsing is hand-rolled (mirrors the exporter). `readHexColor` normalizes the
# hex (strip quotes/whitespace, ensure `#` — vscode JSON quotes `#hex`, helix
# TOML quotes `#hex`; parseColor requires `#`). `opts.strict` is honored at the
# READ sites (readColorOrSkip). No RNG, no I/O. `import` is a Nim keyword ->
# quoted import.
#
# The inverse token->role maps DUPLICATE export/ide.nim `vscodeColors`/
# `vscodeScopes` / `helixTokens` (DAG: import cannot import export). Drift is
# caught by the byte-identical round-trip test.
#
# Layer: import (consumer of parse_color + reconstruct + core/schema +
# registry).
import std/strutils
import std/tables
import std/options
import UniColor/core/result
import UniColor/core/core # Color.
import UniColor/core/color_error
import UniColor/theme/tree # ThemeToken.
import UniColor/core/parse_color # parseColor.
import UniColor/core/schema # checkSchema (the gate).
import "UniColor/import/reconstruct" # ReconstructInput / reconstruct / defaultReconstructInput.
import "UniColor/import/partial" # PartialCollector / readColorOrSkip / setRoleDedup.
import "UniColor/import/registry" # Importer / ImportReport / ImportOpts / registerImporter.

# The inverse vscode token->role maps. MUST MIRROR export/ide.nim `vscodeColors`
# / `vscodeScopes` — duplication is intentional (DAG: import cannot import
# export). Drift is caught by the byte-identical round-trip test.
const vscodeColorRole: seq[(string, string)] = @[
  ("editor.background", "background"), ("editor.foreground", "text.primary"),
  ("editorLineNumber.foreground", "text.muted"),
  ("editor.selectionBackground", "surface.variant"),
  ("editorCursor.foreground", "text.primary"), ("statusBar.background",
      "surface")]

const vscodeScopeRole: seq[(string, string)] = @[
  ("keyword", "syntax.keyword"), ("string", "syntax.string"),
  ("function", "syntax.function"), ("variable", "syntax.variable"),
  ("constant", "syntax.constant"), ("storage.type", "syntax.type"),
  ("keyword.operator", "syntax.operator"), ("comment", "syntax.comment"),
  ("constant.numeric", "syntax.number"), ("entity.name.namespace",
      "syntax.namespace")]

# The inverse helix token->role map. The export emits the key WITH surrounding
# quotes (`"ui.background"`); here we store the UNQUOTED key and quote-compare
# during parsing.
const helixTokenRole: seq[(string, string)] = @[
  ("ui.background", "background"), ("ui.text", "text.primary"),
  ("ui.text.dim", "text.muted"), ("ui.cursorline", "surface"),
  ("ui.selection", "surface.variant"), ("ui.linenr", "text.muted"),
  ("ui.statusline", "surface"), ("syntax.keyword", "syntax.keyword"),
  ("syntax.string", "syntax.string"), ("syntax.function", "syntax.function"),
  ("syntax.variable", "syntax.variable"), ("syntax.constant",
      "syntax.constant"),
  ("syntax.type", "syntax.type"), ("syntax.operator", "syntax.operator"),
  ("syntax.comment", "syntax.comment"), ("syntax.number", "syntax.number"),
  ("syntax.namespace", "syntax.namespace"), ("diagnostic.error", "error"),
  ("diagnostic.warning", "warning"), ("diagnostic.info", "info"),
  ("diff.plus", "success")]

# Read the schemaVersion from a UniColor generation header (the `schema: <ver>`
# segment), ONLY when the `UniColor` guard is present (mirrors base16/terminals/
# CSS — a coincidental `schema:` can't spoof it; the guard substring works
# inside any comment syntax: `#` for helix, `"//":` for vscode JSON). Returns ""
# if absent (third-party file -> no gate).
proc readSchemaVersion(input: string): string {.raises: [].} =
  if "UniColor" notin input:
    return ""
  let idx = input.find("schema: ")
  if idx < 0:
    return ""
  result = ""
  var i = idx + "schema: ".len
  while i < input.len and input[i] in {'a'..'z', 'A'..'Z', '0'..'9', '.', '-', '+'}:
    result.add(input[i])
    inc i

# Normalize a hex color string to `#rrggbb` and parse it. Strips surrounding
# quotes (BOTH single `'` and double `"`) and whitespace, ensures a leading
# `#` (parseColor requires `#`; vscode/helix both quote `#hex`). `err
# InvalidColor` if malformed (non-hex digit, wrong length).
proc readHexColor(s: string): Result[Color, ColorError] {.raises: [].} =
  var v = s.strip()
  while v.len >= 2 and ((v[0] == '"' and v[^1] == '"') or (v[0] == '\'' and
      v[^1] == '\'')):
    v = v[1 ..< ^1].strip()
  if v.len > 0 and v[0] == '#':
    discard
  else:
    v = "#" & v
  parseColor(v)

# Reconstruct a Theme from a role->color map + a partial-failure collector.
# Merges the collector's warnings (skipped tokens / duplicate-role conflicts)
# into the report. IDE is lossless in the SLOT sense (no `warnInfoLost`), but a
# third-party file MAY carry an unreadable token or a real duplicate-role
# conflict -> those warnings flow through here. NO `warnInfoLost` is emitted
# (mirror of export/ide). `opts.strict` is honored at the READ sites
# (readColorOrSkip), not here (reconstruct is color-agnostic).
proc assembleIde(formatName, schemaVersion: string, roleColors: Table[string,
    Color], coll: var PartialCollector): Result[ImportReport,
        ColorError] {.raises: [].} =
  var inp = defaultReconstructInput()
  inp.schemaVersion = schemaVersion
  for role, col in pairs(roleColors):
    inp.primitives.add(ThemeToken(name: role, color: col))
  let rR = reconstruct(inp)
  if rR.isErr:
    return err[ImportReport, ColorError](rR.error)
  ok[ImportReport, ColorError](ImportReport(target: rR.get,
      formatName: formatName, schemaVersion: schemaVersion,
      warnings: coll.warnings))

# --- helix — TOML top-level `"key" = "#hex"` ---------------------------
proc helixParse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  var roleColors: Table[string, Color]
  var coll: PartialCollector
  for raw in input.splitLines():
    let s = raw.strip()
    if s.len == 0 or s.startsWith('#'):
      continue # comment — entry lines start with a quoted key.
    # A helix entry: `"key" = "#hex"`. Find the closing quote of the key, then
    # `=`, then the hex.
    if s.len < 2 or s[0] != '"':
      continue
    let keyEnd = s.find('"', 1)
    if keyEnd < 0:
      continue
    let key = s[1 ..< keyEnd]
    let eq = s.find('=', keyEnd + 1)
    if eq < 0:
      continue
    let val = s[eq + 1 ..< s.len].strip()
    # Linear-scan the inverse map (small, fixed — mirrors export's lookup).
    var role = ""
    for (k, r) in helixTokenRole:
      if k == key:
        role = r
        break
    if role.len == 0:
      continue # not a known helix token — ignore (upward-compat / third-party key).
    let cR = readHexColor(val)
    # Partial failure: best-effort (strict=false) skips an unreadable token +
    # warns + continues; strict=true hard-fails. setRoleDedup applies the
    # duplicate rule (last-wins + warning on a real conflict; idempotent re-set
    # with the same color = no warning).
    let sR = readColorOrSkip(cR, role, "helix", opts, coll)
    if sR.isErr:
      return err[ImportReport, ColorError](sR.error)
    if sR.get.isSome:
      setRoleDedup(roleColors, role, sR.get.get, "helix", coll)
  if roleColors.len == 0:
    return err[ImportReport, ColorError](colorError(ImportFailed,
        "helix: no known highlight tokens found", "helixParse"))
  let sv = readSchemaVersion(input)
  if sv.len > 0:
    let gR = checkSchema(sv)
    if gR.isErr:
      return err[ImportReport, ColorError](gR.error)
  assembleIde("helix", sv, roleColors, coll)

# --- vscode — JSON theme `{ "colors": {...}, "tokenColors": [...] }` ----
# Walk a JSON string literal starting at index `i` (input[i] == '"'); return the
# unescaped content and the index PAST the closing '"'. Escapes (`\"`, `\\`)
# are honored. Returns ("", i) if no closing quote is found (malformed — caller
# treats as junk).
proc jsonStr(input: string, i0: int): (string, int) {.raises: [].} =
  var s = ""
  var i = i0 + 1 # past opening '"'.
  let n = input.len
  while i < n:
    if input[i] == '\\' and i + 1 < n:
      s.add(input[i + 1])
      i += 2
      continue
    if input[i] == '"':
      return (s, i + 1)
    s.add(input[i])
    inc i
  (s, i)

proc vscodeParse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  var roleColors: Table[string, Color]
  var coll: PartialCollector
  var lastScope = "" # the most recent `"scope": "name"` seen — bound to the next `foreground`.
  var i = 0
  let n = input.len
  # Single scan over `"key": "value"` pairs. The export emits `colors` as flat
  # `"key": "#hex"` pairs, and `tokenColors` as
  # `{ "scope": "name", "settings": { "foreground": "#hex" } }` — so a
  # `foreground` value is bound to the MOST RECENT `scope` string (tracked in
  # `lastScope`). We traverse the JSON transparently (a leaf is any
  # `"key": "value"` with a string value).
  while i < n:
    if input[i] == '"':
      let (key, j) = jsonStr(input, i)
      i = j
      # Skip whitespace + ':' + whitespace.
      while i < n and input[i] in {' ', '\t', '\n', '\r'}: inc i
      if i < n and input[i] == ':': inc i
      while i < n and input[i] in {' ', '\t', '\n', '\r'}: inc i
      if i < n and input[i] == '"':
        let (val, k) = jsonStr(input, i)
        i = k
        # Classify the pair: a `colors` entry (key in vscodeColorRole), a scope
        # declaration (key == "scope" -> remember the scope name for the next
        # foreground), or a tokenColors foreground (key == "foreground" -> bind
        # to lastScope via vscodeScopeRole). Else ignore.
        if key == "scope":
          lastScope = val
        elif key == "foreground" and lastScope.len > 0:
          var role = ""
          for (sk, r) in vscodeScopeRole:
            if sk == lastScope:
              role = r
              break
          if role.len > 0:
            let cR = readHexColor(val)
            let sR = readColorOrSkip(cR, role, "vscode", opts, coll)
            if sR.isErr:
              return err[ImportReport, ColorError](sR.error)
            if sR.get.isSome:
              setRoleDedup(roleColors, role, sR.get.get, "vscode", coll)
          lastScope = "" # consume the scope (one foreground per scope entry).
        else:
          var role = ""
          for (ck, r) in vscodeColorRole:
            if ck == key:
              role = r
              break
          if role.len > 0:
            let cR = readHexColor(val)
            let sR = readColorOrSkip(cR, role, "vscode", opts, coll)
            if sR.isErr:
              return err[ImportReport, ColorError](sR.error)
            if sR.get.isSome:
              setRoleDedup(roleColors, role, sR.get.get, "vscode", coll)
      else: discard # non-string value (e.g. "name": "UniColor", or "settings": {) — ignore.
    else: inc i
  if roleColors.len == 0:
    return err[ImportReport, ColorError](colorError(ImportFailed,
        "vscode: no known theme/color tokens found", "vscodeParse"))
  let sv = readSchemaVersion(input)
  if sv.len > 0:
    let gR = checkSchema(sv)
    if gR.isErr:
      return err[ImportReport, ColorError](gR.error)
  assembleIde("vscode", sv, roleColors, coll)

# Bootstrap — register the 2 IDE importers (PARTIAL, 2 of 4; neovim/jetbrains
# deferred, documented missing slots). Fired by the facade
# `import "UniColor/import/formats_ide"`.
discard registerImporter(Importer(name: "vscode", parse: vscodeParse))
discard registerImporter(Importer(name: "helix", parse: helixParse))
