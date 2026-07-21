# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# dither — error-diffusion + ordered dithering to a uniform per-component
# level count. Reduces posterisation when quantising to a limited gamut
# (ANSI 256, 8-bit) by spreading (diffusion) or ordering (Bayer) the
# quantisation error. Four registered algos:
#
# - **floydSteinberg** (default): error diffusion, 4-tap kernel (7/3/5/1
#   sixteenths).
# - **atkinson**: error diffusion, 6-tap kernel at 1/8 each (distributes 3/4
#   of the error — contrast is preserved, the rest is lost, the classic
#   Atkinson look).
# - **jarvis**: Jarvis-Judice-Ninke, 12-tap two-row diffusion (wider spread).
# - **bayer**: ordered 4x4 threshold matrix — deterministic by nature, no
#   raster diffusion, no animated artefacts.
#
# Determinism: error diffusion is deterministic by FIXED raster traversal
# (row-major, left->right, top->bottom) — no RNG; Bayer is ordered by nature.
# `opts.seed` is unused (documented; reserved for a future stochastic
# variant). Uniform per-component quantisation in OKLab (the perceptual work
# space), the textbook dithering target.
#
# Uniform quantisation is adaptive: each OKLab comp (L, a, b) is reduced to
# `levels` steps over the image's own [min, max] range (mirrors Wu/octree
# adaptive binning — a narrow-gamut image uses the full level resolution).
# The output is a new `Image` in OKLab (workSpace = tagOklab); convert for
# display if needed (explicit, no magic).
#
# Layer: image (consumer of image/internal). Deterministic.
import std/math # `round`, `Inf`.
import std/tables # `Table` (registry).
import std/options # `Option`, `some`, `none`.
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/core/result
import UniColor/core/color_error
import UniColor/image/internal

type
  DitherOpts* = object
    ## Parameters for a dither run. `seed` is unused (deterministic algos —
    ## documented, reserved for a future stochastic variant). `strength`
    ## scales the Bayer ordered perturbation (default 1.0 = half a
    ## quantisation step, the textbook ordered-dither magnitude); error
    ## diffusion ignores it.
    seed*: int64
    strength*: float64

  DitherAlgo* = object
    ## Descriptor for a registered dithering algorithm (data-driven like the
    ## other registries). `compute` runs on an `Image` ALREADY in OKLab and
    ## returns a dithered `Image` in OKLab (uniform per-component quantisation
    ## to `levels` steps). `levels < 2` is rejected by `dither` before
    ## dispatch.
    name*: string
    compute*: proc(img: Image, levels: int, opts: DitherOpts): Result[Image,
        ColorError] {.raises: [].}

const
  DefaultDitherAlgo* = "floydSteinberg" ## Floyd-Steinberg (quality default).
  DefaultDitherStrength* = 1.0          ## Bayer perturbation = half a step (textbook
                                        ## ordered dither).

proc defaultDitherOpts*(): DitherOpts {.raises: [].} =
  ## Defaults: seed 0 (unused — deterministic), strength 1.0 (Bayer half-step).
  DitherOpts(seed: 0, strength: DefaultDitherStrength)

# Registry — module-level table, idempotent registration, optional seal
# (mirrors quantize.nim).
var
  ditherByName: Table[string, DitherAlgo]
  ditherSealed: bool

proc registerDitherAlgo*(a: DitherAlgo): bool {.raises: [].} =
  if ditherSealed or a.name.len == 0 or ditherByName.hasKey(a.name) or
      a.compute.isNil:
    return false
  ditherByName[a.name] = a
  true

proc lookupDitherAlgo*(name: string): Option[DitherAlgo] {.raises: [].} =
  if ditherByName.hasKey(name):
    some(ditherByName.getOrDefault(name))
  else:
    none(DitherAlgo)

proc ditherAlgoCount*(): int {.raises: [].} =
  ditherByName.len

proc ditherAlgoNames*(): seq[string] {.raises: [].} =
  result = @[]
  for k in keys(ditherByName):
    result.add(k)

proc sealDitherAlgos*() {.raises: [].} =
  ditherSealed = true

# ---------------------------------------------------------------------------
# Shared helpers.
# ---------------------------------------------------------------------------

