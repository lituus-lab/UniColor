# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# contrast/batch — vector/batch distance API. `deltaEOkBatch` computes ΔE_ok
# over N (a,b) pairs matching `deltaE_ok` element-by-element within TOL_NUMERIC.
# `batchOpts.parallel` is accepted on the contract surface but is a documented
# no-op (serial today). Length mismatch -> InvalidOp.
import UniColor/core/core # Color, ColorError, Result, BatchOpts, colorError, InvalidOp.
import UniColor/core/simd # Vec[2, float64] SIMD128 lane.
import UniColor/contrast/ok # deltaE_ok — the per-pair scalar reference (OKLab-direct, no hub).

# SIMD ΔE_ok over aligned pairs, 2 pairs per f64x2 lane. Within TOL_NUMERIC of
# `deltaE_ok` per pair (bit-identical under RNE + no-fast-math; `x*x` vs `^2`
# <1 ULP). Tail (<2) scalar. `batchOpts.parallel` accepted but is a no-op for
# threads (see module header); SIMD runs for both flag values at len>=4.
proc deltaEOkBatch*(a, b: openArray[Color],
    opts = defaultBatchOpts()): Result[seq[float64], ColorError] {.raises: [].} =
  discard opts # parallel thread dispatch deferred (SIMD/serial path); kept on the contract surface
  if a.len != b.len:
    return err[seq[float64], ColorError](colorError(InvalidOp,
        "deltaEOkBatch: pair arrays must be the same length (got " & $a.len &
        " and " & $b.len & ")", "deltaEOkBatch"))
  let n = a.len
  var outSeq = newSeq[float64](n)
  var i = 0
  # SIMD: 2 pairs per Vec[2, float64] lane. Gate len >= 4 so the 6-lane gather
  # amortizes; below that the scalar tail is as fast (no vectorization win at 1
  # iteration).
  if n >= 4:
    while n - i >= 2:
      let l1 = vec([a[i].comp(0).float64, a[i + 1].comp(0).float64])
      let a1 = vec([a[i].comp(1).float64, a[i + 1].comp(1).float64])
      let b1 = vec([a[i].comp(2).float64, a[i + 1].comp(2).float64])
      let l2 = vec([b[i].comp(0).float64, b[i + 1].comp(0).float64])
      let a2 = vec([b[i].comp(1).float64, b[i + 1].comp(1).float64])
      let b2 = vec([b[i].comp(2).float64, b[i + 1].comp(2).float64])
      let dl = l1 - l2
      let da = a1 - a2
      let db = b1 - b2
      # d² = (dl² + da²) + db² — left-assoc, same order as the scalar `^2 + ^2 + ^2`.
      let d2 = dl * dl + da * da + db * db
      let d = vsqrt(d2)
      outSeq[i] = d[0]
      outSeq[i + 1] = d[1]
      i += 2
  # Scalar tail (remainder, and the whole array when len < 4).
  while i < n:
    outSeq[i] = deltaE_ok(a[i], b[i])
    inc i
  ok[seq[float64], ColorError](outSeq)
