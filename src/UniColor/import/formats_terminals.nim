# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# import/formats_terminals — terminal-config importers. PARTIAL coverage: 4 of
# 8 terminal formats are registered here — "alacritty" (YAML), "kitty" (flat
# conf), "windowsterminal" (JSON), "foot" (ini, no `#`). The mirror of
# export/terminals.
#
# DEFERRED (documented missing slots — same inverse ANSI->role map, only the
# PER-FORMAT PARSING differs = mechanical follow-up, NOT a design gap):
# "wezterm" (Lua table), "ghostty" (conf palette array), "warp" (YAML 3-color),
# "xresources" (X resources). They reuse `assembleTerm` + the inverse maps
# defined here; a follow-up adds their per-format extractors.
#
# Terminals are SLOT-BOUNDED (the ANSI 16-color palette is a FIXED slot set).
# The export projects the theme into 16 ANSI + bg/fg/cursor/selection via a
# DECLARED role->ANSI mapping; the import is the INVERSE — parse the format's
# color entries into a `TermPalette` (16 ansi + 4 aux as raw hex strings),
# reverse-map slot->role, reconstruct a Theme of ALL PRIMITIVES. LOSSY: the
# 16-ANSI palette can't carry the full role set -> ONE GENERIC `warnInfoLost`
# (the import CANNOT enumerate the lost roles — it has no original theme to
# compare against, unlike the export).
#
# DUPLICATE-ROLE DEDUP: the export's ANSI map has multiple slots mapping to the
# SAME role (idx 1 & 9 -> "error"; idx 0 & aux "background" -> "background";
# aux "cursor"/"foreground" -> "text.primary" = idx 15). The export emits the
# SAME hex for the overlapping slots (one role -> one color). The import
# collects into a `Table[string, Color]` (last-wins, deterministic — the
# overlapping slots carry the same hex in a UniColor export, so no real
# conflict) BEFORE reconstruct, because `theme()` rejects duplicate role names.
#
# `schemaVersion` is OPTIONAL (UniColor header guard, mirrors base16/CSS — a
# third-party terminal config with no UniColor header still parses):
# `readSchemaVersion` reads the version ONLY when the `UniColor` guard is
# present; when present, `checkSchema` gates (obsolete/future/malformed -> `err
# ImportFailed`). When absent, no gate. At v0 the gate is live but no migration
# runs.
#
# Golden (byte-identical round-trip): the export iterates slots in FIXED order,
# resolving each role via a Table lookup (order-independent) -> the output
# depends only on the role->color MAPPING. So if the import reconstructs the
# same mapping, `exportTheme(importTheme(exportTheme(t, fmt), fmt), fmt) ==
# exportTheme(t, fmt)` — byte-identical (the sRGB hex round-trips through
# parseHex `b/255` then hexByte `round(c*255)` = identity for bytes; gamutMap
# sRGB->sRGB is identity).
#
# Parsing is hand-rolled (mirrors the exporter). `readHexColor` normalizes the
# hex (strip quotes/whitespace, ensure `#` — alacritty/kitty/windowsterminal
# quote `#hex`, foot emits bare 6-hex; parseColor requires `#`). `opts.strict`
# is honored at the READ sites (readColorOrSkip). No RNG, no I/O. `import` is a
# Nim keyword -> quoted import.
#
# The inverse ANSI/aux maps DUPLICATE export/terminals.nim `termAnsiRoles` /
# `termAuxRoles` (DAG: import cannot import export). Drift is caught by the
# byte-identical round-trip test.
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
import UniColor/palette/unsatisfiable # PaletteWarning / warnInfoLost.
import UniColor/core/schema # checkSchema (the gate).
import "UniColor/import/reconstruct" # ReconstructInput / reconstruct / defaultReconstructInput.
import "UniColor/import/partial" # PartialCollector / readColorOrSkip / setRoleDedup.
import "UniColor/import/registry" # Importer / ImportReport / ImportOpts / registerImporter.

