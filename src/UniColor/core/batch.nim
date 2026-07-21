# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# batch — BatchOpts: shared options for the vector/batch APIs.
# The batch surface processes N independent elements with the same result as
# element-by-element (within TOL_NUMERIC). `parallel` (thread pool, order-stable
# map) and `threads` (0 = auto). Fast-math OFF; batch results match the scalar
# path within TOL_NUMERIC.

type
  BatchOpts* = object
    ## Options shared by every batch/vector API. Defaults are the serial path.
    ##
    ## `parallel`: opt into thread-pool dispatch (order-stable map). Currently a
    ## no-op — parallelism is deferred (gcsafe/registry). The flag is on the
    ## contract surface so callers opt in without future API churn. Serial is
    ## the bit-exact reference; parallel dispatch must match it within
    ## TOL_NUMERIC (each element by the same per-color proc, no shared float
    ## reduction).
    ##
    ## `threads`: thread count when `parallel` (0 = auto). Ignored while
    ## `parallel` is a no-op.
    parallel*: bool
    threads*: int

proc defaultBatchOpts*(): BatchOpts {.raises: [].} =
  ## The serial default — `parallel=false`. Callers opt into parallel
  ## explicitly.
  BatchOpts(parallel: false, threads: 0)
