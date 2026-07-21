# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# quantize_kmeans — perceptual k-means image quantization. Two registered
# algos: "kmeans" (random init) and "kmeansPP" (k-means++ init). Both reuse
# the palette-layer k-means (`UniColor/palette/kmeans`) for the core Lloyd
# iteration in OKLab — the perceptual distance space (ΔE_OK). The image's
# pixels are the point set; the returned `Palette` carries the `n` centroids
# in OKLab (palUnordered / intentQualitative, seed from opts).
#
# WSM (Weighted Significance, `opts.weighting`): the spec calls for weighting
# pixels by perceptual salience but does NOT pin a formula — an explicit spec
# hole. The chosen, documented heuristic here: salience = 1 + OKLab chroma
# (sqrt(a²+b²)), so achromatic pixels keep weight 1 and chromatic pixels are
# weighted higher (they carry more perceptual signal). WSM runs a weighted
# Lloyd: assignment = nearest centroid (unweighted, standard), centroid
# update = weighted mean Σ(wᵢ·pᵢ)/Σwᵢ, convergence = max centroid ΔE_OK
# shift < tol. The weighted path reuses palette/kmeans for the init (k-means++
# / random) via a maxIter=0 call (it returns the init centroids without
# iterating), then runs its own weighted Lloyd loop. The unweighted path
# (default) calls palette/kmeans's full k-means directly.
#
# KD-tree NN, SIMD f32x4 are DEFERRED (perf): brute-force O(P·k) here.
# Parallel dispatch of the assignment+sum pass is also DEFERRED: the
# unweighted path delegates to palette/kmeans (which keeps `threads` as a
# contract surface routing to the serial bit-exact reference today), and the
# WSM weighted Lloyd runs its own SERIAL loop here. `opts.parallel`/
# `opts.threads` stay on the contract surface (serial today, the bit-exact
# reference path; a later perf lot wires real dispatch above
# `KmeansMinParallelPoints`). Determinism: a pure function of (image, n,
# opts.seed) — the only randomness is palette/kmeans's seeded SplitMix64.
#
# Layer: image (consumer of image/internal + palette/kmeans +
# palette/types + contrast/ok). Registered by `quantize.nim` as "kmeans" and
# "kmeansPP".
import std/math # `sqrt`. `Inf` comes from `system`.
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/core/result
import UniColor/core/color_error
import UniColor/image/internal
import UniColor/palette/types
import UniColor/palette/kmeans # kmeans, KmeansOpts, kmKpp, kmRandom,
                               # KmeansMinParallelPoints (reuse).
import UniColor/contrast/ok # `deltaE_ok` (convergence).
import UniColor/image/quantize # `QuantizeOpts`, registry.

# OKLab component reader (float64). The image is required to already be in
# OKLab (k-means is perceptual; see `computeKmeansImage`), so no conversion
# here.
proc lab(c: Color): tuple[l, a, b: float64] {.raises: [].} =
  (c.comp(0).float64, c.comp(1).float64, c.comp(2).float64)

# Squared OKLab euclidean distance (no sqrt — monotonic, used for argmin
# assignment).
proc sqDist(a, b: Color): float64 {.raises: [].} =
  let (l1, a1, b1) = lab(a)
  let (l2, a2, b2) = lab(b)
  (l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)

# WSM perceptual salience weight = 1 + OKLab chroma. Achromatic pixels
# (chroma 0) keep weight 1; chromatic pixels are weighted higher (more
# perceptual signal). Documented heuristic — the spec leaves the WSM formula
# open.
proc wsmWeight(c: Color): float64 {.raises: [].} =
  let a = c.comp(1).float64
  let b = c.comp(2).float64
  1.0 + sqrt(a * a + b * b)

# Build an OKLab color from raw coords (validated by `color`).
proc oklabColor(l, a, b: float64): Result[Color, ColorError] {.raises: [].} =
  color(tagOklab, l.float32, a.float32, b.float32)

# Get the init centroids (k-means++ or random) by calling palette/kmeans's
# k-means with maxIter=0: it validates, converts points to OKLab, runs the
# seeded init, and returns the centroids without iterating. Reuses the
# palette-layer init logic (DRY — no duplicate k-means++ here).
proc initCentroids(img: Image, n: int, seed: int64, init: KmeansInit): Result[
    seq[Color], ColorError] {.raises: [].} =
  let kopts = KmeansOpts(seed: seed, k: n, maxIter: 0, init: init,
      tol: 1.0e-4, threads: 1)
  let r = kmeans(img.pixels, kopts)
  if r.isErr:
    return err[seq[Color], ColorError](r.error)
  ok[seq[Color], ColorError](r.get.palette.colors())

