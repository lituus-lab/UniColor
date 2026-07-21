# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# import/reconstruct — shared token -> Theme/Palette assembly. The importer's
# `parse` (registry) extracts tokens from a format STRING; this module is the
# SHARED reconstruction every format importer calls, so none duplicates the
# "tokens -> Theme" / "colors -> Palette" assembly. `reconstruct(input)`
# DECIDES Theme vs Palette (Theme if the source carries roles: named
# primitives or aliases; Palette otherwise — only a flat color list) and
# ASSEMBLES the target, delegating to `theme()` / `palette()`. The decision
# rule: a role-bearing format with named primitives but NO aliases is still a
# Theme (the primitive layer alone — Tailwind's color scale, Base16's 16
# slots); only a nameless flat list becomes a Palette.
#
# `ReconstructInput` is the intermediate representation between parse and
# assemble: the importer fills the branches it extracted
# (primitives/semantics/components for the role path, bareColors for the flat
# path, plus the schemaVersion read from the source and the Palette
# tag/intent/seed for the flat path). `reconstruct` returns an `ImportTarget`
# (the case object from the registry), ready to drop straight into an
# `ImportReport`.
#
# Why the decision lives here (not in each importer): a single rule keeps
# "what is a Theme vs a Palette" consistent across formats — CSS vars, Base16
# slots and JSON/TOML/YAML all reach the same `reconstruct` and the same
# `decideKind`. The importer only reports what it found.
#
# Deterministic: `theme`/`palette` are pure constructors; reconstruction is
# deterministic given the input. No RNG, no I/O. `import` is a Nim keyword
# -> quoted import.
#
# Layer: import (consumer of theme/tree + palette/types + the registry
# types).
import UniColor/core/result
import UniColor/core/core # Color.
import UniColor/core/color_error
import UniColor/theme/tree # Theme / ThemeToken / theme().
import UniColor/palette/types # Palette / PaletteTag / PaletteIntent / palette().
import "UniColor/import/registry" # ImportTarget / ImportKind.

type
  ReconstructInput* = object
    ## What an importer extracts from a format source, ready for `reconstruct`
    ## to assemble. Fill the branches you have; `reconstruct` decides Theme vs
    ## Palette from what is present. `primitives`/`semantics`/`components`
    ## carry the ROLE path (CSS vars, Base16 slots, JSON/TOML/YAML aliases) ->
    ## Theme; `bareColors` carries the FLAT path (a nameless hex list) ->
    ## Palette. `schemaVersion` is the version read from the source ("" if the
    ## format carries none).
    primitives*: seq[ThemeToken]
    semantics*: seq[ThemeToken]
    components*: seq[ThemeToken]
    bareColors*: seq[Color]
    paletteTag*: PaletteTag ## the flat-path Palette structure (default
                              ## `palUnordered`).
    paletteIntent*: PaletteIntent ## the flat-path Palette intent (default
                                    ## `intentQualitative`).
    seed*: int64 ## the flat-path Palette seed (default 0).
    schemaVersion*: string

proc defaultReconstructInput*(): ReconstructInput {.raises: [].} =
  ## Empty input with flat-path defaults (`palUnordered` / `intentQualitative`
  ## / seed 0). A bare hex list is qualitative unordered by default; the
  ## importer overrides if it knows better.
  ReconstructInput(paletteTag: palUnordered, paletteIntent: intentQualitative,
      seed: 0)

proc decideKind*(input: ReconstructInput): ImportKind {.raises: [].} =
  ## Theme if the source carries roles (named primitives OR aliases); Palette
  ## if it carries only a flat color list. A primitive-only source is still a
  ## Theme (the primitive layer alone). Roles take priority: if both
  ## `primitives` and `bareColors` are present, the role path wins.
  if input.primitives.len > 0 or input.semantics.len > 0 or
      input.components.len > 0:
    ikTheme
  else:
    ikPalette

proc reconstruct*(input: ReconstructInput): Result[ImportTarget,
    ColorError] {.raises: [].} =
  ## Decide Theme vs Palette from `input` and assemble the `ImportTarget`.
  ## Theme path delegates to `theme(primitives, semantics, components)`
  ## (validates tokens, rejects duplicates); Palette path delegates to
  ## `palette(tag, colors, intent, seed)` (rejects empty). An empty input (no
  ## roles AND no bare colors) -> `err InvalidOp`. Constructor errors
  ## propagate.
  case decideKind(input)
  of ikTheme:
    let t = theme(input.primitives, input.semantics, input.components)
    if t.isErr:
      return err[ImportTarget, ColorError](t.error)
    ok[ImportTarget, ColorError](ImportTarget(kind: ikTheme, theme: t.get))
  of ikPalette:
    if input.bareColors.len == 0:
      return err[ImportTarget, ColorError](colorError(InvalidOp,
          "reconstruct: no roles and no bare colors (empty source)",
          "reconstruct"))
    let p = palette(input.paletteTag, input.bareColors, input.paletteIntent,
        input.seed)
    if p.isErr:
      return err[ImportTarget, ColorError](p.error)
    ok[ImportTarget, ColorError](ImportTarget(kind: ikPalette, palette: p.get))
