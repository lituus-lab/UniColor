# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# contrast/batch — vector/batch distance API.
#
# `deltaEOkBatch` computes ΔE_ok over N (a,b) pairs with the SAME result as
# calling `deltaE_ok` element-by-element (within TOL_NUMERIC). `batchOpts.parallel`
# is ACCEPTED but routes to the SIMD/serial path (documented no-op for THREADS):
# `deltaE_ok` is pure math (no registry read → gcsafe-able, unlike the hub-bound
# batch procs), BUT it costs ~6.7ns/pair while a thread `spawn` costs ~µs, so
# per-pair THREAD parallelism is a SLOWDOWN at every realistic N. The
# `parallel` flag stays on the contract surface for API stability; tests pin
# `parallel=true == serial == scalar` within TOL_NUMERIC. Length mismatch →
# InvalidOp.
#
# SIMD: the batch processes 2 pairs per `Vec[2, float64]` lane (128-bit f64x2).
# float64 (not f32x4) matches the scalar `deltaE_ok` precision — a float32 lane
# would violate TOL_NUMERIC for small distances (see core/simd.nim header). Ops
# are left-assoc `*`/`+` in the SAME order as the scalar
# `sqrt((l1-l2)^2 + (a1-a2)^2 + (b1-b2)^2)`, and `x*x` stands in for the scalar
# `^2`/`pow` (within <1 ULP, well inside TOL_NUMERIC). Bit-identical RNE
# (no fast-math); auto-vectorized to `sqrtpd`/`mulpd`/`addpd` at -O3 (release),
# 2-way scalar in debug — same values either way. Gated `len >= 4` (two full
# 2-lane iterations) so the gather does not dominate at tiny N; the scalar tail
# handles the remainder and any len < 4. `parallel` does not gate SIMD (SIMD is
# intra-proc, not threads) — both flag values use the SIMD path when len >= 4.
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
