# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# histogram — 3D OKLCH binned histogram + dominant colors. Bins each
# pixel into a (L, C, H) cell — L and C adaptively scaled to the image's
# range (mirrors Wu/octree adaptive binning), H fixed over [0, 360) — then
# selects the dominant colors as the heaviest bins (modes), weighted by
# pixel count (or WSM perceptual salience), filtered by `minArea`, merged
# by `minDeltaE_OK`, and sorted by weight descending with an order-stable
# tie-break (bin index) for determinism.
#
# The histogram is built in OKLab (the image work space, converted once via
# `toWorkSpace`); L is read directly and C/H are derived from the a/b comps
# (C = sqrt(a²+b²), H = atan2(b,a)) — no OKLCH hub round-trip, so the
# hue-0/360 boundary nuance is controlled here (H normalized to [0,360)).
# The returned dominant colors are OKLab centroid colors (the bin means) —
# explicit, no magic (the caller converts for display). Determinism: fixed
# bins, order-stable reductions — no RNG.
#
# Layer: image (consumer of image/internal + contrast/ok). Deterministic.
import std/math # `sqrt`, `arctan2`, `PI`. `Inf` comes from `system`.
import std/tables # `Table` (sparse 3D histogram).
import std/algorithm # `sort`, `cmp`.
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/core/result
import UniColor/core/color_error
import UniColor/image/internal
import UniColor/contrast/ok # `deltaE_ok` (merge close dominant colors).

type
  BinKey = tuple[l, c, h: int] ## 3D bin index (bL, bC, bH).

  BinAccum* = object
    ## Per-bin accumulator: pixel count, selection weight, and OKLab comp
    ## sums (for the centroid).
    count*: int
    weight*: float64
    sumL*, sumA*, sumB*: float64

  Histogram* = object
    ## Sparse 3D OKLCH histogram (only non-empty bins are stored).
    ## `binL`/`binC`/`binH` are the per-axis bin counts; `lMin`/`lMax`/
    ## `cMin`/`cMax` the adaptive L/C ranges.
    bins*: Table[BinKey, BinAccum]
    binL*: int
    binC*: int
    binH*: int
    lMin*, lMax*: float64
    cMin*, cMax*: float64

  DominantOpts* = object
    ## Options for `dominantColors`. `binL`/`binC`/`binH` = per-axis bin
    ## counts (defaults 16/16/24). `minArea` = minimum bin weight to keep
    ## (default 1.0 = keep every non-empty bin). `minDeltaE` = merge dominant
    ## colors closer than this ΔE_OK (default 0.0 = no merge). `weighting` =
    ## WSM (weight by 1 + OKLab chroma instead of pixel count — same
    ## documented heuristic as quantize_kmeans). `parallel`/`threads` are the
    ## deferred-parallel contract surface (serial today, the bit-exact
    ## reference path; a later perf lot wires real dispatch above
    ## `DominantMinParallelPixels`).
    binL*: int
    binC*: int
    binH*: int
    minArea*: float64
    minDeltaE*: float64
    weighting*: bool
    parallel*: bool
    threads*: int

const
  DefaultBinL* = 16
  DefaultBinC* = 16
  DefaultBinH* = 24
  # Threshold a future parallel dispatch will gate on: below this pixel
  # count the spawn overhead (~us/task) dominates the binning work, so
  # `parallel` would fall back to the serial path. Tuned for the measured
  # binning cost (~hundreds of ns/px with a Table insert); large images
  # (>=4k px) split across threads for a real speedup, small images stay
  # serial. Honest threshold — not cargo-cult.
  DominantMinParallelPixels* = 4096

proc defaultDominantOpts*(): DominantOpts {.raises: [].} =
  ## Defaults: 16/16/24 bins, keep every non-empty bin (minArea 1), no
  ## ΔE_OK merge, count weighting, serial (parallel=false — the bit-exact
  ## reference path).
  DominantOpts(binL: DefaultBinL, binC: DefaultBinC, binH: DefaultBinH,
      minArea: 1.0, minDeltaE: 0.0, weighting: false, parallel: false,
      threads: 0)

