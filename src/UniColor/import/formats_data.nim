# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# import/formats_data — JSON/TOML/YAML importers, registered as "json",
# "toml", "yaml". The mirror of export/json_toml_yaml. These are the CANONICAL
# round-trip formats: the data exports PRESERVE the ALIAS STRUCTURE (primitives
# carry the color string; semantics/components carry the raw alias TARGET NAME,
# not the resolved color), so the importer reconstructs the FULL Theme tree
# (all three layers) — LOSSLESS, unlike CSS which flattens to all-primitives.
#
# `schemaVersion` is REQUIRED: the importer gates it via `migrateData` (gate +
# migration pipeline). At version "0" (min == current) the pipeline is INERT
# (no migrations registered, identity pass-through), but the gate is live:
# obsolete (< min) / future (> current) / malformed / missing -> `err
# ImportFailed` (fatal). When a schema bump ships, a registered migration
# transforms the raw string up to current BEFORE the parser runs (the migration
# engine operates on the raw data string; the parser then reads the migrated
# result — the wiring is honest even though inert at v0).
#
# Round-trip invariant: `exportTheme(importTheme(exportTheme(t, fmt), fmt),
# fmt) == exportTheme(t, fmt)` — byte-identical, because
# `gamutMap(oklch -> oklch)` is identity (no hub drift) and the export is
# deterministic. The data formats are LOSSLESS -> no warnings.
#
# Parsing is hand-rolled (mirrors the exporter, which hand-rolls to control key
# order). Scope: the UniColor-emitted format + reasonable third-party variants
# of the same flat key-value structure. Full third-party TOML/YAML (arrays,
# nested tables, multi-line strings, anchors) is OUT OF SCOPE — these formats
# carry a theme token tree, which is a flat role -> value map; a parser for
# arbitrary data files is YAGNI. Malformed structure -> `err` (ImportFailed for
# the gate / structural, InvalidColor for an unparseable color value, InvalidOp
# from reconstruct for an empty source). `opts.strict` is honored where it
# matters (readColorOrSkip wraps the read). No RNG, no I/O. `import` is a Nim
# keyword -> quoted import.
#
# Layer: import (consumer of parse_color + reconstruct + schema + registry).
import std/strutils
import std/tables
import std/options
import UniColor/core/result
import UniColor/core/core # Color.
import UniColor/core/color_error
import UniColor/theme/tree # ThemeToken.
import UniColor/core/parse_color # parseColor.
import "UniColor/import/schema" # migrateData (gate + migration pipeline).
import "UniColor/import/reconstruct" # ReconstructInput / reconstruct / defaultReconstructInput.
import "UniColor/import/partial" # PartialCollector / readColorOrSkip / setRoleDedup.
import "UniColor/import/registry" # Importer / ImportReport / ImportOpts / registerImporter.

# A flat layer extracted from any of the three formats: (role, value). For
# primitives the value is the color string (parseColor reads it); for
# semantics/components the value is the raw alias target name (preserved
# verbatim for the lossless round-trip).
type FlatLayer = seq[(string, string)]

# Build the ImportReport from the extracted layers. Primitive color strings are
# parsed via `parseColor`; partial failure wraps the read: best-effort
# (`opts.strict = false`, default) SKIPS an unreadable color + `warnInvalidToken`
# + continues (partial theme + report); strict hard-fails with `err
# InvalidColor`. Primitives are deduped via `setRoleDedup` (a duplicate role
# with a DIFFERENT color -> last-wins + `warnDuplicateRole`; same color re-set =
# idempotent, no warning). Semantics/components carry the raw alias target; they
# are deduped last-wins WITHOUT a warning (an alias duplicate is a name
# re-target, not a color conflict — and the lossless UniColor export never
# duplicates a role). Delegates to `reconstruct`. The schema gate already ran in
# the format parser via `migrateData`; `schemaVersion` is the version read from
# the source (reported back). The data formats are LOSSLESS -> NO `warnInfoLost`
# (only the collector's skip/duplicate warnings flow through). Defined BEFORE
# the format parsers (Nim resolves a proc only after its definition point within
# a module).
proc assemble(formatName, schemaVersion: string, prims, sems, comps: FlatLayer,
    opts: ImportOpts, coll: var PartialCollector): Result[ImportReport,
    ColorError] {.raises: [].} =
  var inp = defaultReconstructInput()
  inp.schemaVersion = schemaVersion
  var primColors: Table[string, Color]
  for (role, col) in prims:
    let cR = parseColor(col)
    let sR = readColorOrSkip(cR, role, formatName, opts, coll)
    if sR.isErr:
      return err[ImportReport, ColorError](sR.error)
    if sR.get.isSome:
      setRoleDedup(primColors, role, sR.get.get, formatName, coll)
  for role, col in pairs(primColors):
    inp.primitives.add(ThemeToken(name: role, color: col))
  # Alias layers: last-wins dedup (no warning — an alias re-target is not a
  # color conflict).
  var semSeen: Table[string, string]
  for (role, tgt) in sems:
    semSeen[role] = tgt
  for role, tgt in pairs(semSeen):
    inp.semantics.add(ThemeToken(name: role, alias: tgt))
  var compSeen: Table[string, string]
  for (role, tgt) in comps:
    compSeen[role] = tgt
  for role, tgt in pairs(compSeen):
    inp.components.add(ThemeToken(name: role, alias: tgt))
  let rR = reconstruct(inp)
  if rR.isErr:
    return err[ImportReport, ColorError](rR.error)
  ok[ImportReport, ColorError](ImportReport(target: rR.get,
      formatName: formatName, schemaVersion: schemaVersion,
      warnings: coll.warnings))

