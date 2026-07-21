# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# palette/kmeans — perceptual k-means clustering. Clusters a set of colors in
# OKLab (perceptual space) into `k` centroids via Lloyd's algorithm: k-means++
# seeded init (robust) or random, brute-force nearest-centroid assignment with an
# INDEX tie-break (order-stable: the lowest centroid index wins on equidistant
# points), centroid update = componentwise OKLab mean, convergence when the max
# centroid shift (ΔE_OK) drops below `tol`. KD-tree NN and SIMD are deferred
# (brute force is O(P·k), fine for k <= 256).
#
# The assignment+sum pass is SERIAL today (the bit-exact reference): the
# `threads` field stays on `KmeansOpts` as a contract surface — a deferred
# parallel dispatch will honor it and must remain thread-count-invariant within
# TOL_NUMERIC. `KmeansMinParallelPoints` is the threshold that deferred path
# will gate on (below it the spawn overhead dominates). Determinism: a pure
# function of (points, k, opts.seed) — the only randomness is the seeded
# SplitMix64. Input is `openArray[Color]` (any space -> OKLab); the output
# palette stores centroids in OKLab.
import std/math # `sqrt`, `Inf`, `max`.
import std/options
import std/tables
import UniColor/core/core
import UniColor/conversion/conversion # `to` (points -> OKLab).
import UniColor/contrast/contrast # `deltaE_ok` (energy + convergence).
import UniColor/math/rng # SplitMix64 (deterministic init).
import UniColor/palette/types

type
  KmeansInit* = enum
    kmRandom ## each centroid = a random point (seeded).
    kmKpp    ## k-means++ (seeded, D²-proportional pick — robust init).

  KmeansOpts* = object
    seed*: int64      ## sole source of randomness (deterministic); seed=0 canonical.
    k*: int           ## number of clusters, >= 1 and <= number of points.
    maxIter*: int     ## iteration cap (>= 0); default 100.
    init*: KmeansInit ## default kmKpp.
    tol*: float64     ## convergence: max centroid ΔE_OK shift < tol; default 1e-4.
    threads*: int     ## #threads contract surface (>= 1). Serial today; a deferred
                      ## parallel dispatch will honor `>= 2` above
                      ## `KmeansMinParallelPoints` and must stay thread-count-
                      ## invariant within TOL_NUMERIC.

  KmeansResult* = object
    palette*: Palette ## k centroids in OKLab (palUnordered, qualitative, seed = opts.seed).
    sizes*: seq[int] ## cluster sizes in centroid-index order (order-stable).
    energy*: float64 ## total within-cluster ΔE_OK (lower = tighter clusters).
    iterations*: int ## iterations actually performed.
    warning*: string

  KmeansAlgo* = object
    name*: string
    compute*: proc(points: openArray[Color], opts: KmeansOpts): Result[
        KmeansResult, ColorError] {.raises: [].}

proc defaultKmeansOpts*(k: int): KmeansOpts {.raises: [].} =
  ## Sensible defaults: k-means++ init, 100 iterations, tol 1e-4, seed 0.
  KmeansOpts(seed: 0, k: k, maxIter: 100, init: kmKpp, tol: 1.0e-4, threads: 1)

const
  # Threshold the deferred parallel dispatch will gate on: below this point
  # count the spawn overhead (~µs/task) dominates the assignment+sum work, so
  # `threads >= 2` would fall back to the serial path. Tuned for the measured
  # per-point cost (a brute-force nearest-centroid scan over k <= 256).
  KmeansMinParallelPoints* = 4096

var kmeansByName: Table[string, KmeansAlgo]

proc registerKmeansAlgo*(a: KmeansAlgo): bool {.raises: [].} =
  ## Register a clustering algorithm by name. Returns `true` if added, `false`
  ## if the name is already present (no silent overwrite).
  if kmeansByName.hasKey(a.name):
    return false
  kmeansByName[a.name] = a
  true