# Bin a value in [vMin, vMax] into [0, nBins-1]; a degenerate range maps
# everything to bin 0.
proc binOf(v, vMin, vMax: float64, nBins: int): int {.inline.} =
  if vMax <= vMin:
    return 0
  var b = int((v - vMin) / (vMax - vMin) * float64(nBins))
  if b < 0:
    b = 0
  elif b >= nBins:
    b = nBins - 1
  b

# Hue bin in [0, binH-1] from a hue in degrees (normalized to [0,360)).
proc hueBin(hDeg: float64, nBins: int): int {.inline.} =
  let h = ((hDeg mod 360.0) + 360.0) mod 360.0
  int(h / 360.0 * float64(nBins)) mod nBins

# WSM perceptual salience weight = 1 + OKLab chroma (same documented
# heuristic as quantize_kmeans).
proc wsmWeight(a, b: float64): float64 {.inline.} =
  1.0 + sqrt(a * a + b * b)

proc buildHistogram*(img: Image, opts: DominantOpts): Result[Histogram,
    ColorError] {.raises: [].} =
  ## Build a 3D OKLCH-binned histogram of `img` in OKLab. The image is
  ## converted to OKLab once (immutably); L is read directly, C/H derived
  ## from a/b. Adaptive L/C ranges (image min/max), H over [0,360).
  ## `weighting=true` accumulates WSM weight (1 + chroma) instead of pixel
  ## count. `opts.parallel`/`opts.threads` are the deferred-parallel
  ## contract surface (serial today, the bit-exact reference path).
  if img.isEmpty():
    return err[Histogram, ColorError](colorError(InvalidImage,
        "buildHistogram: empty image", "buildHistogram"))
  if opts.binL < 1 or opts.binC < 1 or opts.binH < 1:
    return err[Histogram, ColorError](colorError(InvalidOp,
        "buildHistogram: bin counts must be >= 1", "buildHistogram"))
  discard opts.parallel # deferred-parallel contract surface (serial today).
  discard opts.threads
  let convR = img.toWorkSpace(tagOklab)
  if convR.isErr:
    return err[Histogram, ColorError](convR.error)
  let okImg = convR.get
  var lMin = Inf
  var lMax = -Inf
  var cMin = Inf
  var cMax = -Inf
  for c in okImg.pixels:
    let l0 = c.comp(0).float64
    let a = c.comp(1).float64
    let b = c.comp(2).float64
    let cc = sqrt(a * a + b * b)
    if l0 < lMin:
      lMin = l0
    if l0 > lMax:
      lMax = l0
    if cc < cMin:
      cMin = cc
    if cc > cMax:
      cMax = cc
  var hist = Histogram(bins: initTable[BinKey, BinAccum](), binL: opts.binL,
      binC: opts.binC, binH: opts.binH, lMin: lMin, lMax: lMax, cMin: cMin,
      cMax: cMax)
  # Binning pass — serial (bit-exact reference). The parallel scatter is
  # deferred (see `DominantMinParallelPixels`).
  for c in okImg.pixels:
    let l0 = c.comp(0).float64
    let a = c.comp(1).float64
    let b = c.comp(2).float64
    let cc = sqrt(a * a + b * b)
    let hDeg = arctan2(b, a) * 180.0 / PI
    let key: BinKey = (binOf(l0, lMin, lMax, opts.binL),
        binOf(cc, cMin, cMax, opts.binC), hueBin(hDeg, opts.binH))
    var acc = hist.bins.getOrDefault(key)
    acc.count += 1
    acc.weight += (if opts.weighting: wsmWeight(a, b) else: 1.0)
    acc.sumL += l0
    acc.sumA += a
    acc.sumB += b
    hist.bins[key] = acc
  ok[Histogram, ColorError](hist)

# A sortable dominant entry: the bin key (for the order-stable tie-break),
# its weight, and the centroid OKLab comps (mean over the bin's pixels).
type DomEntry = object
  key: BinKey
  weight: float64
  l, a, b: float64

