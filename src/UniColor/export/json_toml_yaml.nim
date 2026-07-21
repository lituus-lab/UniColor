# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# export/json_toml_yaml — data-export theme formats, registered as "json",
# "toml", "yaml". These are the CANONICAL round-trip formats: the import side
# reads them back. They carry the `schemaVersion` (from core/schema) so a reader
# can validate the range [min, current] and migrate older versions.
#
# Unlike the textual exporters (css/tailwind/nix/lua) which flatten the tree to
# RESOLVED colors, the data exports PRESERVE the ALIAS STRUCTURE — primitives
# carry the color string (`formatColorCss`, gamut-mapped into the target space),
# semantics + components carry the raw alias TARGET NAME (the string, not the
# resolved color) so the import reconstructs the exact token tree. This is the
# key distinction from a textual dump.
#
# Lossless (full tree projected — every primitive/semantic/component role
# emitted) -> NO `warnInfoLost`. `warnings` always `@[]`.
#
# Dotted role names (e.g. `text.primary`): JSON object keys are strings (dots
# fine inside quotes); TOML keys with a dot MUST be quoted (`"text.primary" =`);
# YAML accepts bare dotted keys. Determinism via the serialize layer's
# `orderedRoles` (primitive->semantic->component, sorted within layer) ->
# byte-identical, independent of theme insertion order. All three formats are
# hand-rolled (no std/json/toml/yaml parsers) so the key order is deterministic
# and matches `orderedRoles` — library parsers don't guarantee key order.
#
# Self-registers via `discard registerExporter(...)`; the facade
# `export/export.nim` imports this module to fire it.
#
# Layer: export (consumer of serialize + registry + core/schema + conversion +
# theme).
import std/strutils
import std/tables
import UniColor/core/core # Color, SpaceTag, tagSrgb, tagOklch.
import UniColor/core/result
import UniColor/core/color_error
import UniColor/core/schema # currentSchemaVersion.
import UniColor/conversion/conversion # gamutMap.
import UniColor/theme/tree
import "UniColor/export/serialize"
import "UniColor/export/registry"

# The three ordered layers of the data model: (role, color-string) for
# primitives, (role, alias-target-name) for semantics and components. Built in
# `orderedRoles` order so the export is deterministic. Color strings come from
# `formatColorCss` on the gamut-mapped color; alias strings are the RAW alias
# target (preserved for round-trip, NOT resolved).
type
  DataModel = object
    prims: seq[(string, string)] # role -> color string (formatColorCss).
    sems: seq[(string, string)]  # role -> alias target name (raw).
    comps: seq[(string, string)] # role -> alias target name (raw).

proc buildDataModel(t: Theme, opts: ExportOpts): Result[DataModel,
    ColorError] {.raises: [].} =
  ## Walk `orderedRoles(t)`; primitives gamut-map + formatColorCss,
  ## semantics/components carry the raw alias target name. Returns the model or
  ## a gamut-map error.
  let target = if opts.legacySrgb: tagSrgb else: tagOklch
  var m: DataModel
  for (role, layer) in orderedRoles(t):
    case layer
    of tlPrimitive:
      let gR = gamutMap(t.prims.getOrDefault(role), target)
      if gR.isErr:
        return err[DataModel, ColorError](gR.error)
      m.prims.add((role, formatColorCss(gR.get, opts.legacySrgb)))
    of tlSemantic:
      m.sems.add((role, t.sems.getOrDefault(role)))
    of tlComponent:
      m.comps.add((role, t.comps.getOrDefault(role)))
  ok[DataModel, ColorError](m)

proc jsonEsc(s: string): string {.raises: [].} =
  ## Minimal JSON string escape (`"` and `\`). Role names and CSS color strings
  ## don't contain these in practice, but escape for correctness so the output
  ## is always valid JSON.
  result = ""
  for ch in s:
    if ch == '"': result.add("\\\"")
    elif ch == '\\': result.add("\\\\")
    else: result.add(ch)

