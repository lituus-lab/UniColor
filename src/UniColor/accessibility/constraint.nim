# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# accessibility/constraint — CVD-safety as a palette `Constraint`. Bridges the
# accessibility CVD audit (`auditSafeColors`) to the `Constraint`/
# `ConstraintResult` types in `palette/constraints`, so a palette optimizer can
# add CVD confusability to its objective the same way it adds `minDeltaEOK` /
# `minContrast` / `gamutTarget`.
#
# Lives HERE (accessibility), not in `palette/constraints`: CVD simulation is an
# accessibility-layer concern, and `palette` is below `accessibility` in the DAG
# (palette cannot import accessibility — `checkVGraph` forbids the upward edge).
# This module imports downward (`palette/constraints` for the type,
# `accessibility/safe` for the audit), which is legal. Deterministic.
import UniColor/core/core # `Color`.
import UniColor/palette/constraints # `Constraint`, `ConstraintResult`.
import UniColor/accessibility/safe # `auditSafeColors`, default threshold/severity.

const EPS = 1.0e-12

proc cvdSafe*(threshold = DefaultCvdSafeThreshold,
    severity = DefaultCvdAuditSeverity): Constraint {.raises: [].} =
  ## CVD confusability constraint: under each of the three dichromacies (protan/
  ## deuter/tritan) at `severity`, no pair of colors may collapse below
  ## `threshold` (ΔE_OK). `violation` is how far the worst-case pair (over the
  ## three dichromacies) sits below `threshold` (0 = safe) — a penalty suitable
  ## for `totalViolation`. Achromatopsia is NOT evaluated (monochromats — see
  ## `safe`). Deterministic; no input mutation.
  Constraint(name: "cvdSafe", evaluate: proc(colors: openArray[
      Color]): ConstraintResult {.raises: [].} =
    let audit = auditSafeColors(colors, threshold, severity)
    let v = max(0.0, threshold - audit.minDeltaE)
    ConstraintResult(name: "cvdSafe", satisfied: audit.safe and v <= EPS,
        violation: v, message: if audit.safe: "" else:
        "CVD-confusable pair: worst ΔE_OK " & $audit.minDeltaE & " < " &
        $threshold))