# The inverse ANSI idx -> role + aux slot -> role maps. MUST MIRROR
# export/terminals.nim `termAnsiRoles` / `termAuxRoles` — duplication is
# intentional (DAG: import cannot import export). Drift is caught by the
# byte-identical round-trip test. Multiple idx map to the same role (dedup in
# assembleTerm).
const ansiRole: array[16, string] = ["background", "error", "success",
    "warning", "primary", "secondary", "tertiary", "text.secondary", "surface",
    "error", "success", "warning", "info",
    "secondary", "tertiary", "text.primary"]

const auxRole: array[4, (string, string)] = [("background", "background"),
    ("foreground", "text.primary"), ("cursor", "text.primary"),
    ("selection", "surface.variant")]

# Read the schemaVersion from a UniColor generation header (the `schema: <ver>`
# segment), ONLY when the `UniColor` guard is present (mirrors base16/CSS — a
# coincidental `schema:` can't spoof it; the guard substring works inside any
# comment syntax: `#`, `--`, `<!--`, or a JSON `"//":`). Returns "" if absent
# (third-party file -> no gate).
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
# quotes (BOTH single `'` — alacritty YAML — and double `"` — windowsterminal
# JSON / base16) and whitespace, ensures a leading `#` (parseColor requires
# `#`; foot emits bare 6-hex, kitty emits `#hex`). `err InvalidColor` if
# malformed (non-hex digit, wrong length).
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

# The resolved terminal palette: 16 ANSI + 4 aux as raw hex strings (6-hex,
# with or without `#`, possibly quoted — `readHexColor` normalizes). Empty =
# slot absent.
type TermPalette = object
  ansi: array[16, string]
  bg, fg, cursor, selection: string

# Map a TermPalette to a Theme + report. Collects role->color into a `Table`
# (last-wins dedup via `setRoleDedup` — the overlapping slots carry the same
# hex in a UniColor export, so no real conflict; a third-party file with a
# genuine duplicate-role conflict -> `warnDuplicateRole`). Reconstructs the
# Theme (all primitives — the slot roles), emits one generic `warnInfoLost`
# (slot-bounded, documented), then MERGES the partial-failure collector's
# warnings. `opts.strict` is honored at the READ sites (readColorOrSkip).
proc assembleTerm(formatName, schemaVersion: string, tp: TermPalette,
    opts: ImportOpts, coll: var PartialCollector): Result[ImportReport,
        ColorError] {.raises: [].} =
  var roleColors: Table[string, Color]
  # ANSI 16 -> role (last-wins for the duplicate-role slots).
  for idx in 0 .. 15:
    if tp.ansi[idx].len == 0:
      continue
    let cR = readHexColor(tp.ansi[idx])
    let sR = readColorOrSkip(cR, ansiRole[idx], formatName, opts, coll)
    if sR.isErr:
      return err[ImportReport, ColorError](sR.error)
    if sR.get.isSome:
      setRoleDedup(roleColors, ansiRole[idx], sR.get.get, formatName, coll)
  # Aux bg/fg/cursor/selection -> role (overlaps with ansi; last-wins, same hex
  # in a UniColor export).
  for (slot, role) in auxRole:
    let raw = case slot
      of "background": tp.bg
      of "foreground": tp.fg
      of "cursor": tp.cursor
      of "selection": tp.selection
      else: ""
    if raw.len == 0:
      continue
    let cR = readHexColor(raw)
    let sR = readColorOrSkip(cR, role, formatName, opts, coll)
    if sR.isErr:
      return err[ImportReport, ColorError](sR.error)
    if sR.get.isSome:
      setRoleDedup(roleColors, role, sR.get.get, formatName, coll)
  var inp = defaultReconstructInput()
  inp.schemaVersion = schemaVersion
  for role, col in pairs(roleColors):
    inp.primitives.add(ThemeToken(name: role, color: col))
  let rR = reconstruct(inp)
  if rR.isErr:
    return err[ImportReport, ColorError](rR.error)
  let warn = PaletteWarning(code: warnInfoLost,
      message: formatName & ": slot-bounded format carries the 16-ANSI palette + bg/fg/cursor/" &
          "selection; theme roles beyond the mapped slots are not recoverable from this source (info lost)",
      context: formatName)
  var allWarnings = @[warn]
  allWarnings.add(coll.warnings)
  ok[ImportReport, ColorError](ImportReport(target: rR.get,
      formatName: formatName, schemaVersion: schemaVersion,
      warnings: allWarnings))