proc jsonRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let mR = buildDataModel(theme, opts)
  if mR.isErr:
    return err[ExportReport, ColorError](mR.error)
  let m = mR.get
  let target = if opts.legacySrgb: tagSrgb else: tagOklch
  let sopts = SerializeOpts(target: target, legacySrgb: opts.legacySrgb)
  var lines: seq[string]
  lines.add("{")
  lines.add("  \"//\": \"" & jsonEsc(genHeader("json", sopts)) & "\",")
  lines.add("  \"schemaVersion\": \"" & currentSchemaVersion & "\",")
  lines.add("  \"name\": \"UniColor\",")
  # primitives object.
  lines.add("  \"primitives\": {")
  var primEntries: seq[string]
  for (role, col) in m.prims:
    primEntries.add("    \"" & jsonEsc(role) & "\": \"" & jsonEsc(col) & "\"")
  lines.add(primEntries.join(",\n"))
  lines.add("  },")
  # semantics object.
  lines.add("  \"semantics\": {")
  var semEntries: seq[string]
  for (role, alias) in m.sems:
    semEntries.add("    \"" & jsonEsc(role) & "\": \"" & jsonEsc(alias) & "\"")
  lines.add(semEntries.join(",\n"))
  lines.add("  },")
  # components object.
  lines.add("  \"components\": {")
  var compEntries: seq[string]
  for (role, alias) in m.comps:
    compEntries.add("    \"" & jsonEsc(role) & "\": \"" & jsonEsc(alias) & "\"")
  lines.add(compEntries.join(",\n"))
  lines.add("  }")
  lines.add("}")
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: @[]))

proc tomlKey(role: string): string {.raises: [].} =
  ## TOML keys with a dot (or other non-bare char) MUST be quoted; bare keys stay
  ## bare (idiomatic).
  if '.' in role: "\"" & role & "\"" else: role

proc tomlRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let mR = buildDataModel(theme, opts)
  if mR.isErr:
    return err[ExportReport, ColorError](mR.error)
  let m = mR.get
  let target = if opts.legacySrgb: tagSrgb else: tagOklch
  let sopts = SerializeOpts(target: target, legacySrgb: opts.legacySrgb)
  var lines: seq[string]
  lines.add("# " & genHeader("toml", sopts)) # TOML comment.
  lines.add("schemaVersion = \"" & currentSchemaVersion & "\"")
  lines.add("name = \"UniColor\"")
  lines.add("")
  lines.add("[primitives]")
  for (role, col) in m.prims:
    lines.add(tomlKey(role) & " = \"" & col & "\"")
  lines.add("")
  lines.add("[semantics]")
  for (role, alias) in m.sems:
    lines.add(tomlKey(role) & " = \"" & alias & "\"")
  lines.add("")
  lines.add("[components]")
  for (role, alias) in m.comps:
    lines.add(tomlKey(role) & " = \"" & alias & "\"")
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: @[]))

proc yamlRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  let mR = buildDataModel(theme, opts)
  if mR.isErr:
    return err[ExportReport, ColorError](mR.error)
  let m = mR.get
  let target = if opts.legacySrgb: tagSrgb else: tagOklch
  let sopts = SerializeOpts(target: target, legacySrgb: opts.legacySrgb)
  var lines: seq[string]
  lines.add("# " & genHeader("yaml", sopts)) # YAML comment.
  lines.add("schemaVersion: \"" & currentSchemaVersion & "\"") # quoted -> string.
  lines.add("name: UniColor")
  lines.add("primitives:")
  for (role, col) in m.prims:
    lines.add("  " & role & ": \"" & col & "\"") # color quoted (spaces/parens).
  lines.add("semantics:")
  for (role, alias) in m.sems:
    lines.add("  " & role & ": " & alias) # alias target bare (no special chars).
  lines.add("components:")
  for (role, alias) in m.comps:
    lines.add("  " & role & ": " & alias)
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: @[]))

# Bootstrap — register "json", "toml", "yaml". Fired by
# `import "UniColor/export/json_toml_yaml"`.
discard registerExporter(Exporter(name: "json", render: jsonRender))
discard registerExporter(Exporter(name: "toml", render: tomlRender))
discard registerExporter(Exporter(name: "yaml", render: yamlRender))
