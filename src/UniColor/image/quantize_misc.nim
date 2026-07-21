# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# quantize_misc — median cut, octree, NeuQuant image quantizers. Three
# registered algos, all running in the image's work space (default OKLab, set
# by `extractPalette`) with centroids returned in that space (palUnordered /
# intentQualitative, seed from opts) — same contract as Wu. Each is a faithful,
# compact implementation of the classic algorithm:
#
# - **medianCut** (Heckbert 1980): bounding box per cluster, cut the longest
#   dimension at the median, recurse to `n` boxes. Centroids = box means.
#   Fast, less precise.
# - **octree** (Gervautz-Purgathofer): insert pixels into a depth-8 octree
#   (adaptive comp scaling to 8 bits), then reduce bottom-up — merge the
#   least-significant (smallest-count) internal nodes into leaves until <= `n`
#   leaves. Low memory, fast.
# - **neuquant** (Dekker 1994): 1D Kohonen self-organizing map; seeded pixel
#   sampling, BMU + 1D-ring neighbor update with decaying learning rate +
#   radius. GIF legacy.
#
# Determinism: median cut + octree are deterministic (no RNG). NeuQuant's
# only randomness is the seeded SplitMix64 (seed = opts.seed). KD-tree NN /
# real parallel dispatch / SIMD are a later perf lot — single-threaded here.
# NeuQuant params (init learning rate, radius, decay) are not pinned by the
# spec — documented defaults (spec hole, like WSM).
#
# Layer: image (consumer of image/internal + palette/types + math/rng).
# Registered by `quantize.nim` as "medianCut", "octree", "neuquant".
import std/algorithm # `sort`, `cmp`.
import std/sequtils # `toSeq`.
import UniColor/core/core
import UniColor/core/result
import UniColor/core/color_error
import UniColor/image/internal
import UniColor/palette/types
import UniColor/math/rng # SplitMix64 (NeuQuant seeded sampling).
import UniColor/image/quantize # `QuantizeOpts`, registry.

# Read a comp as float64 (the work space comps — no conversion; the image is
# already in `space`).
proc compF(c: Color, k: int): float64 {.inline.} =
  c.comp(k).float64

# Build a centroid color in the image work space from summed comps and a count.
proc centroidColor(img: Image, sums: array[3, float64], count: float64): Result[
    Color, ColorError] {.raises: [].} =
  if count <= 0.0:
    return err[Color, ColorError](colorError(InvalidOp, "centroid: empty box",
        "centroidColor"))
  color(img.workSpace, (sums[0] / count).float32, (sums[1] / count).float32,
      (sums[2] / count).float32)

# ---------------------------------------------------------------------------
# median cut (Heckbert 1980).
# ---------------------------------------------------------------------------

type McBox = tuple[start, count: int] ## slice [start, start+count) into the
                                       ## permuted pixel index.

# Widest dimension of a box: returns (maxRange, axis). A single-pixel box has
# range 0 on all axes.
proc mcExtent(img: Image, perm: seq[int], b: McBox): tuple[rg: float64,
    axis: int] {.raises: [].} =
  var mn = [Inf, Inf, Inf]
  var mx = [-Inf, -Inf, -Inf]
  for i in b.start ..< b.start + b.count:
    let c = img.pixels[perm[i]]
    for k in 0 .. 2:
      let v = compF(c, k)
      if v < mn[k]:
        mn[k] = v
      if v > mx[k]:
        mx[k] = v
  var rg = 0.0
  var ax = 0
  for k in 0 .. 2:
    let r = mx[k] - mn[k]
    if r > rg:
      rg = r
      ax = k
  (rg, ax)

proc medianCut(img: Image, n: int, opts: QuantizeOpts): Result[Palette,
    ColorError] {.raises: [].} =
  let p = img.pixels.len
  if p == 0:
    return err[Palette, ColorError](colorError(InvalidImage,
        "medianCut: empty image", "medianCut"))
  if n > p:
    return err[Palette, ColorError](colorError(InvalidOp,
        "medianCut: n (" & $n & ") > pixel count (" & $p & ")", "medianCut"))
  var perm = toSeq(0 ..< p)
  var boxes: seq[McBox] = @[(0, p)]
  while boxes.len < n:
    # Pick the cuttable box (>= 2 pixels) with the widest extent. Widest-first
    # is the canonical Heckbert criterion (cut where the variance spread is
    # largest).
    var bi = -1
    var bestRg = -1.0
    var bestAxis = 0
    for i, b in boxes:
      if b.count < 2:
        continue
      let (rg, axis) = mcExtent(img, perm, b)
      if rg > bestRg:
        bestRg = rg
        bi = i
        bestAxis = axis
    if bi < 0:
      break # no box can be cut further (each has < 2 pixels) — fewer than n clusters.
    let b = boxes[bi]
    # Sort the box's slice by the widest axis, then split at the median index.
    let cmp = proc(x, y: int): int {.closure.} =
      cmp(compF(img.pixels[x], bestAxis), compF(img.pixels[y], bestAxis))
    sort(perm.toOpenArray(b.start, b.start + b.count - 1), cmp)
    let mid = b.count div 2
    if mid == 0:
      # count >= 2 but mid 0 only if count==1 — impossible here; guard against
      # an infinite split.
      break
    boxes[bi] = (b.start, mid)
    boxes.add((b.start + mid, b.count - mid))
  var colors: seq[Color] = @[]
  for b in boxes:
    if b.count == 0:
      continue
    var sums = [0.0, 0.0, 0.0]
    for i in b.start ..< b.start + b.count:
      let c = img.pixels[perm[i]]
      for k in 0 .. 2:
        sums[k] += compF(c, k)
    let cR = centroidColor(img, sums, float64(b.count))
    if cR.isErr:
      return err[Palette, ColorError](cR.error)
    colors.add(cR.get)
  if colors.len == 0:
    return err[Palette, ColorError](colorError(InvalidOp,
        "medianCut: produced no colors", "medianCut"))
  palette(palUnordered, colors, intentQualitative, opts.seed)