# Adaptive per-component [min, max] of the image's OKLab comps.
proc compBounds(img: Image): array[3, tuple[mn, mx: float64]] {.raises: [].} =
  for k in 0 .. 2:
    result[k] = (Inf, -Inf)
  for c in img.pixels:
    for k in 0 .. 2:
      let v = c.comp(k).float64
      if v < result[k].mn:
        result[k].mn = v
      if v > result[k].mx:
        result[k].mx = v

# Uniform-quantise a value to one of `levels` steps over [vMin, vMax].
# `levels >= 2` is assumed (the entry proc rejects < 2). A degenerate range
# (vMin == vMax) maps everything to vMin.
proc quantizeLevel(v, vMin, vMax: float64, levels: int): float64 {.inline.} =
  if vMax <= vMin:
    return vMin
  let step = (vMax - vMin) / float64(levels - 1)
  var q = round((v - vMin) / step)
  if q < 0.0:
    q = 0.0
  elif q > float64(levels - 1):
    q = float64(levels - 1)
  vMin + q * step

# Build the output OKLab image from a working buffer of comps.
proc buildOut(img: Image, buf: seq[array[3, float64]]): Result[Image,
    ColorError] {.raises: [].} =
  var pxs = newSeq[Color](img.pixels.len)
  for i, c in buf:
    let r = color(tagOklab, c[0].float32, c[1].float32, c[2].float32)
    if r.isErr:
      return err[Image, ColorError](r.error)
    pxs[i] = r.get
  image(img.width, img.height, pxs, tagOklab, img.bitDepth, img.gamut)

# ---------------------------------------------------------------------------
# Error diffusion (Floyd-Steinberg, Atkinson, Jarvis-Judice-Ninke).
# ---------------------------------------------------------------------------

# Diffusion kernel: a list of (dx, dy, factor). Forward-only (dx/dy such that
# the neighbor comes later in the row-major raster) — the error is pushed
# ahead, never back.
type Tap = tuple[dx, dy: int, f: float64]

const
  FsKernel: array[4, Tap] = [(1, 0, 7.0 / 16.0), (-1, 1, 3.0 / 16.0),
      (0, 1, 5.0 / 16.0), (1, 1, 1.0 / 16.0)]
  AtkinsonKernel: array[6, Tap] = [(1, 0, 1.0 / 8.0), (2, 0, 1.0 / 8.0),
      (-1, 1, 1.0 / 8.0), (0, 1, 1.0 / 8.0), (1, 1, 1.0 / 8.0), (0, 2, 1.0 / 8.0)]
  JarvisKernel: array[12, Tap] = [(1, 0, 7.0 / 48.0), (2, 0, 5.0 / 48.0),
      (-2, 1, 3.0 / 48.0), (-1, 1, 5.0 / 48.0), (0, 1, 7.0 / 48.0),
      (1, 1, 5.0 / 48.0), (2, 1, 3.0 / 48.0), (-2, 2, 1.0 / 48.0),
      (-1, 2, 3.0 / 48.0), (0, 2, 5.0 / 48.0), (1, 2, 3.0 / 48.0),
      (2, 2, 1.0 / 48.0)]

proc diffuse(buf: var seq[array[3, float64]], w, h, x, y: int,
    kernel: openArray[Tap], eL, eA, eB: float64) {.inline.} =
  for tap in kernel:
    let nx = x + tap.dx
    let ny = y + tap.dy
    if nx < 0 or nx >= w or ny < 0 or ny >= h:
      continue
    let idx = ny * w + nx
    buf[idx][0] += eL * tap.f
    buf[idx][1] += eA * tap.f
    buf[idx][2] += eB * tap.f

proc diffuseDither(img: Image, levels: int, opts: DitherOpts,
    kernel: openArray[Tap]): Result[Image, ColorError] {.raises: [].} =
  let w = img.width
  let h = img.height
  let b = compBounds(img)
  var buf = newSeq[array[3, float64]](w * h)
  for i, c in img.pixels:
    buf[i] = [c.comp(0).float64, c.comp(1).float64, c.comp(2).float64]
  for y in 0 ..< h:
    for x in 0 ..< w:
      let idx = y * w + x
      let old = buf[idx]
      var new0: array[3, float64]
      for k in 0 .. 2:
        new0[k] = quantizeLevel(old[k], b[k].mn, b[k].mx, levels)
      buf[idx] = new0 # the output value (snap to the step).
      diffuse(buf, w, h, x, y, kernel, old[0] - new0[0], old[1] - new0[1],
          old[2] - new0[2])
  buildOut(img, buf)

