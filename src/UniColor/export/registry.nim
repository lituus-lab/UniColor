# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# export/registry — exporter registry + `exportTheme` dispatch. An exporter is
# a registered descriptor adapting the token tree (Theme) to an external format
# string. The registry is module-level, idempotent (no overwrite), and sealable
# (read-only after bootstrap). `exportTheme` resolves a name and invokes the
# exporter's `render(theme, opts)`; an unknown name -> `err UnknownExporter`.
#
# `ExportOpts` carries the cross-cutting output knobs every color-bearing
# exporter honors: OKLCH default / sRGB legacy, the CSS-var prefix, and an
# optional dark-mode theme. Format-specific options (Tailwind steps, Base16
# slots) live in their own modules, reached via the format's direct entry
# point. `render` returns an `ExportReport` (the format string + any warnings
# — `warnInfoLost` for lossy projections like Base16/terminals);
# `exportTheme` is the lossless convenience that returns `.output` only,
# `exportThemeReported` is the non-silent path that surfaces the warnings.
#
# `export` is a Nim keyword, so this module is imported with the quoted form
# `import "export/registry"`.
#
# Layer: export (consumer of theme/tree + core + palette/unsatisfiable for
# PaletteWarning).
import std/tables
import std/options
import UniColor/core/result
import UniColor/core/color_error
import UniColor/theme/tree
import UniColor/palette/unsatisfiable # PaletteWarning / WarningCode (warnInfoLost).

type
  ExportOpts* = object
    ## Cross-cutting export options honored by every color-bearing exporter.
    ## `legacySrgb = false` (default) emits OKLCH (CSS Color 4, the perceptual
    ## default); `true` emits sRGB legacy (`rgb()`/hex) for tools that lack
    ## OKLCH support. `prefix` is the CSS-var prefix (default `--`). `dark` is
    ## an optional dark-mode theme; CSS emits it as `@media
    ## (prefers-color-scheme: dark)`, Tailwind as `dark:` variants. `none` =
    ## light only.
    legacySrgb*: bool
    prefix*: string
    dark*: Option[Theme]

  ExportReport* = object
    ## The result of an export. `output` is the format string; `warnings`
    ## carries any `WarningCode` raised during projection — most notably
    ## `warnInfoLost` when a lossy format (Base16/terminal) cannot carry every
    ## theme token. Lossless formats (CSS vars, Tailwind) emit no warnings.
    output*: string
    warnings*: seq[PaletteWarning]

  Exporter* = object
    ## A registered exporter descriptor. `render` produces the format string
    ## from the token tree; it selects the role families it consumes (a
    ## terminal exporter takes surfaces+accents+syntax, a CSS-vars exporter
    ## takes semantic tokens). `name` is the lookup key (e.g. "css",
    ## "tailwind", "alacritty").
    name*: string
    render*: proc(theme: Theme, opts: ExportOpts): Result[ExportReport,
        ColorError] {.raises: [].}

proc defaultExportOpts*(): ExportOpts {.raises: [].} =
  ## OKLCH output (the perceptual default), `--` prefix, no dark mode.
  ExportOpts(legacySrgb: false, prefix: "--", dark: none(Theme))

# Registry — module-level table, idempotent registration, optional seal
# (mirrors the quantize/loader/dither registries). Extensible: a downstream
# user registers their own exporter. Not `threadvar`: shared (mutated only at
# single-threaded bootstrap, read-only after seal).
var
  exportersByName: Table[string, Exporter]
  exportersSealed: bool

proc registerExporter*(e: Exporter): bool {.raises: [].} =
  ## Register an exporter during bootstrap. Returns `true` if added, `false`
  ## if the name is already present (no overwrite), the registry is sealed,
  ## the name is empty, or `render` is nil. The caller must check the bool.
  if exportersSealed or e.name.len == 0 or e.render.isNil or
      exportersByName.hasKey(e.name):
    return false
  exportersByName[e.name] = e
  true

proc lookupExporter*(name: string): Option[Exporter] {.raises: [].} =
  ## O(1) lookup by name. `none` if absent.
  if exportersByName.hasKey(name):
    some(exportersByName.getOrDefault(name))
  else:
    none(Exporter)

proc exporterCount*(): int {.raises: [].} =
  exportersByName.len

proc exporterNames*(): seq[string] {.raises: [].} =
  result = @[]
  for k in keys(exportersByName):
    result.add(k)

proc sealExporters*() {.raises: [].} =
  ## Freeze the registry: no further registration (read-only after bootstrap).
  exportersSealed = true

proc exportThemeReported*(theme: Theme, name: string,
    opts = defaultExportOpts()): Result[ExportReport, ColorError] {.
    raises: [].} =
  ## Export `theme` to format `name` and return the full report (output +
  ## warnings). This is the NON-SILENT path: lossy formats (Base16/terminal)
  ## raise `warnInfoLost` when theme tokens cannot be projected into the
  ## format's slots; the caller MUST read `warnings` to avoid a silent
  ## information loss. Unknown name -> `err UnknownExporter`. The exporter's
  ## own errors propagate. Deterministic given the exporter.
  let lo = lookupExporter(name)
  if lo.isNone:
    return err[ExportReport, ColorError](colorError(UnknownExporter,
        "exportThemeReported: unknown exporter '" & name & "'",
        "exportThemeReported"))
  lo.get.render(theme, opts)

proc exportTheme*(theme: Theme, name: string,
    opts = defaultExportOpts()): Result[string, ColorError] {.raises: [].} =
  ## Convenience: export `theme` to format `name` and return `.output` only
  ## (warnings discarded). Fine for lossless formats (CSS vars, Tailwind — no
  ## warnings). For lossy formats (Base16, terminals) use
  ## `exportThemeReported` so `warnInfoLost` is not silently dropped. Unknown
  ## name -> `err UnknownExporter`.
  let r = exportThemeReported(theme, name, opts)
  if r.isErr:
    return err[string, ColorError](r.error)
  ok[string, ColorError](r.get.output)
