# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# export/serialize — stable order + header gen + gamut map at export.
#
# Shared helper for the format exporters (CSS-vars, Tailwind, IDE, terminals).
# The theme's three layers live in `Table[string, ...]` (hash tables), whose
# iteration order is NOT insertion-stable in Nim — so a naive walk would leak
# hash-bucket order and break byte-identical exports. This module flattens the
# tree DETERMINISTICALLY:
#   - layer-grouped: primitive -> semantic -> component (the resolution order);
#   - sorted by role name within each layer (`std/algorithm.sort` on a string
#     seq).
# Every resolved color is gamut-mapped into the export target space (CSS Color
# 4): OKLCH is unbounded -> `gamutMap` returns the origin unchanged; sRGB is
# bounded -> chroma is reduced just enough to land in gamut (L and h
# preserved). Alias tokens (semantic/component) resolve to their primitive's
# gamut-mapped color via `Theme.resolve`. Textual exports prepend `genHeader`
# (UniColor version + format + target + schema) for traceability.
#
# Determinism: no RNG, no I/O, no thread state. `serializeTheme` is a pure
# function of (theme, opts) — bit-identical across calls and across insertion
# orders of the same role set.
#
# `ucExportVersion` duplicates `UniColorVersion` (UniColor.nim) to avoid a
# circular import — UniColor imports the export module, so serialize cannot
# import UniColor. The test asserts the two stay in sync.
#
# Layer: export (consumer of theme + conversion + core/schema).
import std/algorithm
import std/tables
import std/strutils
import UniColor/core/core # Color, SpaceTag, spaceName.
import UniColor/core/result
import UniColor/core/color_error
import UniColor/core/schema # currentSchemaVersion.
import UniColor/conversion/conversion # gamutMap.
import UniColor/theme/tree

const ucExportVersion* = "1.1.0" ## UniColor version, written into every export
                                 ## header for traceability. Mirrors
                                 ## `UniColorVersion` (UniColor.nim). Duplicated
                                 ## here to avoid a circular import; the test
                                 ## asserts the two sync.

type
  TokenLayer* {.pure.} = enum
    tlPrimitive, tlSemantic, tlComponent

  RoleColor* = object
    ## One flattened node of the export sequence. For a primitive, `color` is
    ## the gamut-mapped raw color and `alias` is "". For a semantic/component,
    ## `color` is the RESOLVED primitive color (gamut-mapped) and `alias` is
    ## the target role name.
    role*: string
    layer*: TokenLayer
    color*: Color
    alias*: string

  SerializeOpts* = object
    target*: SpaceTag ## gamut target (e.g. `tagOklch` default, `tagSrgb`
                      ## legacy). Colors are gamut-mapped into this space at
                      ## export (CSS Color 4).
    legacySrgb*: bool ## mirrors `ExportOpts.legacySrgb` (cross-cutting knob).
                      ## When true the export emits sRGB (target should be
                      ## `tagSrgb`); when false OKLCH (`tagOklch`).

proc defaultSerializeOpts*(): SerializeOpts {.raises: [].} =
  ## OKLCH default (no gamut loss; the modern CSS Color 4 path).
  SerializeOpts(target: tagOklch, legacySrgb: false)

proc fmtF*(f: float32, decimals = 4): string {.raises: [].} =
  ## Fixed-decimal float formatting (deterministic — same bits -> same string).
  ## Used for OKLCH comps; the serialize layer gamut-maps to exact bits, and
  ## `formatFloat(ffDecimal, n)` renders those bits identically every call.
  ## Shared by every CSS-syntax exporter (CSS vars, Tailwind, IDE).
  formatFloat(f.float64, ffDecimal, decimals)

proc hexByte*(c: float32): string {.raises: [].} =
  ## A sRGB component in [0,1] -> 2-digit lowercase hex (0-255). Rounded,
  ## clamped to [0,255]. Shared by every exporter that emits hex (CSS legacy,
  ## Tailwind legacy, Base16, terminals).
  var n = int(c.float64 * 255.0 + 0.5)
  if n < 0: n = 0
  if n > 255: n = 255
  toHex(n, 2).toLowerAscii()

