# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# import/registry — importer registry + `importReported`/`importTheme`/
# `importPalette` dispatch. MIRRORS export/registry: an importer is a
# registered descriptor adapting an external format STRING back into the token
# tree. The registry is module-level, idempotent (no overwrite), and sealable
# (read-only after bootstrap). `importReported` resolves a name and invokes the
# importer's `parse(input, opts)`; an unknown name -> `err UnknownImporter`.
# `importTheme`/`importPalette` are conveniences that extract the matching
# target kind from the report; a kind mismatch -> `err InvalidOp`.
#
# `ImportTarget` is a case object: a format with roles (CSS vars, Base16, IDE,
# JSON/TOML/YAML with the alias structure) reconstructs a `Theme`; a format
# with a bare color list (no roles) reconstructs a `Palette`. The importer
# decides which (import/reconstruct).
#
# `ImportOpts.strict` is the cross-cutting partial-failure knob: `false`
# (default) = best-effort, collect recoverable errors as `PaletteWarning`s in
# the report (non-silent); `true` = fatal on the first recoverable error
# (`err ImportFailed`). Every importer honors it, so it lives here in the
# shared opts.
#
# `ImportReport.formatName` is the format the importer reconstructs;
# `schemaVersion` is the version read from the source ("" if the format
# carries none); `warnings` carries the recoverable errors (migration advise
# for an older schema, partial tokens).
#
# `import` is a Nim keyword, so this module is imported with the quoted form
# `import "UniColor/import/registry"`.
#
# Layer: import (consumer of theme/tree + palette/types + core +
# palette/unsatisfiable for PaletteWarning).
import std/tables
import std/options
import UniColor/core/result
import UniColor/core/color_error
import UniColor/theme/tree
import UniColor/palette/types # Palette.
import UniColor/palette/unsatisfiable # PaletteWarning / WarningCode.

type
  ImportKind* {.pure.} = enum
    ## What an importer reconstructed from the source. A role-bearing format
    ## (CSS vars, Base16, IDE, JSON/TOML/YAML) -> `ikTheme`; a bare color list
    ## (no roles) -> `ikPalette`.
    ikTheme
    ikPalette

  ImportTarget* = object
    ## The reconstructed target (a Theme OR a Palette). Case object: exactly
    ## one of `theme` / `palette` is populated, selected by `kind`.
    case kind*: ImportKind
    of ikTheme: theme*: Theme
    of ikPalette: palette*: Palette

  ImportReport* = object
    ## The result of an import. `target` is the reconstructed Theme/Palette;
    ## `formatName` the format the importer reconstructs; `schemaVersion` the
    ## version read from the source ("" if the format carries none);
    ## `warnings` any recoverable errors raised during reconstruction
    ## (migration advise, partial tokens — non-silent).
    target*: ImportTarget
    formatName*: string
    schemaVersion*: string
    warnings*: seq[PaletteWarning]

  ImportOpts* = object
    ## Cross-cutting import options honored by every importer. `strict = false`
    ## (default) = best-effort: recoverable errors become `PaletteWarning`s in
    ## the report (non-silent); `true` = fatal on the first recoverable error
    ## (`err ImportFailed`). Declared here so the `parse` signature is stable.
    strict*: bool

  Importer* = object
    ## A registered importer descriptor. `parse` reads the format string and
    ## reconstructs a Theme or Palette; it selects the target kind
    ## (import/reconstruct). The registry stores and dispatches it verbatim —
    ## no transformation, no coupling between importers. `name` is the lookup
    ## key (e.g. "css", "json", "base16").
    name*: string
    parse*: proc(input: string, opts: ImportOpts): Result[ImportReport,
        ColorError] {.raises: [].}

proc defaultImportOpts*(): ImportOpts {.raises: [].} =
  ## Best-effort (collect recoverable errors as warnings). The common case;
  ## `strict = true` is for callers that want a hard fail on the first
  ## recoverable problem.
  ImportOpts(strict: false)

# Registry — module-level table, idempotent registration, optional seal
# (mirrors export/registry and the quantize/loader/dither registries).
# Extensible: a downstream user registers their own importer. Not `threadvar`:
# shared (mutated only at single-threaded bootstrap, read-only after seal).
var
  importersByName: Table[string, Importer]
  importersSealed: bool

proc registerImporter*(e: Importer): bool {.raises: [].} =
  ## Register an importer during bootstrap. Returns `true` if added, `false`
  ## if the name is already present (no overwrite), the registry is sealed,
  ## the name is empty, or `parse` is nil. The caller must check the bool.
  if importersSealed or e.name.len == 0 or e.parse.isNil or
      importersByName.hasKey(e.name):
    return false
  importersByName[e.name] = e
  true

proc lookupImporter*(name: string): Option[Importer] {.raises: [].} =
  ## O(1) lookup by name. `none` if absent.
  if importersByName.hasKey(name):
    some(importersByName.getOrDefault(name))
  else:
    none(Importer)

proc importerCount*(): int {.raises: [].} =
  importersByName.len

proc importerNames*(): seq[string] {.raises: [].} =
  result = @[]
  for k in keys(importersByName):
    result.add(k)

proc sealImporters*() {.raises: [].} =
  ## Freeze the registry: no further registration (read-only after bootstrap).
  importersSealed = true

proc importReported*(input: string, name: string,
    opts = defaultImportOpts()): Result[ImportReport, ColorError] {.
    raises: [].} =
  ## Import `input` as format `name` and return the full report (target +
  ## warnings). This is the NON-SILENT path: a best-effort importer
  ## (strict=false) collects recoverable errors as `PaletteWarning`s rather
  ## than failing; the caller MUST read `warnings`. Unknown name -> `err
  ## UnknownImporter`. The importer's own errors propagate. Deterministic
  ## given the importer.
  let lo = lookupImporter(name)
  if lo.isNone:
    return err[ImportReport, ColorError](colorError(UnknownImporter,
        "importReported: unknown importer '" & name & "'", "importReported"))
  lo.get.parse(input, opts)

proc importTheme*(input: string, name: string,
    opts = defaultImportOpts()): Result[Theme, ColorError] {.raises: [].} =
  ## Convenience: import `input` as `name` and return the reconstructed `Theme`
  ## only. Errors if the report holds a `Palette` (kind mismatch -> `err
  ## InvalidOp`) — use `importPalette` for those, or `importReported` to
  ## inspect the kind. Unknown name -> `err UnknownImporter`; importer errors
  ## propagate.
  let r = importReported(input, name, opts)
  if r.isErr:
    return err[Theme, ColorError](r.error)
  let rep = r.get
  if rep.target.kind != ikTheme:
    return err[Theme, ColorError](colorError(InvalidOp,
        "importTheme: format '" & name &
        "' reconstructed a Palette, not a Theme", "importTheme"))
  ok[Theme, ColorError](rep.target.theme)

proc importPalette*(input: string, name: string,
    opts = defaultImportOpts()): Result[Palette, ColorError] {.raises: [].} =
  ## Convenience: import `input` as `name` and return the reconstructed
  ## `Palette` only. Errors if the report holds a `Theme` (kind mismatch ->
  ## `err InvalidOp`). Unknown name -> `err UnknownImporter`; importer errors
  ## propagate.
  let r = importReported(input, name, opts)
  if r.isErr:
    return err[Palette, ColorError](r.error)
  let rep = r.get
  if rep.target.kind != ikPalette:
    return err[Palette, ColorError](colorError(InvalidOp,
        "importPalette: format '" & name &
        "' reconstructed a Theme, not a Palette", "importPalette"))
  ok[Palette, ColorError](rep.target.palette)