proc lookupKmeansAlgo*(name: string): Option[KmeansAlgo] {.raises: [].} =
  if kmeansByName.hasKey(name):
    some(kmeansByName.getOrDefault(name))
  else:
    none(KmeansAlgo)

proc kmeansAlgoCount*(): int {.raises: [].} = kmeansByName.len

# OKLab component reader as float64.
proc lab(c: Color): tuple[l, a, b: float64] {.raises: [].} =
  (c.comp(0).float64, c.comp(1).float64, c.comp(2).float64)

# Squared OKLab euclidean distance (no sqrt — monotonic, used for argmin).
proc sqDist(a, b: Color): float64 {.raises: [].} =
  let (l1, a1, b1) = lab(a)
  let (l2, a2, b2) = lab(b)
  (l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)

# Build an OKLab color from raw coords (validated by `color`).
proc oklabColor(l, a, b: float64): Result[Color, ColorError] {.raises: [].} =
  color(tagOklab, l.float32, a.float32, b.float32)

# Convert all points to OKLab once (cache); bad conversions propagate.
proc toOklabSeq(points: openArray[Color]): Result[seq[Color],
    ColorError] {.raises: [].} =
  var outSeq: seq[Color] = @[]
  for p in points:
    let r = p.to(tagOklab)
    if r.isErr:
      return err[seq[Color], ColorError](r.error)
    outSeq.add(r.get)
  ok[seq[Color], ColorError](outSeq)

# k-means++ init: first centroid random, then D²-proportional picks (seeded,
# deterministic).
proc kppInit(rng: var SplitMix64, pts: seq[Color], k: int): seq[
    Color] {.raises: [].} =
  let n = pts.len
  result = newSeq[Color](k)
  result[0] = pts[int(rng.next() mod uint64(n))]
  for c in 1 ..< k:
    var d2 = newSeq[float64](n)
    var total = 0.0
    for i in 0 ..< n:
      var nd = Inf
      for j in 0 ..< c:
        let dd = sqDist(pts[i], result[j])
        if dd < nd:
          nd = dd
      d2[i] = nd
      total += nd
    if total <= 0.0: # all points coincide with chosen centroids -> random pick.
      result[c] = pts[int(rng.next() mod uint64(n))]
    else:
      let r = rng.nextFloat() * total
      var cum = 0.0
      var chosen = n - 1
      for i in 0 ..< n:
        cum += d2[i]
        if cum >= r:
          chosen = i
          break
      result[c] = pts[chosen]

proc randomInit(rng: var SplitMix64, pts: seq[Color], k: int): seq[
    Color] {.raises: [].} =
  let n = pts.len
  result = newSeq[Color](k)
  for c in 0 ..< k:
    result[c] = pts[int(rng.next() mod uint64(n))]

proc buildPalette(centroids: seq[Color], seed: int64): Result[Palette, ColorError] {.
    raises: [].} =
  palette(palUnordered, centroids, intentQualitative, seed)