proc floydSteinberg(img: Image, levels: int, opts: DitherOpts): Result[Image,
    ColorError] {.raises: [].} =
  diffuseDither(img, levels, opts, FsKernel)

proc atkinson(img: Image, levels: int, opts: DitherOpts): Result[Image,
    ColorError] {.raises: [].} =
  diffuseDither(img, levels, opts, AtkinsonKernel)

proc jarvis(img: Image, levels: int, opts: DitherOpts): Result[Image,
    ColorError] {.raises: [].} =
  diffuseDither(img, levels, opts, JarvisKernel)

# ---------------------------------------------------------------------------
# Bayer ordered dithering (4x4 threshold matrix).
# ---------------------------------------------------------------------------

# Classic 4x4 Bayer threshold matrix (values 0..15), divided by 16 -> [0,1).
const Bayer4: array[4, array[4, int]] = [
  [0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

proc bayer(img: Image, levels: int, opts: DitherOpts): Result[Image,
    ColorError] {.raises: [].} =
  let w = img.width
  let h = img.height
  let b = compBounds(img)
  # Per-channel quantisation step over the image's [min, max] — constant for
  # the whole image, so precompute once (0 for a degenerate range).
  var steps: array[3, float64]
  for k in 0 .. 2:
    steps[k] = if b[k].mx <= b[k].mn: 0.0
      else: (b[k].mx - b[k].mn) / float64(levels - 1)
  var buf = newSeq[array[3, float64]](w * h)
  for i, c in img.pixels:
    buf[i] = [c.comp(0).float64, c.comp(1).float64, c.comp(2).float64]
  for y in 0 ..< h:
    for x in 0 ..< w:
      let idx = y * w + x
      let t = float64(Bayer4[y mod 4][x mod 4]) / 16.0
      for k in 0 .. 2:
        # Centered ordered perturbation: add (t - 0.5) * step * strength, then snap.
        let perturbed = buf[idx][k] + (t - 0.5) * steps[k] * opts.strength
        buf[idx][k] = quantizeLevel(perturbed, b[k].mn, b[k].mx, levels)
  buildOut(img, buf)

# ---------------------------------------------------------------------------
# Entry seam — convert to OKLab once, dispatch to the registered algo.
# ---------------------------------------------------------------------------

proc dither*(img: Image, levels: int, algo = DefaultDitherAlgo,
    opts = defaultDitherOpts()): Result[Image, ColorError] {.raises: [].} =
  ## Dither `img` to `levels` uniform per-component OKLab steps via the
  ## registered `algo` (default Floyd-Steinberg). The image is converted to
  ## OKLab once (immutably), then handed to the algo. Returns a new `Image` in
  ## OKLab (workSpace = tagOklab) — convert for display if needed (explicit,
  ## no magic). `levels < 2` -> `err InvalidOp`; unknown algo -> `err
  ## UnknownAlgorithm`; empty image -> `err InvalidImage`; conversion error
  ## propagates. Deterministic: fixed raster (diffusion) or ordered matrix
  ## (Bayer), no RNG.
  if img.isEmpty():
    return err[Image, ColorError](colorError(InvalidImage,
        "dither: empty image", "dither"))
  if levels < 2:
    return err[Image, ColorError](colorError(InvalidOp,
        "dither: levels must be >= 2, got " & $levels, "dither"))
  let a = lookupDitherAlgo(algo)
  if a.isNone:
    return err[Image, ColorError](colorError(UnknownAlgorithm,
        "unknown dithering algorithm: " & algo, "dither"))
  if img.workSpace == tagOklab:
    return a.get.compute(img, levels, opts)
  let convR = img.toWorkSpace(tagOklab)
  if convR.isErr:
    return err[Image, ColorError](convR.error)
  a.get.compute(convR.get, levels, opts)

# Bootstrap — register the four dither algos (idempotent; re-registration
# returns false).
discard registerDitherAlgo(DitherAlgo(name: "floydSteinberg",
    compute: floydSteinberg))
discard registerDitherAlgo(DitherAlgo(name: "atkinson", compute: atkinson))
discard registerDitherAlgo(DitherAlgo(name: "jarvis", compute: jarvis))
discard registerDitherAlgo(DitherAlgo(name: "bayer", compute: bayer))