# Order-stable sort: heavier weight first; on ties, the smaller bin key (l,
# then c, then h) first. Deterministic (no RNG).
proc domCmp(x, y: DomEntry): int {.raises: [].} =
  if x.weight != y.weight:
    return cmp(y.weight, x.weight) # descending weight.
  if x.key.l != y.key.l:
    return cmp(x.key.l, y.key.l)
  if x.key.c != y.key.c:
    return cmp(x.key.c, y.key.c)
  cmp(x.key.h, y.key.h)

proc dominantColors*(img: Image, n: int, opts = defaultDominantOpts()): Result[
    seq[Color], ColorError] {.raises: [].} =
  ## The `n` dominant colors of `img`: histogram modes weighted by pixel
  ## count (or WSM if `opts.weighting`), filtered by `minArea`, merged by
  ## `minDeltaE_OK`, sorted by weight descending with an order-stable
  ## tie-break. Returns OKLab centroid colors (the bin means) — convert for
  ## display if needed (explicit, no magic). `n < 1` -> `InvalidOp`; empty
  ## image -> `InvalidImage`. Deterministic.
  if n < 1:
    return err[seq[Color], ColorError](colorError(InvalidOp,
        "dominantColors: n must be >= 1, got " & $n, "dominantColors"))
  let hR = buildHistogram(img, opts)
  if hR.isErr:
    return err[seq[Color], ColorError](hR.error)
  let hist = hR.get
  # Collect bins above `minArea` as dominant entries (centroid = comp mean).
  var entries: seq[DomEntry] = @[]
  for key, acc in hist.bins.pairs:
    if acc.weight < opts.minArea:
      continue
    let cnt = float64(acc.count)
    entries.add(DomEntry(key: key, weight: acc.weight, l: acc.sumL / cnt,
        a: acc.sumA / cnt, b: acc.sumB / cnt))
  entries.sort(domCmp)
  # Merge entries closer than `minDeltaE` (ΔE_OK): greedily, in sorted
  # (weight) order, each candidate is either accepted or merged into the
  # closest already-accepted centroid (weighted mean of OKLab comps).
  # Deterministic (sorted order). minDeltaE <= 0 disables merging.
  var accepted: seq[DomEntry] = @[]
  for e in entries:
    if accepted.len == 0 or opts.minDeltaE <= 0.0:
      accepted.add(e)
      # Merging is off (minDeltaE <= 0): `accepted` only grows by adding, so
      # once it holds n entries the full result is known — stop iterating.
      if opts.minDeltaE <= 0.0 and accepted.len >= n:
        break
      continue
    var closestIdx = -1
    var closestD = Inf
    for j, a2 in accepted:
      let ca = color(tagOklab, e.l.float32, e.a.float32, e.b.float32)
      let cb = color(tagOklab, a2.l.float32, a2.a.float32, a2.b.float32)
      let d = deltaE_ok(ca.get, cb.get) # both OKLab, validated comps -> .get
                                        # is safe.
      if d < closestD:
        closestD = d
        closestIdx = j
    if closestIdx >= 0 and closestD < opts.minDeltaE:
      # Merge e into accepted[closestIdx] (weighted mean of comps).
      let a2 = accepted[closestIdx]
      let w = e.weight + a2.weight
      accepted[closestIdx] = DomEntry(key: a2.key, weight: w,
          l: (e.l * e.weight + a2.l * a2.weight) / w,
          a: (e.a * e.weight + a2.a * a2.weight) / w,
          b: (e.b * e.weight + a2.b * a2.weight) / w)
    else:
      accepted.add(e)
  # Take the top n (the sort + merge already ordered by weight).
  var resultColors: seq[Color] = @[]
  for i in 0 ..< min(n, accepted.len):
    let e = accepted[i]
    let cR = color(tagOklab, e.l.float32, e.a.float32, e.b.float32)
    if cR.isErr:
      return err[seq[Color], ColorError](cR.error)
    resultColors.add(cR.get)
  ok[seq[Color], ColorError](resultColors)
