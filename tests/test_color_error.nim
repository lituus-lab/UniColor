# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import std/strutils
import UniColor

suite "ColorErrorKind — exhaustive categories":
  test "all recoverable categories constructible and carry their kind":
    let cases: array[14, (ColorErrorKind, string)] = [
      (InvalidColor, "hue>360"), (UnknownSpace, "no such space"),
      (UnknownMetric, "no such deltaE"), (UnknownCvdModel, "no such cvd"),
      (UnknownExporter, "no such exporter"), (UnknownImporter,
          "no such importer"),
      (UnknownAlgorithm, "no such quantizer"), (UnknownFormat, "sniff failed"),
      (Unsatisfiable, "contrast impossible"), (UnresolvedRole, "role missing"),
      (InvalidOp, "sample on unordered"), (ImportFailed, "structure illisible"),
      (InvalidImage, "0x0"), (EmptySource, "empty source"),
    ]
    for (k, msg) in cases:
      let e = colorError(k, msg)
      check e.kind == k
      check e.message == msg

  test "NumericalError category present":
    let e = colorError(NumericalError, "overflow")
    check e.kind == NumericalError

suite "error context":
  test "context and explicit severity carried":
    let e = colorError(InvalidColor, "alpha<0", "role=primary", Warning)
    check e.context == "role=primary"
    check e.severity == Warning
  test "default severity is Error for recoverable categories":
    check colorError(InvalidColor, "x").severity == Error
    check colorError(Unsatisfiable, "x").severity == Error
    check colorError(UnresolvedRole, "x").severity == Error
  test "default severity is Fatal for non-recoverable categories":
    check defaultSeverity(ImportFailed) == Fatal
    check defaultSeverity(NumericalError) == Fatal
    check colorError(ImportFailed, "x").severity == Fatal
  test "default context is empty":
    check colorError(InvalidColor, "x").context == ""

suite "deterministic diagnostic format":
  test "$ renders kind, message, severity":
    let s = $colorError(InvalidColor, "alpha<0")
    check "InvalidColor" in s
    check "alpha<0" in s
    check "Error" in s
  test "$ includes context when present":
    let s = $colorError(InvalidColor, "alpha<0", "role=primary")
    check "role=primary" in s

suite "Severity enum":
  test "has four distinct levels Info/Warning/Error/Fatal":
    check Severity.Info != Severity.Warning
    check Severity.Warning != Severity.Error
    check Severity.Error != Severity.Fatal
