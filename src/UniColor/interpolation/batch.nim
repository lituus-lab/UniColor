# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# interpolation/batch — batch interpolation API.
#
# `interpolateBatch` blends a→b at N `t` values with the SAME result as calling
# `interpolate(a, b, t, opts)` element-by-element (bit-exact by construction —
# it delegates to the scalar proc). This is the ramp form (fixed endpoints,
# many parameters): palette gradients, tonal scales.
# `batchOpts.parallel` is ACCEPTED but routes to the serial path (documented
# no-op): `interpolate` is hub-bound and not gcsafe without a registry post-seal
# annotation, so thread dispatch is deferred. The `parallel` flag stays on the
# contract surface; tests pin `parallel=true == serial == scalar`. Hub/gamut
# errors from the first failing t short-circuit.
import UniColor/core/core # Color, ColorError, Result, BatchOpts, defaultBatchOpts.
import UniColor/interpolation/space # interpolate, InterpOpts — the per-t scalar reference.

# Serial interpolate: a→b at each `t` in `ts`. Bit-exact vs
# `interpolate(a, b, t, opts)` per t. `batchOpts.parallel` accepted but routes
# here (deferred — see module header); `batchOpts` is otherwise unused today.
# Errors short-circuit.
proc interpolateBatch*(a, b: Color, ts: openArray[float32], opts0: InterpOpts,
    batchOpts = defaultBatchOpts()): Result[seq[Color], ColorError] {.
    raises: [].} =
  discard batchOpts # parallel dispatch deferred (serial path); kept on the contract surface
  var outSeq = newSeq[Color](ts.len)
  for i in 0 ..< ts.len:
    let r = interpolate(a, b, ts[i], opts0)
    if r.isErr:
      return err[seq[Color], ColorError](r.error)
    outSeq[i] = r.get
  ok[seq[Color], ColorError](outSeq)
