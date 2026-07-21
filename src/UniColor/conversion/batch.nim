# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# batch — vector/batch conversion APIs.
#
# `toBatch` / `gamutMapBatch` process N independent colors with the SAME result
# as calling the per-color `to` / `gamutMap` element-by-element (within
# TOL_NUMERIC). They are a vector surface alongside the per-color O(1) APIs (not
# a replacement — no `Optimized*` variants). The serial impl delegates to the
# existing per-color procs, so it is bit-exact by construction.
#
# `opts.parallel` is accepted but routes to the serial path (documented no-op):
# real thread-pool dispatch is deferred. `to`/`gamutMap` read the space-registry
# globals (`byTag` in spaces/registry.nim, `var` mutated at bootstrap then
# sealed), and Nim `spawn` rejects non-gcsafe calls, so parallel dispatch needs
# the registry's post-seal reads marked `{.gcsafe.}` — a cross-module change
# beyond this layer. At palette/batch scale (N ~ 5-20) per-element parallelism is
# a slowdown anyway (`spawn` costs ~us vs `to` ~376ns/elt); the genuinely
# parallel hot path is the image-wide quantize histogram (integer bin-counts, no
# registry read in the inner loop). The `parallel` flag stays on the contract
# surface so callers opt in without API churn when a future lot wires real
# parallelism; tests pin `parallel=true == serial == scalar` within TOL_NUMERIC.
# Errors propagate: the first failing element short-circuits. Alpha preserved.

import UniColor/core/core # Color, ColorError, Result, BatchOpts, TOL_NUMERIC.
import UniColor/conversion/to # to — the per-color scalar reference (bit-exact).
import UniColor/conversion/gamut # gamutMap — the per-color scalar reference.

# Serial convert: N colors -> target. Bit-exact vs `to(c, target)` per element
# (delegates directly). `opts.parallel` accepted but routes here (deferred);
# serial is the reference.
proc toBatch*(src: openArray[Color], target: SpaceTag,
    opts = defaultBatchOpts()): Result[seq[Color], ColorError] {.raises: [].} =
  var outSeq = newSeq[Color](src.len)
  for i in 0 ..< src.len:
    let r = to(src[i], target)
    if r.isErr:
      return err[seq[Color], ColorError](r.error)
    outSeq[i] = r.get
  ok[seq[Color], ColorError](outSeq)

# Serial gamut map: N colors -> gamut-mapped into `target` (chroma-reduce if
# bounded, CSS Color 4). Bit-exact vs `gamutMap(c, target)` per element.
# `opts.parallel` accepted but routes here (deferred).
proc gamutMapBatch*(src: openArray[Color], target: SpaceTag,
    opts = defaultBatchOpts()): Result[seq[Color], ColorError] {.raises: [].} =
  var outSeq = newSeq[Color](src.len)
  for i in 0 ..< src.len:
    let r = gamutMap(src[i], target)
    if r.isErr:
      return err[seq[Color], ColorError](r.error)
    outSeq[i] = r.get
  ok[seq[Color], ColorError](outSeq)