proc kmeans*(points: openArray[Color], opts: KmeansOpts): Result[KmeansResult,
    ColorError] {.raises: [].} =
  ## Perceptual k-means in OKLab. Returns `k` centroids as a `palUnordered`
  ## qualitative palette (seed = opts.seed) plus cluster sizes and the
  ## within-cluster ΔE_OK energy.
  if points.len == 0:
    return err[KmeansResult, ColorError](colorError(InvalidColor,
        "kmeans: empty point set", "kmeans"))
  if opts.k < 1:
    return err[KmeansResult, ColorError](colorError(InvalidColor,
        "kmeans: k must be >= 1, got " & $opts.k, "kmeans"))
  if opts.k > points.len:
    return err[KmeansResult, ColorError](colorError(InvalidColor,
        "kmeans: k (" & $opts.k & ") > number of points (" & $points.len & ")",
        "kmeans"))
  if opts.maxIter < 0:
    return err[KmeansResult, ColorError](colorError(InvalidColor,
        "kmeans: maxIter must be >= 0, got " & $opts.maxIter, "kmeans"))
  if opts.threads < 1:
    return err[KmeansResult, ColorError](colorError(InvalidColor,
        "kmeans: threads must be >= 1, got " & $opts.threads, "kmeans"))
  let ptsR = toOklabSeq(points)
  if ptsR.isErr:
    return err[KmeansResult, ColorError](ptsR.error)
  let pts = ptsR.get
  var rng = initSplitMix64(uint64(opts.seed) xor 0x9E3779B97F4A7C15'u64)
  var centroids = if opts.init == kmKpp: kppInit(rng, pts, opts.k)
    else: randomInit(rng, pts, opts.k)
  var sizes = newSeq[int](opts.k)
  var energy = 0.0
  var iters = 0
  if opts.maxIter == 0:
    let pR = buildPalette(centroids, opts.seed)
    if pR.isErr:
      return err[KmeansResult, ColorError](pR.error)
    return ok[KmeansResult, ColorError](KmeansResult(palette: pR.get,
        sizes: sizes, energy: 0.0, iterations: 0, warning: ""))
  var assign = newSeq[int](pts.len) # nearest-centroid index per point.
  for it in 0 ..< opts.maxIter:
    iters = it + 1
    # Assignment + sum (index tie-break: strict `<` keeps the lowest centroid
    # index on equidistant pts — order-stable). The nearest centroid per point
    # is computed once and stored in `assign`, then reused for the component
    # sums below — the centroids are unchanged between assignment and update, so
    # a second nearest-centroid search would be redundant O(N·K) work.
    sizes = newSeq[int](opts.k)
    energy = 0.0
    var sums = newSeq[float64](opts.k * 3)
    for i in 0 ..< pts.len:
      var bestD = Inf
      var bestC = 0
      for c in 0 ..< opts.k:
        let d = sqDist(pts[i], centroids[c])
        if d < bestD:
          bestD = d
          bestC = c
      assign[i] = bestC
      sizes[bestC] += 1
      energy += sqrt(bestD) # ΔE_OK to the assigned centroid.
    for i in 0 ..< pts.len:
      let c = assign[i]
      let (l, a, b) = lab(pts[i])
      sums[c * 3] += l
      sums[c * 3 + 1] += a
      sums[c * 3 + 2] += b
    # Update: each centroid = componentwise mean of its points (empty cluster
    # keeps its value).
    var maxShift = 0.0
    for c in 0 ..< opts.k:
      if sizes[c] == 0:
        continue # keep previous centroid (order-stable: no reinit noise).
      let nl = sums[c * 3] / float64(sizes[c])
      let na = sums[c * 3 + 1] / float64(sizes[c])
      let nb = sums[c * 3 + 2] / float64(sizes[c])
      let nR = oklabColor(nl, na, nb)
      if nR.isErr:
        return err[KmeansResult, ColorError](nR.error)
      let shift = deltaE_ok(nR.get, centroids[c])
      if shift > maxShift:
        maxShift = shift
      centroids[c] = nR.get
    if maxShift < opts.tol:
      break
  let pR = buildPalette(centroids, opts.seed)
  if pR.isErr:
    return err[KmeansResult, ColorError](pR.error)
  ok[KmeansResult, ColorError](KmeansResult(palette: pR.get, sizes: sizes,
      energy: energy, iterations: iters, warning: ""))

proc quantize*(points: openArray[Color], opts: KmeansOpts,
    algo: string): Result[KmeansResult, ColorError] {.raises: [].} =
  ## Dispatch to a registered clustering algorithm by name. Unknown ->
  ## `UnknownAlgorithm`.
  let aOpt = lookupKmeansAlgo(algo)
  if aOpt.isNone:
    return err[KmeansResult, ColorError](colorError(UnknownAlgorithm,
        "quantize: unknown algorithm '" & algo & "'", "quantize"))
  aOpt.get.compute(points, opts)

# Bootstrap: register the built-in perceptual k-means (idempotent —
# re-registration returns false).
discard registerKmeansAlgo(KmeansAlgo(name: "kmeans", compute: kmeans))
