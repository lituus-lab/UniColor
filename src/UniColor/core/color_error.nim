# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# color_error — ColorError (context) + ColorErrorKind (SemVer-stable enum).
# The enum is a 1:1 mirror of the C ABI error codes (UcError) at the C/WASM
# boundary. Stable: add = minor, remove/recode = major; no in-place recoding
# (would break compiled bindings).

type
  ColorErrorKind* {.pure.} = enum
    ## Error categories stable per major. `InvalidColor` is an error category,
    ## not a separate type.
    InvalidColor ## strict out-of-range domain (hue>360, alpha<0, NaN at bounds)
    UnknownSpace ## unregistered space (runtime conversion)
    UnknownMetric ## unknown distance/contrast metric
    UnknownCvdModel ## unknown CVD model
    UnknownExporter ## unregistered export format
    UnknownImporter ## unregistered import format
    UnknownAlgorithm ## unknown quantization/generation algorithm
    UnknownFormat ## import auto-detection failed
    Unsatisfiable ## unsatisfiable constraint (impossible contrast/gamut/ΔE)
    UnresolvedRole ## missing role + exhausted fallback (theme)
    InvalidOp ## invalid operation for the tag (e.g. sample on Unordered)
    ImportFailed ## unreadable structure / schema version < min (fatal)
    InvalidImage ## empty image / 0×0 / unsupported image format
    EmptySource ## empty import source
    NumericalError ## unrecoverable overflow/underflow (rare — NaN propagated)

  Severity* {.pure.} = enum
    Info
    Warning
    Error
    Fatal

  ColorError* = object
    ## Contextual error carried by `Result[T, ColorError]`. `kind` is the
    ## stable contract (SemVer, mirror of UcError); `message`/`context` are
    ## localizable diagnostics.
    kind*: ColorErrorKind
    message*: string
    context*: string
    severity*: Severity

func defaultSeverity*(kind: ColorErrorKind): Severity {.raises: [].} =
  ## Default severity per category: `ImportFailed`/`NumericalError` = fatal
  ## (non-recoverable); the others = error (recoverable).
  case kind
  of ImportFailed, NumericalError:
    Fatal
  else:
    Error

func colorError*(kind: ColorErrorKind, message: string, context = "",
                 severity = defaultSeverity(kind)): ColorError {.raises: [].} =
  ## Contextual error constructor. Default severity derives from `kind` unless
  ## explicit override.
  ColorError(kind: kind, message: message, context: context, severity: severity)

func `$`*(e: ColorError): string {.raises: [].} =
  ## Diagnostic: `ColorError(<kind>): <message> [<context>] <<severity>>`.
  result = "ColorError(" & $e.kind & "): " & e.message
  if e.context.len > 0:
    result.add(" [" & e.context & "]")
  result.add(" <" & $e.severity & ">")