# ANSI color-name -> index 0..7 (black/red/green/yellow/blue/magenta/cyan/
# white), -1 otherwise. Used by alacritty's `normal`/`bright` sections.
proc ansiNameIdx(name: string): int {.raises: [].} =
  case name
  of "black": 0
  of "red": 1
  of "green": 2
  of "yellow": 3
  of "blue": 4
  of "magenta": 5
  of "cyan": 6
  of "white": 7
  else: -1

# Parse a non-negative integer from a string WITHOUT raising (Nim's `parseInt`
# raises ValueError, forbidden under `raises: []`). Returns -1 if the string is
# empty or contains a non-digit. Used for the numeric suffixes of
# `color0`/`regular3`/`bright7` (kitty/foot) — the export always emits valid
# digits, but a third-party file may carry junk, and we skip it (no crash).
proc safeParseInt(s: string): int {.raises: [].} =
  if s.len == 0:
    return -1
  result = 0
  for ch in s:
    if ch < '0' or ch > '9':
      return -1
    result = result * 10 + ord(ch) - ord('0')

# Parse a `key: value` YAML-ish line (alacritty) into (key, value). Returns
# ("", "") if no `: ` found.
proc yamlKV(line: string): (string, string) {.raises: [].} =
  let sep = line.find(": ")
  if sep < 0:
    return ("", "")
  (line[0 ..< sep], line[sep + 2 ..< line.len].strip())

# --- alacritty — YAML colors -------------------------------------------
proc alacrittyParse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  var tp: TermPalette
  var coll: PartialCollector
  var section = ""
  for raw in input.splitLines():
    let s = raw.strip()
    if s.len == 0 or s.startsWith('#'):
      continue # comment / blank — entry lines start with a key, never bare `#`.
    if s.endsWith(':'):
      let name = s[0 ..< ^1]
      if name in ["primary", "cursor", "selection", "normal", "bright",
          "colors"]:
        section = name
      continue
    let (key, val) = yamlKV(s)
    if key.len == 0:
      continue
    case section
    of "primary":
      if key == "background": tp.bg = val
      elif key == "foreground": tp.fg = val
    of "cursor":
      if key == "cursor": tp.cursor = val
      elif key == "text": tp.fg = val # cursor text = fg.
    of "selection":
      if key == "background": tp.selection = val
      elif key == "text": tp.fg = val # selection text = fg.
    of "normal":
      let idx = ansiNameIdx(key)
      if idx >= 0: tp.ansi[idx] = val
    of "bright":
      let idx = ansiNameIdx(key)
      if idx >= 0: tp.ansi[idx + 8] = val
    else: discard
  let sv = readSchemaVersion(input)
  if sv.len > 0:
    let gR = checkSchema(sv)
    if gR.isErr:
      return err[ImportReport, ColorError](gR.error)
  assembleTerm("alacritty", sv, tp, opts, coll)

# --- kitty — flat conf `key #hex` --------------------------------------
proc kittyParse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  var tp: TermPalette
  var coll: PartialCollector
  for raw in input.splitLines():
    let s = raw.strip()
    if s.len == 0 or s.startsWith('#'):
      continue # comment — entry lines start with a key.
    let sp = s.find(' ')
    if sp < 0:
      continue
    let key = s[0 ..< sp]
    let val = s[sp + 1 ..< s.len].strip()
    if key.startsWith("color") and key.len > 5:
      let nR = safeParseInt(key[5 ..< key.len])
      if nR >= 0 and nR <= 15:
        tp.ansi[nR] = val
    elif key == "background": tp.bg = val
    elif key == "foreground": tp.fg = val
    elif key == "cursor": tp.cursor = val
    elif key == "selection_background": tp.selection = val
  let sv = readSchemaVersion(input)
  if sv.len > 0:
    let gR = checkSchema(sv)
    if gR.isErr:
      return err[ImportReport, ColorError](gR.error)
  assembleTerm("kitty", sv, tp, opts, coll)

