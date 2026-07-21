# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# import/formats_css — CSS-vars importer, registered as "css". The mirror of
# export/css: it parses `:root { --role: <color>; ... }` back into the token
# tree via the shared `reconstruct`.
#
# CSS export FLATTENS the alias structure — every role (primitive, semantic,
# component) is emitted with its RESOLVED color (the alias pointer is gone).
# So this importer reconstructs a Theme of ALL PRIMITIVES: the role->color
# mapping is preserved (a color-level round-trip), but the semantic/component
# alias layers are lost (a structure-level loss). This is the honest behavior
# of a CSS-vars round-trip — the byte-identical round-trip invariant holds only
# for the lossless data formats (json/toml/yaml/nix/lua), NOT for CSS.
#
# `parseColor` reads each color value, returning a Color tagged by its native
# space (oklch -> tagOklch, hex -> tagSrgb) — no conversion, the color is what
# the source says. The UniColor generation header, if present, carries the
# `schemaVersion` (read only when the `UniColor` guard is present, mirroring
# sniff — a coincidental `schema: ` in a role name cannot spoof it). A
# `@media (prefers-color-scheme: dark)` block is real information dropped (the
# import models a single light theme — `ReconstructInput` has no dark slot),
# so a `warnInfoLost` warning is emitted rather than a silent drop.
#
# Error model: a malformed color value is a HARD error (`err InvalidColor`) in
# both strict and best-effort modes — it is unrecoverable (the importer cannot
# guess the color). The partial-failure collection framework (skip-and-warn per
# bad token, order-stable warning list) wraps this importer via
# `readColorOrSkip` / `setRoleDedup`. An empty source (no `:root` block or no
# declarations) -> `reconstruct` returns `err InvalidOp` (no roles, no bare
# colors).
#
# Deterministic: no RNG, no I/O. `import` is a Nim keyword -> quoted import.
#
# Layer: import (consumer of parse_color + reconstruct + registry).
import std/strutils
import std/tables
import std/options
import UniColor/core/result
import UniColor/core/core # Color.
import UniColor/core/color_error
import UniColor/theme/tree # ThemeToken.
import UniColor/palette/unsatisfiable # PaletteWarning / warnInfoLost.
import UniColor/core/parse_color # parseColor.
import "UniColor/import/reconstruct" # ReconstructInput / reconstruct / defaultReconstructInput.
import "UniColor/import/partial" # PartialCollector / readColorOrSkip / setRoleDedup.
import "UniColor/import/registry" # Importer / ImportReport / ImportOpts / registerImporter.

# Read the schemaVersion from the UniColor generation header. Only trusted when
# the `UniColor` guard is present (mirrors sniff): a coincidental `schema: `
# inside a role name (e.g. `--schema: ...`) cannot spoof the version. Reads
# alnum + `.` + `-` after `schema: `.
proc readSchemaVersion(input: string): string {.raises: [].} =
  if "UniColor" notin input:
    return ""
  let idx = input.find("schema: ")
  if idx < 0:
    return ""
  result = ""
  var i = idx + "schema: ".len
  while i < input.len and input[i] in {'a'..'z', 'A'..'Z', '0'..'9', '.', '-'}:
    result.add(input[i])
    inc i

# Parse one `:root { ... }` block's declarations into a role->color Table
# (last-wins dedup via `setRoleDedup`). `body` is the text between the block's
# braces. Each declaration is `--role: <value>;` — split on `;`, take chunks
# starting with `--`, split on the first `: ` for role/value. Partial failure:
# a malformed color value is SKIPPED + `warnInvalidToken` in best-effort mode
# (`opts.strict = false`, default — the import continues, partial theme +
# report); in strict mode it hard-fails with `err InvalidColor`. An empty role
# name is skipped (defensive). Returns `err` ONLY in strict mode (when
# readColorOrSkip propagates the InvalidColor); best-effort never returns err
# here.
proc parseRootBlock(body: string, opts: ImportOpts,
    coll: var PartialCollector): Result[Table[string, Color],
        ColorError] {.raises: [].} =
  var roleColors: Table[string, Color]
  for chunk in body.split(';'):
    let s = chunk.strip()
    if not s.startsWith("--"):
      continue
    let sep = s.find(": ")
    if sep < 0:
      continue
    let role = s[2 ..< sep] # drop the leading `--`.
    if role.len == 0:
      continue
    let val = s[sep + 2 ..< s.len].strip()
    let cR = parseColor(val)
    let sR = readColorOrSkip(cR, role, "css", opts, coll)
    if sR.isErr:
      return err[Table[string, Color], ColorError](sR.error)
    if sR.get.isSome:
      setRoleDedup(roleColors, role, sR.get.get, "css", coll)
  ok[Table[string, Color], ColorError](roleColors)

# Find the text of the FIRST `:root { ... }` block in `section`. Returns "" if
# there is no `:root`. The block's braces do not nest (CSS vars hold only
# declarations), so the closing brace is the first `}` after the opening `{`.
proc firstRootBody(section: string): string {.raises: [].} =
  let rs = section.find(":root")
  if rs < 0:
    return ""
  let bo = section.find('{', rs)
  if bo < 0:
    return ""
  let bc = section.find('}', bo)
  if bc < 0:
    return ""
  section[bo + 1 ..< bc]

proc cssParse(input: string, opts: ImportOpts): Result[ImportReport,
    ColorError] {.raises: [].} =
  ## Registered parse: read the CSS-vars source, reconstruct an all-primitive
  ## Theme, return the report. Partial failure: `opts.strict = false` (default)
  ## skips an unreadable color token + `warnInvalidToken` + continues (partial
  ## theme + report); `strict = true` hard-fails with `err InvalidColor`. The
  ## dark-mode @media block (if present) is dropped with a `warnInfoLost`
  ## warning (non-silent). A duplicate `--role` with a DIFFERENT color ->
  ## last-wins + `warnDuplicateRole`; same color re-set is idempotent (no
  ## warning).
  let schemaVersion = readSchemaVersion(input)
  # The light theme is everything BEFORE the dark @media block (UniColor export
  # emits light :root first, then @media). The dark block's :root is excluded
  # from light parsing.
  let darkMarker = "@media (prefers-color-scheme: dark)"
  let darkPresent = darkMarker in input
  let lightSection = if darkPresent: input[0 ..< input.find(
      darkMarker)] else: input
  let body = firstRootBody(lightSection)
  var coll: PartialCollector
  let tR = parseRootBlock(body, opts, coll)
  if tR.isErr:
    return err[ImportReport, ColorError](tR.error)
  var inp = defaultReconstructInput()
  inp.schemaVersion = schemaVersion
  for role, col in pairs(tR.get):
    inp.primitives.add(ThemeToken(name: role, color: col))
  let rR = reconstruct(inp)
  if rR.isErr:
    return err[ImportReport, ColorError](rR.error)
  var warnings: seq[PaletteWarning] = @[]
  if darkPresent:
    warnings.add(PaletteWarning(code: warnInfoLost,
        message: "css: dark-mode @media block dropped (import models a single light theme)",
        context: "css"))
  warnings.add(coll.warnings)
  ok[ImportReport, ColorError](ImportReport(target: rR.get, formatName: "css",
      schemaVersion: schemaVersion, warnings: warnings))

# Bootstrap — register "css". Fired by the facade
# `import "UniColor/import/formats_css"`.
discard registerImporter(Importer(name: "css", parse: cssParse))
