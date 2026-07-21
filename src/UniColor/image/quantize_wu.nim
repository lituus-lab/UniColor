# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# quantize_wu — Xiaolin Wu's color quantization (1992), adapted to a
# perceptual work space. Wu bins the image into a 3D histogram (Q^3 bins,
# Q=16), builds the cumulative moments (weight M0, first M1 per component,
# second M2) as 3D prefix sums so any box's moments are an O(1)
# inclusion-exclusion of 8 corners, then greedily cuts boxes to maximize the
# total within-box variance reduction (the "Maximization of Variance"
# criterion), until `n` boxes are reached or no box can be cut further. Each
# box's centroid = (M1/M0) is a palette color in the work space. Deterministic
# (no RNG), O(pixels) + O(n · Q · boxes).
#
# Faithful to Wu 1992 / the canonical implementation. Runs in the image's
# work space (default OKLab — set by `extractPalette`); the centroids are
# returned in that space. Adaptive per-component binning (min/max over the
# image) adapts to the gamut actually present, so a narrow-gamut image still
# uses the full 16^3 bin resolution.
#
# The raw-moment accumulation (per-pixel bin scatter into the 5 moment
# arrays) is the genuinely parallel hot path (integer bin-counts, no registry
# read in the inner loop), but it runs SERIAL here — real thread-pool
# dispatch is a later perf lot. `opts.parallel`/`opts.threads` stay on the
# contract surface so callers opt in without API churn when that lot wires
# real parallelism; today both route to the serial (bit-exact reference)
# path. `buildPrefix` (the 3-pass cumulative prefix sum) is inherently
# sequential and O(S^3) ~ 5k cells, negligible. Deterministic (no RNG).
#
# Layer: image (consumer of image/internal + palette/types). Registered by
# `quantize.nim` as "wu".
import std/math # `floor`.
import UniColor/core/core
import UniColor/core/result
import UniColor/core/color_error
import UniColor/image/internal
import UniColor/palette/types
import UniColor/image/quantize # `QuantizeOpts`, registry.

const
  QuantBins = 16    ## bins per component (Q). 16^3 = 4096 histogram cells —
                    ## fine-grained yet cheap.
  S = QuantBins + 1 ## prefix-sum stride (indices 0..Q, 0 = empty boundary).
  # Threshold a future parallel dispatch will gate on: below this pixel count
  # the spawn overhead (~us/task) dominates the moment accumulation, so
  # `opts.parallel` would fall back to the serial path. Tuned for the
  # per-pixel cost (a bin scatter into 5 S^3 arrays): large images (>=4k px)
  # split across threads for a real speedup, small images stay serial.
  WuMinParallelPixels* = 4096

type
  Box = tuple[r1, r2, g1, g2, b1, b2: int] ## inclusive bin ranges of a 3D
                                            ## color box.

# Flat 3D index into a (S^3) prefix-sum array: x,y,z in [0..Q].
proc fi(x, y, z: int): int {.inline.} =
  (x * S + y) * S + z

# Bin a component value into [0..QuantBins-1] using the adaptive [cmin, cmax]
# range. A degenerate range (cmax == cmin) maps everything to bin 0
# (single-bin box — not further cuttable).
proc binOf(c, cmin, cmax: float64): int {.inline.} =
  if cmax <= cmin:
    return 0
  var b = int(floor((c - cmin) / (cmax - cmin) * float64(QuantBins)))
  if b < 0:
    b = 0
  elif b >= QuantBins:
    b = QuantBins - 1
  b

# Inclusion-exclusion: the sum over box [r1..r2][g1..g2][b1..b2] from the 3D
# prefix array `p` (where p[x][y][z] = cumulative sum over bins
# [0..x-1][0..y-1][0..z-1]).
proc boxSum(p: openArray[float64], b: Box): float64 {.inline.} =
  let
    hiR = b.r2 + 1
    hiG = b.g2 + 1
    hiB = b.b2 + 1
  p[fi(hiR, hiG, hiB)] - p[fi(b.r1, hiG, hiB)] - p[fi(hiR, b.g1, hiB)] -
      p[fi(hiR, hiG, b.b1)] + p[fi(b.r1, b.g1, hiB)] + p[fi(b.r1, hiG, b.b1)] +
      p[fi(hiR, b.g1, b.b1)] - p[fi(b.r1, b.g1, b.b1)]