proc formatColorCss*(c: Color, legacySrgb: bool): string {.raises: [].} =
  ## Render a resolved color (already in the export target space from
  ## `serializeTheme`) as a CSS color string. OKLCH: `oklch(L C h)` (+ ` / a`
  ## inside the parens if alpha < 1 — CSS Color 4). sRGB legacy: `#rrggbb`
  ## (+ `aa` if alpha < 1). The space tag matches `legacySrgb` because
  ## serializeTheme was called with the matching target. Shared by every
  ## CSS-syntax exporter (CSS vars, Tailwind, IDE). DRY: one formatter.
  let a = c.alpha()
  if legacySrgb:
    let (c0, c1, c2) = c.components
    result = "#" & hexByte(c0) & hexByte(c1) & hexByte(c2)
    if a < 1.0'f32:
      result.add(hexByte(a))
  else:
    let (l, cc, h) = c.components
    result = "oklch(" & fmtF(l) & " " & fmtF(cc) & " " & fmtF(h)
    if a < 1.0'f32:
      result.add(" / " & fmtF(a))
    result.add(")")

proc orderedRoles*(t: Theme): seq[(string, TokenLayer)] {.raises: [].} =
  ## The deterministic flat order of the theme's roles: primitive -> semantic
  ## -> component, sorted by role name within each layer. Independent of
  ## hash-table insertion order. This is the order every format exporter emits
  ## (byte-identical exports).
  var
    ps: seq[string]
    ss: seq[string]
    cs: seq[string]
  for k, _ in t.prims.pairs: ps.add(k)
  for k, _ in t.sems.pairs: ss.add(k)
  for k, _ in t.comps.pairs: cs.add(k)
  ps.sort()
  ss.sort()
  cs.sort()
  for name in ps: result.add((name, tlPrimitive))
  for name in ss: result.add((name, tlSemantic))
  for name in cs: result.add((name, tlComponent))

proc serializeTheme*(t: Theme, opts = defaultSerializeOpts()): Result[
    seq[RoleColor], ColorError] {.raises: [].} =
  ## Build the deterministic export sequence: every role in `orderedRoles`
  ## order, each resolved color gamut-mapped into `opts.target`. Primitive
  ## tokens carry their own color; semantic and component tokens carry the
  ## resolved primitive color (via `Theme.resolve`) plus the alias target
  ## name. An unresolvable alias -> `err UnresolvedRole` (no silent skip); a
  ## gamut-map failure -> the underlying error. Pure / deterministic: the same
  ## (theme, opts) yields a bit-identical seq every call.
  var outSeq: seq[RoleColor]
  for (name, layer) in orderedRoles(t):
    var
      resolvedAlias: string
      origin: Color
    case layer
    of tlPrimitive:
      origin = t.prims.getOrDefault(name)
    of tlSemantic:
      resolvedAlias = t.sems.getOrDefault(name)
    of tlComponent:
      resolvedAlias = t.comps.getOrDefault(name)
    if layer != tlPrimitive:
      let rR = t.resolve(name)
      if rR.isErr:
        return err[seq[RoleColor], ColorError](rR.error)
      origin = rR.get
    let gR = gamutMap(origin, opts.target)
    if gR.isErr:
      return err[seq[RoleColor], ColorError](gR.error)
    outSeq.add(RoleColor(role: name, layer: layer, color: gR.get,
        alias: resolvedAlias))
  ok[seq[RoleColor], ColorError](outSeq)

proc genHeader*(formatName: string, opts = defaultSerializeOpts()): string {.
    raises: [].} =
  ## Generation header for a textual export: `Generated by UniColor <version>
  ## | format: <name> | target: <space> | schema: <version>`. The target name
  ## is the space's own name (`spaceName(opts.target)`), so the header reports
  ## what was actually gamut-mapped. Deterministic (same args -> same string).
  ## The format exporter prepends this as a comment in its own syntax (e.g.
  ## `/* ... */` for CSS, `# ...` for terminal/Xresources). Built with `.add`
  ## per segment so nimpretty never collapses a `& <identifier>` at a line
  ## wrap.
  result = "Generated by UniColor " & ucExportVersion
  result.add(" | format: " & formatName)
  result.add(" | target: " & spaceName(opts.target))
  result.add(" | schema: " & currentSchemaVersion)