# --- windowsterminal — flat JSON `{"key": "#hex", ...}` ----------------
# Scan a flat JSON object for `"key": "value"` pairs (the WT scheme is flat —
# no nesting). A char scanner: finds `"`, reads until the closing `"`, skips
# `:`/whitespace, reads the value string.
proc wtParse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  var tp: TermPalette
  var coll: PartialCollector
  var i = 0
  let n = input.len
  while i < n:
    if input[i] == '"':
      inc i
      var key = ""
      while i < n and input[i] != '"':
        key.add(input[i])
        inc i
      if i < n: inc i # past closing `"`.
      while i < n and input[i] in {':', ' ', '\t', '\n', '\r'}:
        inc i
      if i < n and input[i] == '"':
        inc i
        var val = ""
        while i < n and input[i] != '"':
          val.add(input[i])
          inc i
        if i < n: inc i
        case key
        of "background": tp.bg = val
        of "foreground": tp.fg = val
        of "cursorColor": tp.cursor = val
        of "selectionBackground": tp.selection = val
        of "black": tp.ansi[0] = val
        of "red": tp.ansi[1] = val
        of "green": tp.ansi[2] = val
        of "yellow": tp.ansi[3] = val
        of "blue": tp.ansi[4] = val
        of "purple": tp.ansi[5] = val
        of "cyan": tp.ansi[6] = val
        of "white": tp.ansi[7] = val
        of "brightBlack": tp.ansi[8] = val
        of "brightRed": tp.ansi[9] = val
        of "brightGreen": tp.ansi[10] = val
        of "brightYellow": tp.ansi[11] = val
        of "brightBlue": tp.ansi[12] = val
        of "brightPurple": tp.ansi[13] = val
        of "brightCyan": tp.ansi[14] = val
        of "brightWhite": tp.ansi[15] = val
        else: discard # "name", "//" header, etc. — ignore.
    else: inc i
  let sv = readSchemaVersion(input)
  if sv.len > 0:
    let gR = checkSchema(sv)
    if gR.isErr:
      return err[ImportReport, ColorError](gR.error)
  assembleTerm("windowsterminal", sv, tp, opts, coll)

# --- foot — ini `[colors] key=hex (no #) --------------------------------
proc footParse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  var tp: TermPalette
  var coll: PartialCollector
  var inColors = false
  for raw in input.splitLines():
    let s = raw.strip()
    if s.len == 0 or s.startsWith('#'):
      continue # comment — foot hex is bare (no `#`), entry lines start with a key.
    if s == "[colors]":
      inColors = true
      continue
    if s.startsWith('['):
      inColors = false # a different ini section.
      continue
    if not inColors:
      continue
    let eq = s.find('=')
    if eq < 0:
      continue
    let key = s[0 ..< eq]
    let val = s[eq + 1 ..< s.len].strip()
    if key == "background": tp.bg = val
    elif key == "foreground": tp.fg = val
    elif key.startsWith("regular") and key.len > 7:
      let nR = safeParseInt(key[7 ..< key.len])
      if nR >= 0 and nR <= 7: tp.ansi[nR] = val
    elif key.startsWith("bright") and key.len > 6:
      let nR = safeParseInt(key[6 ..< key.len])
      if nR >= 0 and nR <= 7: tp.ansi[nR + 8] = val
  let sv = readSchemaVersion(input)
  if sv.len > 0:
    let gR = checkSchema(sv)
    if gR.isErr:
      return err[ImportReport, ColorError](gR.error)
  assembleTerm("foot", sv, tp, opts, coll)

# Bootstrap — register the 4 terminal importers (PARTIAL, 4 of 8;
# wezterm/ghostty/warp/xresources deferred, documented missing slots). Fired by
# the facade `import "UniColor/import/formats_terminals"`.
discard registerImporter(Importer(name: "alacritty", parse: alacrittyParse))
discard registerImporter(Importer(name: "kitty", parse: kittyParse))
discard registerImporter(Importer(name: "windowsterminal", parse: wtParse))
discard registerImporter(Importer(name: "foot", parse: footParse))