# Within-box total squared error: wt*var = m2*wt - (mr^2+mg^2+mb^2). Computed
# directly (no division), so it is exact even when wt is small. Returns 0 for
# an empty box (wt == 0).
proc boxError(wt, mr, mg, mb, m2: float64): float64 {.inline.} =
  if wt <= 0.0:
    return 0.0
  m2 * wt - (mr * mr + mg * mg + mb * mb)

# Find the cut (axis + position) of `b` that maximizes the variance
# reduction. Returns the reduction and the (axis, pos): axis 0=r, 1=g, 2=b;
# pos is the last bin of the LOW child (low = [lo..pos], high = [pos+1..hi]).
# reduction < 0 means the box cannot reduce error (a single-bin or uniform
# box); the caller treats reduction <= 0 as non-cuttable.
proc bestCut(pWt, pMr, pMg, pMb, pM2: openArray[float64], b: Box): tuple[
    reduction: float64, axis: int, pos: int] =
  var best = -1.0
  var bestAxis = -1
  var bestPos = -1
  let parentWt = boxSum(pWt, b)
  let parentMr = boxSum(pMr, b)
  let parentMg = boxSum(pMg, b)
  let parentMb = boxSum(pMb, b)
  let parentM2 = boxSum(pM2, b)
  let parentErr = boxError(parentWt, parentMr, parentMg, parentMb, parentM2)
  # Try each axis; for each, scan the valid cut positions.
  for axis in 0 .. 2:
    let lo = if axis == 0: b.r1 elif axis == 1: b.g1 else: b.b1
    let hi = if axis == 0: b.r2 elif axis == 1: b.g2 else: b.b2
    if hi <= lo:
      continue # single bin on this axis — no cut here.
    for pos in lo ..< hi:
      var c1 = b
      var c2 = b
      if axis == 0:
        c1.r2 = pos
        c2.r1 = pos + 1
      elif axis == 1:
        c1.g2 = pos
        c2.g1 = pos + 1
      else:
        c1.b2 = pos
        c2.b1 = pos + 1
      let w1 = boxSum(pWt, c1)
      let w2 = boxSum(pWt, c2)
      if w1 <= 0.0 or w2 <= 0.0:
        continue # empty child — not a real cut.
      let e1 = boxError(w1, boxSum(pMr, c1), boxSum(pMg, c1), boxSum(pMb, c1),
              boxSum(pM2, c1))
      let e2 = boxError(w2, boxSum(pMr, c2), boxSum(pMg, c2), boxSum(pMb, c2),
              boxSum(pM2, c2))
      let red = parentErr - (e1 + e2)
      if red > best:
        best = red
        bestAxis = axis
        bestPos = pos
  (best, bestAxis, bestPos)

# Build the 3D prefix sum in place: three 1D cumulative passes (x, then y,
# then z). After this, `a[fi(x+1,y+1,z+1)]` holds the sum over bins
# [0..x][0..y][0..z] — the O(1) box-query basis.
proc buildPrefix(a: var openArray[float64]) {.raises: [].} =
  for x in 1 ..< S:
    for y in 0 ..< S:
      for z in 0 ..< S:
        a[fi(x, y, z)] += a[fi(x - 1, y, z)]
  for x in 0 ..< S:
    for y in 1 ..< S:
      for z in 0 ..< S:
        a[fi(x, y, z)] += a[fi(x, y - 1, z)]
  for x in 0 ..< S:
    for y in 0 ..< S:
      for z in 1 ..< S:
        a[fi(x, y, z)] += a[fi(x, y, z - 1)]

