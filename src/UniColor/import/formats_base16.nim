# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# import/formats_base16 — Base16/Base24 scheme importers, registered as
# "base16" (16 slots) and "base24" (24 slots). The mirror of export/base16.
# Base16/Base24 are DECLARATIVE slot-bounded scheme formats: the export projects
# the theme into a FIXED slot set (base00-07 neutrals, base08-0F syntax
# accents, base24 base10-17 status+brand) via a DECLARED slot->role mapping; the
# import is the INVERSE — parse the YAML scheme `slot: "hex"`, reverse-map
# slot->role, reconstruct a Theme of ALL PRIMITIVES (the slot roles, no aliases
# — the format is a flat slot->color map, like CSS).
#
# LOSSY: the format carries only 16/24 slots, so component tokens are NOT
# recoverable. The import CANNOT enumerate the lost roles (it has no original
# theme to compare against, unlike the export which has the full theme) -> ONE
# GENERIC `warnInfoLost` (non-silent) reminding the caller the reconstructed
# Theme is the slot subset. This is the honest, documented distinction from the
# export's enumerated warning.
#
# `schemaVersion` is OPTIONAL (UniColor header guard, mirrors CSS — a
# third-party base16 scheme with no UniColor header still parses):
# `readSchemaVersion` reads the version ONLY when the `UniColor` guard is
# present in the source (a coincidental `schema:` in a role name can't spoof
# it). When present, the gate runs via `checkSchema` (obsolete<min /
# future>current / malformed -> `err ImportFailed` fatal). When absent, no gate
# (third-party file). At v0 the gate is live but no migration is registered
# (identity). NOTE: CSS reads+reports the header WITHOUT gating (its documented
# lenient behavior); base16/terminals/IDE gate (the header is a version
# contract when present) — the inconsistency is documented, not a bug.
#
# Round-trip (mirrors CSS — LOSSY, NOT byte-identical at the Theme-tree level):
# the slot->hex map is preserved through export->import->re-export (golden
# asserts map equality, avoiding any float hex-round-trip assumption — parseHex
# `d/255` then hexByte `round(c*255)` is not guaranteed bit-identical through
# float32). The role SET of the imported Theme = the 16/24 mapped slot roles.
#
# Parsing is hand-rolled (mirrors the exporter). Scope: the UniColor-emitted
# scheme + third-party base16 YAML of the same flat `slot: "hex"` structure.
# `readHexColor` normalizes the hex (strip quotes/whitespace, ensure `#` —
# base16 YAML quotes the hex without `#`; parseColor requires `#`). Malformed
# hex -> `err InvalidColor`. `opts.strict` is honored at the READ sites
# (readColorOrSkip). No RNG, no I/O. `import` is a Nim keyword -> quoted import.
#
# The slot->role maps are DUPLICATED from export/base16.nim (`base16Slots` /
# `base24ExtraSlots`) on purpose: the DAG forbids import -> export (import is a
# lower layer), so the importer cannot reference the export's maps. Drift is
# caught by the round-trip test (export->import->re-export slot map equal).
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

# The declared slot->role mapping. MUST MIRROR export/base16.nim `base16Slots` /
# `base24ExtraSlots` — duplication is intentional (DAG: import cannot import
# export; see module header). Drift is caught by the round-trip test.
const base16SlotRoles: seq[(string, string)] = @[
  ("base00", "background"), ("base01", "surface"), ("base02",
      "surface.variant"),
  ("base03", "text.muted"), ("base04", "text.disabled"), ("base05",
      "text.primary"),
  ("base06", "text.secondary"), ("base07", "overlay"), ("base08",
      "syntax.variable"),
  ("base09", "syntax.constant"), ("base0A", "syntax.type"), ("base0B",
      "syntax.string"),
  ("base0C", "syntax.operator"), ("base0D", "primary"), ("base0E",
      "syntax.keyword"),
  ("base0F", "syntax.comment")]

const base24ExtraSlotRoles: seq[(string, string)] = @[
  ("base10", "error"), ("base11", "warning"), ("base12", "success"),
  ("base13", "info"),
  ("base14", "syntax.function"), ("base15", "secondary"), ("base16",
      "tertiary"),
  ("base17", "accent")]