# Weighted Lloyd iteration (WSM). Assignment = nearest centroid (brute force,
# index tie-break -> order-stable). Update = weighted mean Σ(wᵢ·pᵢ)/Σwᵢ
# (empty cluster keeps its centroid — no reinitialization noise).
# Convergence = max centroid ΔE_OK shift < tol, or maxIter reached.
# The assignment+weighted-sum pass runs SERIAL (bit-exact reference);
# `parallel`/`threads` are the deferred-parallel contract surface (a later
# perf lot wires real dispatch above `KmeansMinParallelPoints`). The centroid
# update + convergence check is serial (O(k)).
proc weightedLloyd(img: Image, centroids: var seq[Color],
    weights: seq[float64], maxIter: int, tol: float64, parallel: bool,
    threads: int): Result[int, ColorError] {.raises: [].} =
  discard parallel # deferred-parallel contract surface (serial today).
  discard threads
  let pts = img.pixels
  let k = centroids.len
  var iters = 0
  for it in 0 ..< maxIter:
    iters = it + 1
    var wsum = newSeq[float64](k * 3)
    var wcount = newSeq[float64](k)
    # Serial assignment+weighted-sum (bit-exact reference).
    for i in 0 ..< pts.len:
      var bestD = Inf
      var bestC = 0
      for c in 0 ..< k:
        let d = sqDist(pts[i], centroids[c])
        if d < bestD: # strict `<` keeps the lowest centroid index on ties.
          bestD = d
          bestC = c
      let w = weights[i]
      let (l, a, b) = lab(pts[i])
      wsum[bestC * 3] += w * l
      wsum[bestC * 3 + 1] += w * a
      wsum[bestC * 3 + 2] += w * b
      wcount[bestC] += w
    var maxShift = 0.0
    for c in 0 ..< k:
      if wcount[c] <= 0.0:
        continue # empty cluster: keep previous centroid (order-stable).
      let nl = wsum[c * 3] / wcount[c]
      let na = wsum[c * 3 + 1] / wcount[c]
      let nb = wsum[c * 3 + 2] / wcount[c]
      let nR = oklabColor(nl, na, nb)
      if nR.isErr:
        # A bad centroid (NaN/Inf comps) aborts iteration early — surface as
        # InvalidOp (never silent); the caller propagates instead of building
        # a palette from invalid comps.
        return err[int, ColorError](colorError(InvalidOp,
            "weightedLloyd: centroid update produced invalid comps",
            "weightedLloyd"))
      let shift = deltaE_ok(nR.get, centroids[c])
      if shift > maxShift:
        maxShift = shift
      centroids[c] = nR.get
    if maxShift < tol:
      break
  ok[int, ColorError](iters)

proc computeKmeansImage(img: Image, n: int, opts: QuantizeOpts,
    init: KmeansInit): Result[Palette, ColorError] {.raises: [].} =
  ## Perceptual k-means image quantization. Requires `img.workSpace == oklab`
  ## (k-means is perceptual; `extractPalette` converts to OKLab by default).
  ## Returns `n` OKLab centroids as a `palUnordered` qualitative palette
  ## (seed = opts.seed). WSM weighting when `opts.weighting`; otherwise plain
  ## (unweighted) k-means reusing palette/kmeans directly.
  if img.pixels.len == 0:
    return err[Palette, ColorError](colorError(InvalidImage,
        "kmeans: empty image", "computeKmeansImage"))
  if img.workSpace != tagOklab:
    # k-means clusters in OKLab (perceptual). The image must already be in
    # OKLab — `extractPalette` converts once (default space=oklab). A non-
    # OKLab work space with a perceptual algo is an invalid combination
    # (honest InvalidOp, no silent cross-space clustering).
    return err[Palette, ColorError](colorError(InvalidOp,
        "kmeans: requires OKLab work space, got " & $img.workSpace,
        "computeKmeansImage"))
  if n > img.pixels.len:
    return err[Palette, ColorError](colorError(InvalidOp,
        "kmeans: n (" & $n & ") > pixel count (" & $img.pixels.len & ")",
        "computeKmeansImage"))
  if not opts.weighting:
    # Unweighted path: palette/kmeans's full k-means (init + Lloyd +
    # convergence), reused directly. palette/kmeans keeps `threads` as a
    # contract surface routing to the serial path today.
    let kopts = KmeansOpts(seed: opts.seed, k: n, maxIter: opts.maxIter,
        init: init, tol: 1.0e-4, threads: if opts.parallel and
        opts.threads >= 2: opts.threads else: 1)
    let r = kmeans(img.pixels, kopts)
    if r.isErr:
      return err[Palette, ColorError](r.error)
    return ok[Palette, ColorError](r.get.palette)
  # WSM weighted path: init centroids via palette/kmeans (maxIter=0), then a
  # weighted Lloyd.
  let initR = initCentroids(img, n, opts.seed, init)
  if initR.isErr:
    return err[Palette, ColorError](initR.error)
  var centroids = initR.get
  var weights = newSeq[float64](img.pixels.len)
  for i in 0 ..< img.pixels.len:
    weights[i] = wsmWeight(img.pixels[i])
  let wlR = weightedLloyd(img, centroids, weights, opts.maxIter, 1.0e-4,
      opts.parallel, opts.threads)
  if wlR.isErr:
    return err[Palette, ColorError](wlR.error)
  palette(palUnordered, centroids, intentQualitative, opts.seed)

# Bootstrap — register the two k-means variants (idempotent; re-registration
# returns false).
discard registerQuantizeAlgo(QuantizeAlgo(name: "kmeans",
    compute: proc(img: Image, n: int, opts: QuantizeOpts): Result[Palette,
        ColorError] {.raises: [].} = computeKmeansImage(img, n, opts, kmRandom)))
discard registerQuantizeAlgo(QuantizeAlgo(name: "kmeansPP",
    compute: proc(img: Image, n: int, opts: QuantizeOpts): Result[Palette,
        ColorError] {.raises: [].} = computeKmeansImage(img, n, opts, kmKpp)))