proc computeWu(img: Image, n: int, opts: QuantizeOpts): Result[Palette,
    ColorError] {.raises: [].} =
  ## Wu quantization of `img` (in its work space) into <= `n` centroid colors.
  ## Builds the 3D moment prefix sums, then greedily cuts boxes by max
  ## variance reduction. Deterministic. `opts.parallel`/`opts.threads` are
  ## the deferred-parallel contract surface (serial today, the bit-exact
  ## reference path; a later perf lot wires real dispatch above
  ## `WuMinParallelPixels`).
  if img.pixels.len == 0:
    return err[Palette, ColorError](colorError(InvalidImage,
        "wu: empty image", "computeWu"))
  discard opts.parallel # deferred-parallel contract surface (serial today).
  discard opts.threads
  # 1. Adaptive per-component min/max over the image (in workSpace comps).
  var cmin = [Inf, Inf, Inf]
  var cmax = [-Inf, -Inf, -Inf]
  for c in img.pixels:
    for k in 0 .. 2:
      let v = c.comp(k).float64
      if v < cmin[k]:
        cmin[k] = v
      if v > cmax[k]:
        cmax[k] = v
  # 2. Build the raw moments at prefix index [bi+1][bj+1][bk+1]. Serial
  # (bit-exact reference) — the parallel scatter is deferred (see
  # `WuMinParallelPixels`).
  var pWt = newSeq[float64](S * S * S)
  var pMr = newSeq[float64](S * S * S)
  var pMg = newSeq[float64](S * S * S)
  var pMb = newSeq[float64](S * S * S)
  var pM2 = newSeq[float64](S * S * S)
  for c in img.pixels:
    let l0 = c.comp(0).float64
    let l1 = c.comp(1).float64
    let l2 = c.comp(2).float64
    let bi = binOf(l0, cmin[0], cmax[0])
    let bj = binOf(l1, cmin[1], cmax[1])
    let bk = binOf(l2, cmin[2], cmax[2])
    let p = fi(bi + 1, bj + 1, bk + 1)
    pWt[p] += 1.0
    pMr[p] += l0
    pMg[p] += l1
    pMb[p] += l2
    pM2[p] += l0 * l0 + l1 * l1 + l2 * l2
  # 3. 3D prefix sums (three 1D cumulative passes — simpler and exact). Each
  # pass is a separate helper call because `var openArray` is the clean way to
  # mutate a seq by reference (a `let` alias would be immutable — Nim seqs are
  # value types).
  buildPrefix(pWt)
  buildPrefix(pMr)
  buildPrefix(pMg)
  buildPrefix(pMb)
  buildPrefix(pM2)
  # 4. Greedy box cutting. Start with the full range; repeatedly cut the box
  # whose best cut gives the largest variance reduction, until `n` boxes or
  # no box is cuttable.
  var boxes: seq[Box] = @[(0, QuantBins - 1, 0, QuantBins - 1, 0,
      QuantBins - 1)]
  while boxes.len < n:
    var bestBoxIdx = -1
    var bestRed = 1.0e-12 # require a strictly positive, non-trivial reduction.
    var bestCutAxis = -1
    var bestCutPos = -1
    for i, b in boxes:
      let (red, axis, pos) = bestCut(pWt, pMr, pMg, pMb, pM2, b)
      if axis >= 0 and red > bestRed:
        bestRed = red
        bestBoxIdx = i
        bestCutAxis = axis
        bestCutPos = pos
    if bestBoxIdx < 0:
      break # no box can be cut further — fewer than n colors.
    let target = boxes[bestBoxIdx]
    var c1 = target
    var c2 = target
    if bestCutAxis == 0:
      c1.r2 = bestCutPos
      c2.r1 = bestCutPos + 1
    elif bestCutAxis == 1:
      c1.g2 = bestCutPos
      c2.g1 = bestCutPos + 1
    else:
      c1.b2 = bestCutPos
      c2.b1 = bestCutPos + 1
    boxes[bestBoxIdx] = c1 # replace parent with low child ...
    boxes.add(c2) # ... and append high child.
  # 5. Centroid per box = (M1/M0) in the work space. Skip empty boxes
  # (wt == 0).
  var colors: seq[Color] = @[]
  for b in boxes:
    let wt = boxSum(pWt, b)
    if wt <= 0.0:
      continue
    let mr = boxSum(pMr, b)
    let mg = boxSum(pMg, b)
    let mb = boxSum(pMb, b)
    let cR = color(img.workSpace, (mr / wt).float32, (mg / wt).float32,
        (mb / wt).float32)
    if cR.isErr:
      return err[Palette, ColorError](cR.error)
    colors.add(cR.get)
  if colors.len == 0:
    return err[Palette, ColorError](colorError(InvalidOp,
        "wu: produced no colors (degenerate image)", "computeWu"))
  palette(palUnordered, colors, intentQualitative, opts.seed)

# Bootstrap — register Wu as the default quantizer ("wu").
discard registerQuantizeAlgo(QuantizeAlgo(name: "wu", compute: computeWu))