# Read the schemaVersion from a UniColor generation header (the `schema: <ver>`
# segment), ONLY when the `UniColor` guard is present (mirrors sniff/CSS — a
# coincidental `schema:` in a role name can't spoof it; the header is always
# line 1 so find() returns its index first). Returns "" if absent (third-party
# file -> no gate).
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
# quotes/whitespace and a leading `#` if present, then re-prepends `#`
# (parseColor requires the `#` prefix; base16 YAML quotes the 6-hex WITHOUT `#`,
# foot/jetbrains emit bare 6-hex — both handled). `err InvalidColor` if the hex
# is malformed (non-hex digit, wrong length).
proc readHexColor(s: string): Result[Color, ColorError] {.raises: [].} =
  var v = s.strip()
  if v.len >= 2 and v[0] == '"' and v[^1] == '"':
    v = v[1 ..< ^1].strip()
  if v.len > 0 and v[0] == '#':
    discard
  else:
    v = "#" & v
  parseColor(v)

# Look up the role for a slot name in the slot->role table (linear scan — the
# tables are tiny: 16/24). "" if the slot name is not a mapped slot (a stray
# key the importer ignores — upward-compat field policy).
proc roleForSlot(slots: openArray[(string, string)],
    slot: string): string {.raises: [].} =
  for (s, role) in slots:
    if s == slot:
      return role
  ""

# Parse a base16/base24 scheme into a Theme. Shared by both formats (only the
# slot table differs). Reads the schemaVersion (gates if the UniColor header is
# present), extracts `slot: "hex"` lines for mapped slots into a role->color
# Table (last-wins dedup via `setRoleDedup` — a third-party scheme repeating a
# slot with a DIFFERENT color -> `warnDuplicateRole`; the slot maps are unique
# per role so a UniColor export never trips it), reconstructs the Theme (all
# primitives — the slot roles), emits one generic `warnInfoLost`
# (slot-bounded, documented), then MERGES the partial-failure collector's
# warnings. `opts.strict` is honored at the READ sites (readColorOrSkip:
# best-effort skips an unreadable token + warns + continues; strict hard-fails).
proc baseParse(input: string, opts: ImportOpts, formatName: string,
    slots: openArray[(string, string)]): Result[ImportReport,
        ColorError] {.raises: [].} =
  let schemaVersion = readSchemaVersion(input)
  if schemaVersion.len > 0:
    # UniColor header present -> gate (obsolete/future/malformed -> ImportFailed).
    let gR = checkSchema(schemaVersion)
    if gR.isErr:
      return err[ImportReport, ColorError](gR.error)
  var roleColors: Table[string, Color]
  var coll: PartialCollector
  for line in input.splitLines():
    let s = line.strip()
    if s.len == 0 or s.startsWith('#') or s.startsWith("scheme:") or
        s.startsWith("author:"):
      continue
    let sep = s.find(": ")
    if sep < 0:
      continue
    let slot = s[0 ..< sep]
    if not slot.startsWith("base"):
      continue
    let role = roleForSlot(slots, slot)
    if role.len == 0:
      continue # unmapped slot key — ignore (upward-compat field policy).
    let val = s[sep + 2 ..< s.len]
    let cR = readHexColor(val)
    # Partial failure: best-effort skips an unreadable token + warns + continues;
    # strict hard-fails. setRoleDedup applies the duplicate rule (last-wins +
    # warning on a real conflict; idempotent re-set with the same color = no
    # warning).
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
  # One generic warnInfoLost: the format is slot-bounded; theme roles beyond the
  # mapped slots are not recoverable from this source (the reconstructed Theme
  # carries only the slot subset).
  let msg = formatName & ": slot-bounded format carries only " & $slots.len &
      " mapped slots; theme roles beyond the slots are not recoverable from this source (info lost)"
  let warn = PaletteWarning(code: warnInfoLost, message: msg,
      context: formatName)
  var allWarnings = @[warn]
  allWarnings.add(coll.warnings)
  ok[ImportReport, ColorError](ImportReport(target: rR.get,
      formatName: formatName, schemaVersion: schemaVersion,
      warnings: allWarnings))

proc base16Parse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  baseParse(input, opts, "base16", base16SlotRoles)

proc base24Parse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  baseParse(input, opts, "base24", base16SlotRoles & base24ExtraSlotRoles)

# Bootstrap — register "base16" and "base24". Fired by the facade
# `import "UniColor/import/formats_base16"`.
discard registerImporter(Importer(name: "base16", parse: base16Parse))
discard registerImporter(Importer(name: "base24", parse: base24Parse))