# Read a JSON string starting just after the opening `"` at index `start`.
# Handles `\"` `\\` `\/` `\n` `\t` escapes (the exporter escapes only `"` and
# `\`, but the common escapes are honored for third-party robustness). Returns
# the unescaped content and the index AFTER the closing `"`.
proc readJsonString(s: string, start: int): tuple[val: string,
    nextIdx: int] {.raises: [].} =
  result.val = ""
  result.nextIdx = start
  var i = start
  while i < s.len:
    let ch = s[i]
    if ch == '\\':
      if i + 1 < s.len:
        case s[i + 1]
        of '"': result.val.add('"')
        of '\\': result.val.add('\\')
        of '/': result.val.add('/')
        of 'n': result.val.add('\n')
        of 't': result.val.add('\t')
        of 'r': result.val.add('\r')
        else: result.val.add(s[i + 1]) # best-effort: drop the backslash.
        inc i, 2
      else:
        inc i
    elif ch == '"':
      result.nextIdx = i + 1
      return
    else:
      result.val.add(ch)
      inc i
  result.nextIdx = i # unterminated — return what we have.

# Find the matching `}` for the `{` at `openIdx`, counting braces and skipping
# string literals. Returns -1 if unbalanced. The data objects are flat (no
# nesting) in the UniColor format, but brace counting stays correct for
# third-party nested inputs.
proc findMatchingBrace(s: string, openIdx: int): int {.raises: [].} =
  var depth = 0
  var i = openIdx
  var inStr = false
  while i < s.len:
    let ch = s[i]
    if inStr:
      if ch == '\\':
        inc i, 2
        continue
      elif ch == '"':
        inStr = false
    else:
      if ch == '"':
        inStr = true
      elif ch == '{':
        inc depth
      elif ch == '}':
        dec depth
        if depth == 0:
          return i
    inc i
  -1

# Extract the body (between `{` and matching `}`) of the JSON object for
# `section`, or "" if the section is absent.
proc jsonSection(s, section: string): string {.raises: [].} =
  let key = "\"" & section & "\":"
  let idx = s.find(key)
  if idx < 0:
    return ""
  let bo = s.find('{', idx + key.len)
  if bo < 0:
    return ""
  let bc = findMatchingBrace(s, bo)
  if bc < 0:
    return ""
  s[bo + 1 ..< bc]

# Parse a JSON object body into (role, value) pairs. Scans `"key": "value"`
# pairs; skips stray non-string tokens (defensive — the format is pairs only).
proc jsonPairs(body: string): FlatLayer {.raises: [].} =
  var i = 0
  while i < body.len:
    while i < body.len and body[i] != '"':
      inc i
    if i >= body.len:
      break
    inc i # past the opening `"` of the key.
    let (key, ni) = readJsonString(body, i)
    i = ni
    while i < body.len and body[i] != ':':
      inc i
    inc i # past `:`.
    while i < body.len and body[i] != '"':
      inc i
    if i >= body.len:
      break
    inc i # past the opening `"` of the value.
    let (val, ni2) = readJsonString(body, i)
    if key.len > 0:
      result.add((key, val))
    i = ni2

# Extract the schemaVersion from a JSON source (the `"schemaVersion": "..."`
# top-level value). Returns "" if absent (the gate then rejects it as
# malformed).
proc jsonSchemaVersion(s: string): string {.raises: [].} =
  let key = "\"schemaVersion\":"
  let idx = s.find(key)
  if idx < 0:
    return ""
  let q = s.find('"', idx + key.len)
  if q < 0:
    return ""
  let (v, _) = readJsonString(s, q + 1)
  v

