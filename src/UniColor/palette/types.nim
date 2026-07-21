# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# palette/types — `Palette` value type tagged by structure.
# A `Palette` is an IMMUTABLE value type (like `Color` is by space) carrying a
# color container, a structure tag, metadata (intent, seed), and an optional
# role map for Semantic. The tag governs which indexing operations are valid:
# `colorAt(i)` for the discrete structures, `sample(t)` for the ordered ramps
# (delegates to `interpolation.gradient`), `role(name)` for Semantic. Operations
# valid for the wrong tag return `InvalidOp` — fail fast at the type boundary,
# never silently coerce. There are no setters; transformations build a new
# `Palette`.
#
# Seven structures: Ordered (indexed ramp), Unordered (distinct, no order),
# Scientific (perceptually uniform + CVD-safe ramp), Terminal (ANSI projection),
# Categorical (unordered, more colors), Continuous (interpolator), Semantic
# (named by role). `intent` is metadata (qualitative/sequential/diverging/UI)
# orthogonal to the structure.
import std/tables
import UniColor/core/core
import UniColor/interpolation/interpolation # gradient/ColorStop/GradientOpts.

type
  PaletteTag* = enum
    palOrdered     ## indexed ramp (sequential, diverging, UI tonal scale).
    palUnordered   ## distinct colors, no order (qualitative).
    palScientific  ## perceptually uniform ramp + CVD-safe (viridis-like).
    palTerminal    ## projected on ANSI 16/256, ANSI order.
    palCategorical ## unordered variant, more colors (UI categories).
    palContinuous  ## interpolator (stops + function) — heatmap / gradient.
    palSemantic    ## colors named by role (theme tokens).

  PaletteIntent* = enum
    intentQualitative
    intentSequential
    intentDiverging
    intentUI
    intentScientific
    intentCategorical
    intentTerminal

  Palette* = object
    ## Immutable palette value (fields private — no setters; transformations
    ## build a new palette). `colors` is the discrete container (also the stops
    ## for `sample` on ordered ramps); `roles` maps a role name to an index into
    ## `colors` (Semantic only).
    colors: seq[Color]
    tag: PaletteTag
    intent: PaletteIntent
    seed: int64
    roles: Table[string, int]

# Public read-only accessors (no setters -> immutability is structural).
proc tag*(p: Palette): PaletteTag {.raises: [].} = p.tag
proc intent*(p: Palette): PaletteIntent {.raises: [].} = p.intent
proc seed*(p: Palette): int64 {.raises: [].} = p.seed
proc len*(p: Palette): int {.raises: [].} = p.colors.len
proc colors*(p: Palette): seq[Color] {.raises: [].} = p.colors

# Which structures admit each indexing mode.
func isDiscrete(t: PaletteTag): bool {.raises: [].} =
  t in {palOrdered, palUnordered, palScientific, palTerminal, palCategorical}

func isOrderedRamp(t: PaletteTag): bool {.raises: [].} =
  t in {palOrdered, palScientific, palContinuous}

proc palette*(tag: PaletteTag, colors: openArray[Color], intent: PaletteIntent,
    seed: int64, roles: Table[string, int] = initTable[string,
    int]()): Result[Palette, ColorError] {.raises: [].} =
  ## Construct an immutable `Palette`. Empty colors -> `InvalidOp`. For
  ## `Semantic`, every role index must be in range (else `InvalidColor` — a
  ## programming error in the role map). Roles are ignored for non-Semantic tags
  ## (the role map is a Semantic-only carrier).
  if colors.len == 0:
    return err[Palette, ColorError](colorError(InvalidOp,
        "palette: empty color set", "palette"))
  if tag == palSemantic:
    for name, idx in roles.pairs:
      if idx < 0 or idx >= colors.len:
        return err[Palette, ColorError](colorError(InvalidColor,
            "palette: role '" & name & "' index " & $idx &
            " out of range for " & $colors.len & " colors", "palette"))
  ok[Palette, ColorError](Palette(colors: @colors, tag: tag, intent: intent,
      seed: seed, roles: roles))

proc colorAt*(p: Palette, i: int): Result[Color, ColorError] {.raises: [].} =
  ## Discrete indexation for the five discrete structures. `InvalidOp` for
  ## `Continuous`/`Semantic` (use `sample`/`role`). Out-of-range -> `InvalidColor`.
  if not p.tag.isDiscrete:
    return err[Color, ColorError](colorError(InvalidOp,
        "colorAt: discrete index not valid for structure " & $p.tag, "colorAt"))
  if i < 0 or i >= p.colors.len:
    return err[Color, ColorError](colorError(InvalidColor,
        "colorAt: index " & $i & " out of range for " & $p.colors.len &
        " colors", "colorAt"))
  ok[Color, ColorError](p.colors[i])

proc sample*(p: Palette, t: float64): Result[Color, ColorError] {.raises: [].} =
  ## Ordered-ramp sampling. Valid for `Ordered`/`Scientific`/`Continuous`;
  ## delegates to `interpolation.gradient` with stops at positions `i/(n-1)`.
  ## `InvalidOp` for unordered structures (no order to sample). `t` must be in
  ## [0,1] (else `InvalidColor`). A single-color palette samples to itself.
  if not p.tag.isOrderedRamp:
    return err[Color, ColorError](colorError(InvalidOp,
        "sample: structure " & $p.tag & " is not an ordered ramp", "sample"))
  if t < 0.0 or t > 1.0:
    return err[Color, ColorError](colorError(InvalidColor,
        "sample: t must be in [0,1], got " & $t, "sample"))
  if p.colors.len == 1:
    return ok[Color, ColorError](p.colors[0])
  # Build evenly-spaced stops in [0,1] and delegate the blend (hue method,
  # premultiplied alpha, gamut map) to the interpolation module — reuse, not
  # reinvent.
  var stops: seq[ColorStop] = newSeq[ColorStop](p.colors.len)
  let denom = float32(p.colors.len - 1)
  for i in 0 ..< p.colors.len:
    stops[i] = ColorStop(color: p.colors[i], pos: float32(i) / denom)
  gradient(stops, t.float32, GradientOpts())

proc role*(p: Palette, name: string): Result[Color, ColorError] {.raises: [].} =
  ## Role access for `Semantic`. `InvalidOp` for other structures. Unknown role
  ## -> `InvalidColor`.
  if p.tag != palSemantic:
    return err[Color, ColorError](colorError(InvalidOp,
        "role: role access not valid for structure " & $p.tag, "role"))
  if not p.roles.hasKey(name):
    return err[Color, ColorError](colorError(InvalidColor,
        "role: unknown role '" & name & "'", "role"))
  ok[Color, ColorError](p.colors[p.roles.getOrDefault(name)])