# ---------------------------------------------------------------------------
# octree (Gervautz-Purgathofer).
# ---------------------------------------------------------------------------

const OctDepth = 8 ## octree depth (8 levels -> 8-bit adaptive comp scale,
                   ## 0..255 per component).

type OctNode = ref object
  children: array[8, OctNode]
  isLeaf: bool
  count: int
  sum: array[3, float64]

# Adaptive per-component scale to [0,255] (8 bits) so the octree index bits are
# meaningful even for a narrow-gamut image (mirrors Wu's adaptive binning).
proc octBounds(img: Image): tuple[mn, mx: array[3, float64]] {.raises: [].} =
  var mn = [Inf, Inf, Inf]
  var mx = [-Inf, -Inf, -Inf]
  for c in img.pixels:
    for k in 0 .. 2:
      let v = compF(c, k)
      if v < mn[k]:
        mn[k] = v
      if v > mx[k]:
        mx[k] = v
  # Degenerate range (single color) -> scale to 0 everywhere (all bits 0, one
  # octree path).
  for k in 0 .. 2:
    if mx[k] <= mn[k]:
      mx[k] = mn[k] + 1.0
  (mn, mx)

# Child index at level d (0..7): bit (7-d) of each scaled comp, comp0 = MSB.
proc octChild(c: Color, d: int, mn, mx: array[3, float64]): int {.raises: [].} =
  var idx = 0
  for k in 0 .. 2:
    let v = (compF(c, k) - mn[k]) / (mx[k] - mn[k])
    var q = if v <= 0.0: 0
      elif v >= 1.0: 255
      else: int(v * 255.0)
    if q < 0:
      q = 0
    elif q > 255:
      q = 255
    let bit = (q shr (OctDepth - 1 - d)) and 1
    idx = (idx shl 1) or bit
  idx

proc octInsert(root: OctNode, c: Color, mn, mx: array[3, float64]) {.raises: [].} =
  var node = root
  for d in 0 ..< OctDepth:
    let ci = octChild(c, d, mn, mx)
    if node.children[ci].isNil:
      node.children[ci] = OctNode()
    node = node.children[ci]
  node.isLeaf = true
  node.count += 1
  for k in 0 .. 2:
    node.sum[k] += compF(c, k)

# Collect internal (non-leaf) nodes by depth, for bottom-up reduction.
proc octCollect(node: OctNode, depth: int, byDepth: var array[OctDepth, seq[
    OctNode]]) {.raises: [].} =
  if node.isLeaf:
    return
  if depth < OctDepth:
    byDepth[depth].add(node)
  for ch in node.children:
    if not ch.isNil:
      octCollect(ch, depth + 1, byDepth)

# Subtree pixel count (children are leaves by the time we sort -> their
# .count).
proc octSubtreeCount(node: OctNode): int {.raises: [].} =
  if node.isLeaf:
    return node.count
  var s = 0
  for ch in node.children:
    if not ch.isNil:
      s += octSubtreeCount(ch)
  s

proc countLeaves(node: OctNode): int {.raises: [].} =
  if node.isLeaf:
    return 1
  for ch in node.children:
    if not ch.isNil:
      result += countLeaves(ch)