proc jsonParse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  let schemaVersion = jsonSchemaVersion(input)
  let mR = migrateData(schemaVersion, input) # gate + migration (INERT at v0).
  if mR.isErr:
    return err[ImportReport, ColorError](mR.error)
  let src = mR.get
  let prims = jsonPairs(jsonSection(src, "primitives"))
  let sems = jsonPairs(jsonSection(src, "semantics"))
  let comps = jsonPairs(jsonSection(src, "components"))
  var coll: PartialCollector
  assemble("json", schemaVersion, prims, sems, comps, opts, coll)

# --- TOML --------------------------------------------------------------
# Extract the value of a TOML `key = "value"` or `key = bare` line. Returns
# ("", "") if no `=` found.
proc tomlKeyValue(line: string): (string, string) {.raises: [].} =
  let eq = line.find('=')
  if eq < 0:
    return ("", "")
  var key = line[0 ..< eq].strip()
  if key.len >= 2 and key[0] == '"' and key[^1] == '"':
    key = key[1 ..< ^1] # quoted key -> unquote.
  var val = line[eq + 1 ..< line.len].strip()
  if val.len >= 2 and val[0] == '"' and val[^1] == '"':
    val = val[1 ..< ^1] # quoted value -> unquote.
  (key, val)

proc tomlParse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  # schemaVersion is the first `schemaVersion = "..."` line.
  var schemaVersion = ""
  var prims: FlatLayer = @[]
  var sems: FlatLayer = @[]
  var comps: FlatLayer = @[]
  var section = 0 # 0 none, 1 prims, 2 sems, 3 comps.
  for line in input.splitLines():
    let s = line.strip()
    if s.len == 0 or s.startsWith('#'):
      continue
    if s == "[primitives]":
      section = 1
      continue
    if s == "[semantics]":
      section = 2
      continue
    if s == "[components]":
      section = 3
      continue
    if s.startsWith("schemaVersion"):
      let (k, v) = tomlKeyValue(s)
      if k == "schemaVersion":
        schemaVersion = v
      continue
    let (key, val) = tomlKeyValue(s)
    if key.len == 0:
      continue
    case section
    of 1: prims.add((key, val))
    of 2: sems.add((key, val))
    of 3: comps.add((key, val))
    else: discard # top-level key we don't carry (e.g. name) — ignore.
  let mR = migrateData(schemaVersion, input)
  if mR.isErr:
    return err[ImportReport, ColorError](mR.error)
  # The gate ran via migrateData; at v0 the migration is identity, so the layers
  # extracted above are already the migrated view. Assemble the report.
  var coll: PartialCollector
  assemble("toml", schemaVersion, prims, sems, comps, opts, coll)

# --- YAML --------------------------------------------------------------
# Extract the value of a YAML `  role: value` entry. Returns ("", "") if no
# `: ` found. Strips surrounding quotes from the value if present (the exporter
# quotes color strings; alias targets are bare).
proc yamlKeyValue(line: string): (string, string) {.raises: [].} =
  let sep = line.find(": ")
  if sep < 0:
    return ("", "")
  let key = line[0 ..< sep].strip()
  var val = line[sep + 2 ..< line.len].strip()
  if val.len >= 2 and val[0] == '"' and val[^1] == '"':
    val = val[1 ..< ^1]
  (key, val)

proc yamlParse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  var schemaVersion = ""
  var prims: FlatLayer = @[]
  var sems: FlatLayer = @[]
  var comps: FlatLayer = @[]
  var section = 0
  for line in input.splitLines():
    if line.strip().len == 0 or line.strip().startsWith('#'):
      continue
    # A section header is a non-indented line ending with `:` (e.g.
    # `primitives:`).
    if not line.startsWith(' ') and line.endsWith(':'):
      let name = line[0 ..< ^1].strip()
      if name == "primitives": section = 1
      elif name == "semantics": section = 2
      elif name == "components": section = 3
      else: section = 0
      continue
    let (key, val) = yamlKeyValue(line.strip())
    if key == "schemaVersion":
      schemaVersion = val
      continue
    if key.len == 0:
      continue
    case section
    of 1: prims.add((key, val))
    of 2: sems.add((key, val))
    of 3: comps.add((key, val))
    else: discard
  let mR = migrateData(schemaVersion, input)
  if mR.isErr:
    return err[ImportReport, ColorError](mR.error)
  var coll: PartialCollector
  assemble("yaml", schemaVersion, prims, sems, comps, opts, coll)

# Bootstrap — register "json", "toml", "yaml". Fired by the facade
# `import "UniColor/import/formats_data"`.
discard registerImporter(Importer(name: "json", parse: jsonParse))
discard registerImporter(Importer(name: "toml", parse: tomlParse))
discard registerImporter(Importer(name: "yaml", parse: yamlParse))
