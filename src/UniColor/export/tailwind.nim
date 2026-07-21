# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# export/tailwind — Tailwind v4 `@theme` exporter, registered as "tailwind".
# Emits `@theme { --color-<family>-<step>: <color>; ... }` from the theme's
# PRIMITIVE tokens (the tonal ramps). Tailwind's model is utility classes over
# color ramps (`bg-blue-500`), NOT semantic roles — semantics/components are
# not emitted (the user wires them in their own CSS from the ramp tokens).
# Primitives are grouped by family (the part before the last `.`) and the steps
# sorted NUMERICALLY within a family (50, 100, 200, …, 950 — lexicographic would
# give 100, 200, 50, 950). Families sorted alphabetically. OKLCH default
# (CSS Color 4) / sRGB legacy (`#rrggbb` hex). `opts.dark` emits a second
# `@theme` block for the dark theme. Same (theme, opts) -> byte-identical.
#
# Why primitives-only (not serializeTheme): serializeTheme resolves ALL layers
# and orders layer-grouped. Tailwind wants primitives only, family-grouped with
# numeric step order — a different structure. So this exporter walks `t.prims`
# directly, gamut-mapping each primitive (a dangling semantic is never touched —
# the export succeeds; that is the documented behavior, not a silent skip).
#
# Self-registers via `discard registerExporter(...)`; the facade
# `export/export.nim` imports this module to fire it.
#
# Layer: export (consumer of serialize + registry + conversion + theme).
import std/algorithm
import std/strutils
import std/options
import std/tables # Table.pairs.
import UniColor/core/core # Color, SpaceTag, tagSrgb, tagOklch.
import UniColor/core/result
import UniColor/core/color_error
import UniColor/conversion/conversion # gamutMap.
import UniColor/theme/tree
import "UniColor/export/serialize"
import "UniColor/export/registry"

type FamilyStep = tuple[family: string, step: string, stepNum: int,
    name: string, color: Color]

proc stepSortKey(step: string): int {.raises: [].} =
  ## Numeric sort key for a step: the parsed int if the step is a plain integer,
  ## else `high(int)` so non-numeric steps sort AFTER numeric ones (alphabetical
  ## among themselves via a stable sort on the string). Tailwind steps are 50,
  ## 100, …, 950 (all integers).
  try:
    parseInt(step)
  except ValueError:
    high(int)

proc tailwindBlock(t: Theme, opts: ExportOpts): Result[string,
    ColorError] {.raises: [].} =
  ## One `@theme { ... }` block for `t`'s primitives, gamut-mapped into the
  ## target space, grouped by family with numeric step order. Returns the block
  ## text (no header) or a gamut error.
  let target = if opts.legacySrgb: tagSrgb else: tagOklch
  var entries: seq[FamilyStep]
  for name, col in t.prims.pairs:
    let gR = gamutMap(col, target)
    if gR.isErr:
      return err[string, ColorError](gR.error)
    let dot = name.rfind('.')
    if dot < 0:
      entries.add((family: name, step: "", stepNum: high(int), name: name,
          color: gR.get))
    else:
      let fam = name[0 ..< dot]
      let stp = name[dot + 1 ..^ 1]
      entries.add((family: fam, step: stp, stepNum: stepSortKey(stp),
          name: name, color: gR.get))
  # Family alphabetical, then numeric step ascending, then step string for a
  # stable tie-break.
  entries.sort(proc(a, b: FamilyStep): int =
    result = cmp(a.family, b.family)
    if result == 0: result = cmp(a.stepNum, b.stepNum)
    if result == 0: result = cmp(a.step, b.step))
  var lines: seq[string]
  lines.add("@theme {")
  for e in entries:
    let varName = if e.step.len == 0: "--color-" & e.family
                  else: "--color-" & e.family & "-" & e.step
    lines.add("  " & varName & ": " & formatColorCss(e.color,
        opts.legacySrgb) & ";")
  lines.add("}")
  ok[string, ColorError](lines.join("\n"))

proc tailwindRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  ## Registered render: header (CSS comment) + light `@theme` block + optional
  ## dark `@theme` block. Tailwind ramps are a LOSSLESS projection of the
  ## theme's primitives (every primitive is emitted), so `warnings` is empty
  ## here. A dangling semantic alias is never touched (primitives-only walk) —
  ## not an info loss, just skipped.
  let sopts = SerializeOpts(target: if opts.legacySrgb: tagSrgb else: tagOklch,
      legacySrgb: opts.legacySrgb)
  var outParts: seq[string]
  outParts.add("/* " & genHeader("tailwind", sopts) & " */")
  let lightR = tailwindBlock(theme, opts)
  if lightR.isErr:
    return err[ExportReport, ColorError](lightR.error)
  outParts.add(lightR.get)
  if opts.dark.isSome:
    let darkR = tailwindBlock(opts.dark.get, opts)
    if darkR.isErr:
      return err[ExportReport, ColorError](darkR.error)
    outParts.add(darkR.get) # a second @theme block for the dark theme.
  ok[ExportReport, ColorError](ExportReport(output: outParts.join("\n"),
      warnings: @[]))

# Bootstrap — register "tailwind". Fired by `import "UniColor/export/tailwind"`.
discard registerExporter(Exporter(name: "tailwind", render: tailwindRender))