proc octree(img: Image, n: int, opts: QuantizeOpts): Result[Palette,
    ColorError] {.raises: [].} =
  let p = img.pixels.len
  if p == 0:
    return err[Palette, ColorError](colorError(InvalidImage,
        "octree: empty image", "octree"))
  if n > p:
    return err[Palette, ColorError](colorError(InvalidOp,
        "octree: n (" & $n & ") > pixel count (" & $p & ")", "octree"))
  let (mn, mx) = octBounds(img)
  let root = OctNode()
  for c in img.pixels:
    octInsert(root, c, mn, mx)
  var leaves = countLeaves(root)
  if leaves > n:
    var byDepth: array[OctDepth, seq[OctNode]]
    octCollect(root, 0, byDepth)
    # Reduce bottom-up (deepest first); within a depth, least-significant
    # (smallest subtree) first — deterministic (count-based, no RNG).
    for d in countdown(OctDepth - 1, 0):
      if leaves <= n:
        break
      byDepth[d].sort(proc(x, y: OctNode): int {.closure.} =
        cmp(octSubtreeCount(x), octSubtreeCount(y)))
      for node in byDepth[d]:
        if leaves <= n:
          break
        if node.isLeaf:
          continue
        # Merge children (all leaves at this point — deeper levels already
        # reduced) into the node.
        var sc = 0
        var ss = [0.0, 0.0, 0.0]
        var nc = 0
        for ci in 0 .. 7:
          let ch = node.children[ci]
          if ch.isNil:
            continue
          if not ch.isLeaf:
            continue # defensive: skip non-leaf children (should not happen bottom-up).
          sc += ch.count
          for k in 0 .. 2:
            ss[k] += ch.sum[k]
          nc += 1
          node.children[ci] = nil
        if nc == 0:
          continue
        node.isLeaf = true
        node.count = sc
        node.sum = ss
        leaves -= (nc - 1)
  # Collect leaf centroids.
  var colors: seq[Color] = @[]
  proc gather(node: OctNode) {.raises: [].} =
    if node.isLeaf:
      if node.count > 0:
        let cR = centroidColor(img, node.sum, float64(node.count))
        if cR.isErr:
          return # defensive — a degenerate leaf is skipped, not fatal.
        colors.add(cR.get)
      return
    for ch in node.children:
      if not ch.isNil:
        gather(ch)
  gather(root)
  if colors.len == 0:
    return err[Palette, ColorError](colorError(InvalidOp,
        "octree: produced no colors", "octree"))
  palette(palUnordered, colors, intentQualitative, opts.seed)

# ---------------------------------------------------------------------------
# NeuQuant (Dekker 1994) — 1D Kohonen self-organizing map.
# ---------------------------------------------------------------------------

# Squared work-space euclidean distance (no sqrt — monotonic, used for BMU
# argmin).
proc nqSqDist(a, b: array[3, float64]): float64 {.inline.} =
  (a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[
      2]) * (a[2] - b[2])

proc neuquant(img: Image, n: int, opts: QuantizeOpts): Result[Palette,
    ColorError] {.raises: [].} =
  let p = img.pixels.len
  if p == 0:
    return err[Palette, ColorError](colorError(InvalidImage,
        "neuquant: empty image", "neuquant"))
  if n > p:
    return err[Palette, ColorError](colorError(InvalidOp,
        "neuquant: n (" & $n & ") > pixel count (" & $p & ")", "neuquant"))
  # Precompute pixels as work-space comp triples (avoid re-reading comps each
  # step).
  var pix = newSeq[array[3, float64]](p)
  for i in 0 ..< p:
    for k in 0 .. 2:
      pix[i][k] = compF(img.pixels[i], k)
  # Init neurons by sampling n pixels at seeded positions (deterministic). May
  # pick duplicates — the SOM separates them during training.
  var rng = initSplitMix64(uint64(opts.seed) xor 0x9E3779B97F4A7C15'u64)
  var neu = newSeq[array[3, float64]](n)
  for i in 0 ..< n:
    neu[i] = pix[int(rng.next() mod uint64(p))]
  # Training: opts.maxIter epochs over the pixel set. Learning rate + radius
  # decay linearly to 0. Defaults (initLr=0.3, initRadius=n/2) are documented —
  # the spec does not pin them (spec hole, like WSM).
  let totalSteps = max(1, opts.maxIter) * p
  let initRadius = float64(max(1, n div 2))
  let initLr = 0.3
  for t in 0 ..< totalSteps:
    let frac = float64(t) / float64(totalSteps)
    let lr = initLr * (1.0 - frac)
    if lr <= 0.0:
      break
    let radius = max(1, int(initRadius * (1.0 - frac)))
    let px = pix[int(rng.next() mod uint64(p))]
    # BMU = nearest neuron.
    var bestD = Inf
    var bmu = 0
    for i in 0 ..< n:
      let d = nqSqDist(px, neu[i])
      if d < bestD: # strict `<` -> lowest index on ties (order-stable).
        bestD = d
        bmu = i
    # Update the BMU and its 1D-ring neighbors (uniform influence within
    # radius).
    for di in -radius .. radius:
      let j = ((bmu + di) mod n + n) mod n
      for k in 0 .. 2:
        neu[j][k] += lr * (px[k] - neu[j][k])
  var colors: seq[Color] = @[]
  for i in 0 ..< n:
    let cR = color(img.workSpace, neu[i][0].float32, neu[i][1].float32,
        neu[i][2].float32)
    if cR.isErr:
      return err[Palette, ColorError](cR.error)
    colors.add(cR.get)
  palette(palUnordered, colors, intentQualitative, opts.seed)

# Bootstrap — register the three misc quantizers (idempotent; re-registration
# returns false).
discard registerQuantizeAlgo(QuantizeAlgo(name: "medianCut",
    compute: medianCut))
discard registerQuantizeAlgo(QuantizeAlgo(name: "octree", compute: octree))
discard registerQuantizeAlgo(QuantizeAlgo(name: "neuquant", compute: neuquant))
