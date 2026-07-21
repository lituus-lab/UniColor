# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# quantize — quantization algorithm registry + `extractPalette`. Turns an
# `Image` into a `Palette` of `n` colors via a registered algorithm (Wu
# default, k-means+WSM, k-means++, medianCut, octree, NeuQuant). The algos are
# registered descriptors — a new algo registers without touching the core.
# Each algo runs in the image's work space (default OKLab, the perceptual
# distance space), and the returned `Palette` carries the centroid colors in
# that work space (convert after for display sRGB; no lossy in-engine
# conversion — explicit, no magic).
#
# `extractPalette` is the unified pipeline seam: it converts the image to the
# requested work space ONCE, then hands the converted image to the algo.
# Determinism: the algos are deterministic (Wu has no RNG; k-means uses a
# seeded init), single-threaded here. `opts.parallel`/`opts.threads` stay on
# the contract surface but route to the serial path today (real thread-pool
# dispatch is a later perf lot — same deferred-parallel pattern as
# conversion/batch and palette/kmeans).
#
# Layer: image (consumer of image/internal + palette/types). Deterministic.
import std/options
import std/tables
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/core/result
import UniColor/core/color_error
import UniColor/image/internal # `Image`, `toWorkSpace`.
import UniColor/palette/types # `Palette`, `palette()`.

type
  QuantizeOpts* = object
    ## Parameters for a quantization run. `seed` initializes the stochastic
    ## algos (k-means init); Wu is deterministic and ignores it. `maxIter`
    ## bounds the iterative algos (k-means); Wu ignores it. `weighting` enables
    ## WSM (weighted least squares, perceptual) for k-means. `parallel`/
    ## `threads` are the deferred-parallel contract surface (serial today,
    ## the bit-exact reference path; a later perf lot wires real dispatch).
    seed*: int64
    maxIter*: int
    weighting*: bool
    parallel*: bool
    threads*: int

  QuantizeAlgo* = object
    ## Descriptor for a registered quantization algorithm (data-driven like
    ## the other registries). `compute` runs on an `Image` ALREADY in the
    ## target work space (the caller — `extractPalette` — converts once) and
    ## returns a `Palette` of <= `n` centroid colors in that work space. `n < 1`
    ## is rejected by `extractPalette` before dispatch.
    name*: string
    compute*: proc(img: Image, n: int, opts: QuantizeOpts): Result[Palette,
        ColorError] {.raises: [].}

const
  DefaultQuantizeAlgo* = "wu"      ## Wu (quality default).
  DefaultQuantizeSpace* = tagOklab ## OKLab perceptual distance space.
  DefaultQuantizeMaxIter* = 20     ## k-means iteration cap; Wu ignores it.

proc defaultQuantizeOpts*(): QuantizeOpts {.raises: [].} =
  ## The default options: seed 0 (canonical, deterministic), 20 iterations,
  ## WSM off, serial (`parallel: false` — the bit-exact reference path). Wu
  ## ignores seed/maxIter/weighting; k-means honors them; `parallel`/
  ## `threads` gate the deferred dispatch.
  QuantizeOpts(seed: 0, maxIter: DefaultQuantizeMaxIter, weighting: false,
      parallel: false, threads: 0)

# Registry — module-level table, idempotent registration, optional seal
# (mirrors the other registries). Extensible: a downstream user registers
# their own quantizer.
var
  quantByName: Table[string, QuantizeAlgo]
  quantSealed: bool

proc registerQuantizeAlgo*(a: QuantizeAlgo): bool {.raises: [].} =
  if quantSealed or a.name.len == 0 or quantByName.hasKey(a.name) or
      a.compute.isNil:
    return false
  quantByName[a.name] = a
  true

proc lookupQuantizeAlgo*(name: string): Option[QuantizeAlgo] {.raises: [].} =
  if quantByName.hasKey(name):
    some(quantByName.getOrDefault(name))
  else:
    none(QuantizeAlgo)

proc sealQuantizeAlgos*() {.raises: [].} =
  quantSealed = true

proc extractPalette*(img: Image, n: int, algo = DefaultQuantizeAlgo,
    space = DefaultQuantizeSpace, opts = defaultQuantizeOpts()): Result[Palette,
    ColorError] {.raises: [].} =
  ## Quantize `img` to a `Palette` of `n` colors via the registered `algo`,
  ## operating in `space` (default OKLab — perceptual). The image is converted
  ## to `space` once (immutably), then handed to the algo. The returned
  ## palette's colors are centroids in `space` — convert them for display if
  ## needed (no lossy in-engine conversion; explicit). `n < 1` -> `err
  ## InvalidOp`; unknown algo -> `err UnknownAlgorithm`; conversion error
  ## propagates. Deterministic.
  if n < 1:
    return err[Palette, ColorError](colorError(InvalidOp,
        "extractPalette: n must be >= 1, got " & $n, "extractPalette"))
  let a = lookupQuantizeAlgo(algo)
  if a.isNone:
    return err[Palette, ColorError](colorError(UnknownAlgorithm,
        "unknown quantization algorithm: " & algo, "extractPalette"))
  if img.workSpace == space:
    # already in the target work space — no conversion (avoid a copy).
    return a.get.compute(img, n, opts)
  let convR = img.toWorkSpace(space)
  if convR.isErr:
    return err[Palette, ColorError](convR.error)
  a.get.compute(convR.get, n, opts)
