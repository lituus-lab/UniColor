# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# test_image — image layer: Image value type, format-free loader registry,
# quantizer registry (Wu / k-means / k-means++ / WSM / medianCut / octree /
# NeuQuant), 3D OKLCH histogram + dominant colors, dithering (Floyd-
# Steinberg / Atkinson / Jarvis / Bayer), HDR (ICtCp work space), and the
# image-layer determinism properties. Consolidated from the palette test
# suite; imports adapted to the UniColor umbrella. The malebolgia
# parallel-only test files are NOT ported — parallel dispatch is a deferred
# contract surface (serial bit-exact path today; see `*MinParallelPixels`
# consts), so the parallel-vs-serial equivalence they asserted is trivially
# true and covered by the determinism suites here.
import std/algorithm
import std/math
import std/options
import std/tables
import std/unittest
import UniColor

proc srgb255(r, g, b: int): Color {.raises: [].} =
  color(tagSrgb, r.float32 / 255.0'f32, g.float32 / 255.0'f32,
      b.float32 / 255.0'f32).get

proc oklabImg(w, h: int): Image {.raises: [].} =
  # A 3x1 sRGB image of distinct primaries, converted to OKLab.
  let pxs = [srgb255(255, 0, 0), srgb255(0, 255, 0), srgb255(0, 0, 255)]
  image(w, h, pxs, tagSrgb).get.toWorkSpace(tagOklab).get

proc near(c1, c2: Color, tol: float64): bool {.raises: [].} =
  for k in 0 .. 2:
    if abs(c1.comp(k).float64 - c2.comp(k).float64) > tol:
      return false
  true

# ===========================================================================
# Image value type + format-free loader (internal + loader).
# ===========================================================================

# Build a "nimraw" frame: u32-LE W, u32-LE H, then w*h RGBA8 pixels filled
# with `fill`.
proc nimrawBytes(w, h: int, fill: Color): seq[byte] =
  let s = fill.to(tagSrgb).get
  let r = uint8(s.comp(0).float32 * 255.0'f32 + 0.5'f32)
  let g = uint8(s.comp(1).float32 * 255.0'f32 + 0.5'f32)
  let b = uint8(s.comp(2).float32 * 255.0'f32 + 0.5'f32)
  let a = uint8(s.alpha().float32 * 255.0'f32 + 0.5'f32)
  result = newSeq[byte](8 + w * h * 4)
  result[0] = byte(w and 0xff)
  result[1] = byte((w shr 8) and 0xff)
  result[2] = byte((w shr 16) and 0xff)
  result[3] = byte((w shr 24) and 0xff)
  result[4] = byte(h and 0xff)
  result[5] = byte((h shr 8) and 0xff)
  result[6] = byte((h shr 16) and 0xff)
  result[7] = byte((h shr 24) and 0xff)
  for i in 0 ..< w * h:
    let off = 8 + i * 4
    result[off] = r
    result[off + 1] = g
    result[off + 2] = b
    result[off + 3] = a

suite "Image value type — validated pixel buffer":
  test "builds a valid Image from a matching pixel buffer":
    let pxs = [srgb255(255, 0, 0), srgb255(0, 255, 0), srgb255(0, 0, 255),
        srgb255(255, 255, 255)]
    let r = image(2, 2, pxs, tagSrgb)
    check r.isOk
    let img = r.get
    check img.width == 2
    check img.height == 2
    check img.len() == 4
    check not img.isEmpty()
    check img.originSpace == tagSrgb
    check img.bitDepth == 8
    check img.gamut == gamutSdr

  test "0x0 dimensions -> err InvalidImage":
    let r = image(0, 0, [], tagSrgb)
    check r.isErr
    check r.error.kind == InvalidImage
    let r2 = image(0, 3, [], tagSrgb)
    check r2.isErr
    check r2.error.kind == InvalidImage

  test "pixel count mismatch -> err InvalidImage":
    let pxs = [srgb255(1, 1, 1), srgb255(2, 2, 2)] # 2 pixels for a 2x2 claim
    let r = image(2, 2, pxs, tagSrgb)
    check r.isErr
    check r.error.kind == InvalidImage

  test "unknown origin space -> err UnknownSpace":
    let pxs = [srgb255(0, 0, 0)]
    let r = image(1, 1, pxs, tagUnknown)
    check r.isErr
    check r.error.kind == UnknownSpace

  test "pixelAt reads back the stored Color (AoS interface)":
    let pxs = [srgb255(10, 20, 30), srgb255(40, 50, 60)]
    let img = image(2, 1, pxs, tagSrgb).get
    let p0 = img.pixelAt(0, 0).get
    let p1 = img.pixelAt(1, 0).get
    check abs(p0.comp(0).float64 - 10.0 / 255.0) < 1.0e-3
    check abs(p1.comp(2).float64 - 60.0 / 255.0) < 1.0e-3

  test "pixelAt out of bounds -> err InvalidImage":
    let img = image(1, 1, [srgb255(0, 0, 0)], tagSrgb).get
    check img.pixelAt(1, 0).isErr
    check img.pixelAt(0, 1).isErr

suite "ImageLoader registry — injected decoding, narrow pipeline":
  test "the default 'nimraw' loader is registered":
    check imageLoaderCount() >= 1
    let names = imageLoaderNames()
    check "nimraw" in names

  test "decode a 2x2 nimraw frame into an Image":
    let bytes = nimrawBytes(2, 2, srgb255(255, 128, 0))
    let r = decode("nimraw", bytes)
    check r.isOk
    let img = r.get
    check img.width == 2
    check img.height == 2
    check img.len() == 4
    check img.originSpace == tagSrgb

  test "decode preserves the pixel color within 8-bit rounding":
    let bytes = nimrawBytes(1, 1, srgb255(200, 100, 50))
    let img = decode("nimraw", bytes).get
    let p = img.pixelAt(0, 0).get.to(tagSrgb).get
    check abs(p.comp(0).float64 - 200.0 / 255.0) < 2.0e-2
    check abs(p.comp(1).float64 - 100.0 / 255.0) < 2.0e-2
    check abs(p.comp(2).float64 - 50.0 / 255.0) < 2.0e-2

  test "unknown loader name -> err (not InvalidImage)":
    let r = decode("definitelyNotAFormat", [byte 0])
    check r.isErr
    check r.error.kind == UnknownAlgorithm

  test "fuzz: empty bytes -> err InvalidImage":
    let r = decode("nimraw", [])
    check r.isErr
    check r.error.kind == InvalidImage

  test "fuzz: truncated header -> err InvalidImage":
    let r = decode("nimraw", [byte 1, 2, 3])         # < 8-byte header.
    check r.isErr
    check r.error.kind == InvalidImage

  test "fuzz: 0x0 dims in header -> err InvalidImage":
    let r = decode("nimraw", [byte 0, 0, 0, 0, 0, 0, 0, 0])
    check r.isErr
    check r.error.kind == InvalidImage

  test "fuzz: payload size mismatch -> err InvalidImage":
    let r = decode("nimraw", [byte 2, 0, 0, 0, 2, 0, 0, 0, byte 0]) # 2x2, 1 byte.
    check r.isErr
    check r.error.kind == InvalidImage

  test "registry: idempotent registration rejects duplicates":
    let before = imageLoaderCount()
    discard registerImageLoader(ImageLoader(name: "nimraw",
        decode: decodeNimraw))
    check imageLoaderCount() == before # no duplicate.

  test "deterministic: same bytes decode to the same Image":
    let bytes = nimrawBytes(2, 2, srgb255(64, 128, 192))
    let a = decode("nimraw", bytes).get
    let b = decode("nimraw", bytes).get
    check a.width == b.width
    check a.height == b.height
    check a.pixels.len == b.pixels.len
    check a.pixels == b.pixels

suite "toWorkSpace — OKLab work space conversion":
  test "converts an sRGB image to OKLab and sets workSpace":
    let img = oklabImg(3, 1)
    check img.workSpace == tagOklab
    check img.originSpace == tagSrgb # origin preserved.
    check img.width == 3
    check img.height == 1
    check img.len() == 3

  test "does not mutate the input image (immutable)":
    let src = image(2, 1, [srgb255(10, 20, 30), srgb255(40, 50, 60)], tagSrgb).get
    let before = src.workSpace
    discard src.toWorkSpace(tagOklab)
    check src.workSpace == before # untouched.
    check src.pixels[0].spaceTag() == tagSrgb # pixels unchanged.

  test "same-space target is a copy (no conversion)":
    let src = image(1, 1, [srgb255(100, 100, 100)], tagSrgb).get
    let outImg = src.toWorkSpace(tagSrgb).get
    check outImg.workSpace == tagSrgb
    check outImg.pixels[0] == src.pixels[0] # bit-identical copy.

  test "unknown target space -> err UnknownSpace":
    let src = image(1, 1, [srgb255(0, 0, 0)], tagSrgb).get
    let r = src.toWorkSpace(tagUnknown)
    check r.isErr
    check r.error.kind == UnknownSpace

  test "OKLab pixels are in the OKLab space after conversion":
    let img = oklabImg(3, 1)
    check img.pixels[0].spaceTag() == tagOklab

suite "oklabPlanes — SoA<->AoS zero-cost bridge":
  test "requires workSpace == oklab (else InvalidOp)":
    let src = image(1, 1, [srgb255(0, 0, 0)], tagSrgb).get # workSpace == sRGB.
    let r = src.oklabPlanes()
    check r.isErr
    check r.error.kind == InvalidOp

  test "planes length equals width*height":
    let img = oklabImg(3, 1)
    let p = img.oklabPlanes().get
    check p.l.len == 3
    check p.a.len == 3
    check p.b.len == 3
    check p.alpha.len == 3

  test "SoA planes == AoS pixelAt comps (zero-cost bridge, bit-identical)":
    # The planes are read directly from the OKLab Color comps, so they match
    # `pixelAt` exactly (no round-trip — same float32 values).
    let img = oklabImg(3, 1)
    let p = img.oklabPlanes().get
    for i in 0 ..< img.len():
      let x = i mod img.width
      let y = i div img.width
      let c = img.pixelAt(x, y).get
      check p.l[i] == c.comp(0)
      check p.a[i] == c.comp(1)
      check p.b[i] == c.comp(2)
      check p.alpha[i] == c.alpha()

  test "distinct primaries produce distinct OKLab L values":
    let img = oklabImg(3, 1)
    let p = img.oklabPlanes().get
    check p.l[0] != p.l[1] # red vs green have different OKLab L.
    check p.l[1] != p.l[2] # green vs blue.
    check p.l[0] != p.l[2]

  test "deterministic: same image converted twice gives the same planes":
    let src = image(2, 1, [srgb255(123, 200, 45), srgb255(9, 9, 9)],
        tagSrgb).get
    let a = src.toWorkSpace(tagOklab).get.oklabPlanes().get
    let b = src.toWorkSpace(tagOklab).get.oklabPlanes().get
    check a.l == b.l
    check a.a == b.a
    check a.b == b.b

  test "alpha plane is 1.0 for opaque pixels":
    let img = image(2, 1, [srgb255(255, 0, 0), srgb255(0, 255, 0)],
        tagSrgb).get.toWorkSpace(tagOklab).get
    let p = img.oklabPlanes().get
    for i in 0 ..< p.alpha.len:
      check abs(p.alpha[i].float64 - 1.0) < 1.0e-6

# ===========================================================================
# Quantize (registry + Wu + k-means + WSM + misc).
# ===========================================================================

suite "extractPalette — error contracts + dispatch":
  test "n < 1 -> err InvalidOp":
    let img = oklabImg(3, 1)
    let r = img.extractPalette(0)
    check r.isErr
    check r.error.kind == InvalidOp

  test "unknown algorithm -> err UnknownAlgorithm":
    let img = oklabImg(3, 1)
    let r = img.extractPalette(3, algo = "nope")
    check r.isErr
    check r.error.kind == UnknownAlgorithm

  test "unregistered algos -> UnknownAlgorithm (any unknown name)":
    let img = oklabImg(3, 1)
    let r = img.extractPalette(3, algo = "definitelyNotAnAlgo")
    check r.isErr
    check r.error.kind == UnknownAlgorithm

  test "all six registered algos dispatch and succeed":
    let img = oklabImg(3, 1)
    for name in ["wu", "kmeans", "kmeansPP", "medianCut", "octree", "neuquant"]:
      let r = img.extractPalette(3, algo = name)
      check r.isOk
      if r.isOk:
        check r.get.len() <= 3
        check r.get.len() >= 1

suite "Wu — deterministic moment-based quantization":
  test "returns a palette of <= n colors in the work space":
    let img = oklabImg(3, 1)
    let r = img.extractPalette(3)
    check r.isOk
    let p = r.get
    check p.len() <= 3
    check p.len() >= 1
    check p.tag() == palUnordered
    check p.intent() == intentQualitative
    for c in p.colors():
      check c.spaceTag() == tagOklab # centroids in the work space.

  test "3 primaries with n=3 -> centroids match the input OKLab pixels":
    # One pixel per box: the centroid = the pixel exactly (mr/wt with wt=1).
    let img = oklabImg(3, 1)
    let primaries = img.pixels
    let p = img.extractPalette(3).get
    check p.len() == 3
    for c in p.colors():
      var matched = false
      for q in primaries:
        if near(c, q, 1.0e-5):
          matched = true
          break
      check matched

  test "n=2 on 3 primaries -> 2 centroids (fewer boxes than pixels)":
    let img = oklabImg(3, 1)
    let p = img.extractPalette(2).get
    check p.len() == 2

  test "single-color image -> 1 centroid":
    let pxs = [srgb255(123, 45, 67)]
    let img = image(1, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get
    let p = img.extractPalette(1).get
    check p.len() == 1
    check near(p.colors()[0], img.pixels[0], 1.0e-5)

  test "deterministic: same image twice -> same palette":
    let img = oklabImg(3, 1)
    let a = img.extractPalette(3).get
    let b = img.extractPalette(3).get
    check a.len() == b.len()
    for i in 0 ..< a.len():
      check near(a.colors()[i], b.colors()[i], 1.0e-7)

  test "n larger than distinct colors -> still <= n (no padding)":
    let img = oklabImg(3, 1) # only 3 distinct colors.
    let p = img.extractPalette(8).get
    check p.len() <= 8
    check p.len() >= 1

  test "converts an sRGB image to OKLab once when workSpace is sRGB":
    let img = image(3, 1, [srgb255(255, 0, 0), srgb255(0, 255, 0),
        srgb255(0, 0, 255)], tagSrgb).get
    check img.workSpace == tagSrgb # as loaded.
    let p = img.extractPalette(3, space = tagOklab).get
    for c in p.colors():
      check c.spaceTag() == tagOklab

  test "honors a custom seed in the returned palette metadata":
    let img = oklabImg(3, 1)
    let opts = QuantizeOpts(seed: 42, maxIter: 5, weighting: false)
    let p = img.extractPalette(3, opts = opts).get
    check p.seed() == 42

suite "k-means / k-means++ — perceptual clustering reusing palette/kmeans":
  test "kmeans and kmeansPP return <= n OKLab centroids":
    let img = oklabImg(3, 1)
    for name in ["kmeans", "kmeansPP"]:
      let p = img.extractPalette(3, algo = name).get
      check p.len() <= 3
      check p.len() >= 1
      check p.tag() == palUnordered
      check p.intent() == intentQualitative
      for c in p.colors():
        check c.spaceTag() == tagOklab

  test "kmeansPP on 3 primaries n=3 -> centroids match the input OKLab pixels":
    # k-means++ spreads the init (D2-proportional), so with k=3 on 3 distinct
    # points each point is its own cluster -> centroid = the point. Random
    # init ("kmeans") can duplicate centroids (empty cluster keeps its init
    # value), so it is NOT asserted to match.
    let img = oklabImg(3, 1)
    let primaries = img.pixels
    let p = img.extractPalette(3, algo = "kmeansPP").get
    check p.len() == 3
    for c in p.colors():
      var matched = false
      for q in primaries:
        if near(c, q, 1.0e-4): # k-means convergence tolerance 1e-4.
          matched = true
          break
      check matched

  test "kmeans (random init) on 3 primaries n=3 -> valid <= n palette":
    let img = oklabImg(3, 1)
    let p = img.extractPalette(3, algo = "kmeans").get
    check p.len() <= 3
    check p.len() >= 1
    for c in p.colors():
      check c.spaceTag() == tagOklab

  test "n=2 on 3 primaries -> 2 centroids":
    let img = oklabImg(3, 1)
    for name in ["kmeans", "kmeansPP"]:
      let p = img.extractPalette(2, algo = name).get
      check p.len() == 2

  test "deterministic: same image + same seed -> same palette":
    let img = oklabImg(3, 1)
    for name in ["kmeans", "kmeansPP"]:
      let opts = QuantizeOpts(seed: 7, maxIter: 50, weighting: false)
      let a = img.extractPalette(3, algo = name, opts = opts).get
      let b = img.extractPalette(3, algo = name, opts = opts).get
      check a.len() == b.len()
      for i in 0 ..< a.len():
        check near(a.colors()[i], b.colors()[i], 1.0e-6)

  test "different seeds can produce different clusterings":
    # k-means init is seeded; on more points than clusters, distinct seeds
    # usually diverge. We only require both runs are valid <= n palettes (we
    # do NOT assert they differ, since k-means can converge to the same
    # partition regardless of init for well-separated data).
    let pxs = [srgb255(255, 0, 0), srgb255(0, 255, 0), srgb255(0, 0, 255),
        srgb255(255, 255, 0), srgb255(255, 0, 255), srgb255(0, 255, 255)]
    let img = image(6, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get
    let o1 = QuantizeOpts(seed: 1, maxIter: 50, weighting: false)
    let o2 = QuantizeOpts(seed: 999, maxIter: 50, weighting: false)
    let p1 = img.extractPalette(3, algo = "kmeansPP", opts = o1).get
    let p2 = img.extractPalette(3, algo = "kmeansPP", opts = o2).get
    check p1.len() <= 3
    check p2.len() <= 3

  test "n > pixel count -> err InvalidOp":
    let img = oklabImg(3, 1) # 3 pixels.
    let r = img.extractPalette(5, algo = "kmeansPP")
    check r.isErr
    check r.error.kind == InvalidOp

  test "non-OKLab work space (sRGB) with kmeans -> err InvalidOp":
    let img = image(3, 1, [srgb255(255, 0, 0), srgb255(0, 255, 0),
        srgb255(0, 0, 255)], tagSrgb).get
    check img.workSpace == tagSrgb
    # extractPalette(space=srgb) hands an sRGB image to kmeans, which
    # requires OKLab — honest InvalidOp, no silent cross-space clustering.
    let r = img.extractPalette(3, algo = "kmeansPP", space = tagSrgb)
    check r.isErr
    check r.error.kind == InvalidOp

suite "WSM — weighted-significance k-means (opts.weighting)":
  test "weighting=true produces a valid <= n OKLab palette":
    let img = oklabImg(3, 1)
    let opts = QuantizeOpts(seed: 0, maxIter: 50, weighting: true)
    let p = img.extractPalette(3, algo = "kmeansPP", opts = opts).get
    check p.len() <= 3
    for c in p.colors():
      check c.spaceTag() == tagOklab

  test "WSM kmeansPP on 3 primaries n=3 -> centroids match the pixels":
    # k-means++ spreads; with k=points each point is its own cluster
    # regardless of weighting.
    let img = oklabImg(3, 1)
    let primaries = img.pixels
    let opts = QuantizeOpts(seed: 0, maxIter: 50, weighting: true)
    let p = img.extractPalette(3, algo = "kmeansPP", opts = opts).get
    check p.len() == 3
    for c in p.colors():
      var matched = false
      for q in primaries:
        if near(c, q, 1.0e-4):
          matched = true
          break
      check matched

  test "WSM deterministic: same image + same seed -> same palette":
    let img = oklabImg(3, 1)
    let opts = QuantizeOpts(seed: 3, maxIter: 50, weighting: true)
    let a = img.extractPalette(3, algo = "kmeansPP", opts = opts).get
    let b = img.extractPalette(3, algo = "kmeansPP", opts = opts).get
    check a.len() == b.len()
    for i in 0 ..< a.len():
      check near(a.colors()[i], b.colors()[i], 1.0e-6)

suite "medianCut / octree / neuquant — misc quantizers":
  test "all three return <= n OKLab centroids with the right tag/intent":
    let img = oklabImg(3, 1)
    for name in ["medianCut", "octree", "neuquant"]:
      let p = img.extractPalette(3, algo = name).get
      check p.len() <= 3
      check p.len() >= 1
      check p.tag() == palUnordered
      check p.intent() == intentQualitative
      for c in p.colors():
        check c.spaceTag() == tagOklab

  test "medianCut on 3 primaries n=3 -> 3 centroids matching the pixels":
    # 3 distinct points: median cut splits at the median each time, isolating
    # each pixel into its own box -> centroid = the pixel.
    let img = oklabImg(3, 1)
    let primaries = img.pixels
    let p = img.extractPalette(3, algo = "medianCut").get
    check p.len() == 3
    for c in p.colors():
      var matched = false
      for q in primaries:
        if near(c, q, 1.0e-5):
          matched = true
          break
      check matched

  test "medianCut n=2 -> 2 centroids":
    let img = oklabImg(3, 1)
    let p = img.extractPalette(2, algo = "medianCut").get
    check p.len() == 2

  test "octree reduces to <= n leaves (single-color image -> 1 leaf)":
    let pxs = [srgb255(123, 45, 67)]
    let img = image(1, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get
    let p = img.extractPalette(1, algo = "octree").get
    check p.len() == 1
    check near(p.colors()[0], img.pixels[0], 1.0e-5)

  test "octree on 3 primaries n=3 -> centroids match the pixels":
    let img = oklabImg(3, 1)
    let primaries = img.pixels
    let p = img.extractPalette(3, algo = "octree").get
    check p.len() <= 3
    # 3 distinct colors -> 3 octree leaves (no reduction needed).
    check p.len() == 3
    for c in p.colors():
      var matched = false
      for q in primaries:
        if near(c, q, 1.0e-4):
          matched = true
          break
      check matched

  test "neuquant returns exactly n neurons (the SOM has n units)":
    let img = oklabImg(3, 1)
    let p = img.extractPalette(3, algo = "neuquant").get
    check p.len() == 3

  test "neuquant deterministic: same image + same seed -> same palette":
    let img = oklabImg(3, 1)
    let opts = QuantizeOpts(seed: 11, maxIter: 10, weighting: false)
    let a = img.extractPalette(3, algo = "neuquant", opts = opts).get
    let b = img.extractPalette(3, algo = "neuquant", opts = opts).get
    check a.len() == b.len()
    for i in 0 ..< a.len():
      check near(a.colors()[i], b.colors()[i], 1.0e-7)

  test "medianCut/octree/neuquant reject n > pixel count -> InvalidOp":
    let img = oklabImg(3, 1) # 3 pixels.
    for name in ["medianCut", "octree", "neuquant"]:
      let r = img.extractPalette(5, algo = name)
      check r.isErr
      check r.error.kind == InvalidOp

  test "determinism across all misc algos: same image + seed -> same palette":
    # A larger image (6 primaries) so the algos do real work.
    let pxs = [srgb255(255, 0, 0), srgb255(0, 255, 0), srgb255(0, 0, 255),
        srgb255(255, 255, 0), srgb255(255, 0, 255), srgb255(0, 255, 255)]
    let img = image(6, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get
    let opts = QuantizeOpts(seed: 0, maxIter: 20, weighting: false)
    for name in ["medianCut", "octree", "neuquant"]:
      let a = img.extractPalette(4, algo = name, opts = opts).get
      let b = img.extractPalette(4, algo = name, opts = opts).get
      check a.len() == b.len()
      for i in 0 ..< a.len():
        check near(a.colors()[i], b.colors()[i], 1.0e-6)

# ===========================================================================
# Histogram + dominant colors.
# ===========================================================================

# A 10x1 sRGB image: 9 reds + 1 blue, converted to OKLab.
proc majorityImage(): Image {.raises: [].} =
  var pxs: seq[Color] = @[]
  for i in 0 ..< 9:
    pxs.add(srgb255(255, 0, 0))
  pxs.add(srgb255(0, 0, 255))
  image(10, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get

proc nearDE(c1, c2: Color, tol: float64): bool {.raises: [].} =
  deltaE_ok(c1, c2) < tol

suite "dominantColors — error contracts":
  test "n < 1 -> err InvalidOp":
    let img = majorityImage()
    let r = img.dominantColors(0)
    check r.isErr
    check r.error.kind == InvalidOp

  test "bin counts < 1 -> err InvalidOp":
    let img = majorityImage()
    let opts = DominantOpts(binL: 0, binC: 16, binH: 24)
    let r = img.dominantColors(3, opts)
    check r.isErr
    check r.error.kind == InvalidOp

suite "dominantColors — weighted modes (golden: majority first)":
  test "90/10 image -> red dominant first (majority by pixel count)":
    # With 9 reds + 1 blue, the heaviest bin is red. The top dominant must
    # match the red OKLab pixel, not the blue.
    let img = majorityImage()
    let doms = img.dominantColors(2).get
    check doms.len == 2
    let red = img.pixels[0] # red (the majority).
    check nearDE(doms[0], red, 0.05)

  test "returns <= n colors in OKLab (the histogram space)":
    let img = majorityImage()
    let doms = img.dominantColors(5).get
    check doms.len <= 5
    check doms.len >= 1
    for c in doms:
      check c.spaceTag() == tagOklab

  test "n larger than distinct bins -> still <= n (no padding)":
    let img = majorityImage()
    let doms = img.dominantColors(50).get
    check doms.len <= 50
    check doms.len >= 1

  test "single-color image -> 1 dominant matching the pixel":
    let pxs = [srgb255(123, 45, 67)]
    let img = image(1, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get
    let doms = img.dominantColors(3).get
    check doms.len == 1
    check nearDE(doms[0], img.pixels[0], 0.02)

suite "dominantColors — determinism + order-stable":
  test "deterministic: same image twice -> same dominant colors (same order)":
    let img = majorityImage()
    let a = img.dominantColors(3).get
    let b = img.dominantColors(3).get
    check a.len == b.len
    for i in 0 ..< a.len:
      check a[i] == b[i] # bit-identical (no RNG, fixed bins).

  test "order-stable: equal-weight bins sorted by bin key":
    # 3 primaries, each appearing once -> 3 equal-weight bins. The order is
    # deterministic (bin key ascending: l, then c, then h).
    let pxs = [srgb255(255, 0, 0), srgb255(0, 255, 0), srgb255(0, 0, 255)]
    let img = image(3, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get
    let a = img.dominantColors(3).get
    let b = img.dominantColors(3).get
    check a.len == b.len
    for i in 0 ..< a.len:
      check a[i] == b[i]

  test "order-stable: heavier bin always precedes lighter one":
    # 4 blues + 1 red: blue bin (weight 4) must be first, red (weight 1)
    # second — the weight sort dominates, not pixel order.
    var pxs: seq[Color] = @[]
    for i in 0 ..< 4:
      pxs.add(srgb255(0, 0, 255)) # blue majority.
    pxs.add(srgb255(255, 0, 0)) # red minority.
    let img = image(5, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get
    let doms = img.dominantColors(2).get
    check doms.len == 2
    let blue = img.pixels[0] # blue (majority).
    check nearDE(doms[0], blue, 0.05)

suite "dominantColors — filtering + merging":
  test "minArea filters out small bins":
    # 9 reds + 1 blue: minArea=2 drops the blue bin (weight 1) -> only red.
    let img = majorityImage()
    let opts = DominantOpts(binL: 16, binC: 16, binH: 24, minArea: 2.0,
        minDeltaE: 0.0, weighting: false)
    let doms = img.dominantColors(5, opts).get
    check doms.len == 1 # only the red bin survives.
    let red = img.pixels[0]
    check nearDE(doms[0], red, 0.05)

  test "minDeltaE_OK merges close dominant colors":
    # Two near-identical reds (1-step apart in sRGB) land in (likely) different
    # bins but are very close in OKLab. With minDeltaE large enough, they
    # merge into one dominant.
    var pxs: seq[Color] = @[]
    for i in 0 ..< 5:
      pxs.add(srgb255(255, 0, 0))
    for i in 0 ..< 5:
      pxs.add(srgb255(254, 0, 0)) # ~indistinguishable from red.
    pxs.add(srgb255(0, 0, 255)) # a clearly different blue.
    let img = image(11, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get
    var oNo = defaultDominantOpts()
    oNo.minArea = 1.0
    oNo.minDeltaE = 0.0
    let noMerge = img.dominantColors(5, oNo).get
    var oM = defaultDominantOpts()
    oM.minArea = 1.0
    oM.minDeltaE = 1.0
    let merged = img.dominantColors(5, oM).get
    check merged.len <= noMerge.len
    check merged.len <= 2

  test "minDeltaE=0 (default) never merges (each bin distinct)":
    let img = majorityImage()
    let doms = img.dominantColors(5).get
    check doms.len >= 1
    for i in 0 ..< doms.len:
      for j in i + 1 ..< doms.len:
        check deltaE_ok(doms[i], doms[j]) > 1.0e-3

suite "dominantColors — WSM weighting":
  test "WSM (weighting=true) returns valid <= n OKLab dominant colors":
    let img = majorityImage()
    let opts = DominantOpts(binL: 16, binC: 16, binH: 24, minArea: 1.0,
        minDeltaE: 0.0, weighting: true)
    let doms = img.dominantColors(3, opts).get
    check doms.len <= 3
    for c in doms:
      check c.spaceTag() == tagOklab

  test "WSM deterministic: same image twice -> same dominant colors":
    let img = majorityImage()
    let opts = DominantOpts(binL: 16, binC: 16, binH: 24, minArea: 1.0,
        minDeltaE: 0.0, weighting: true)
    let a = img.dominantColors(3, opts).get
    let b = img.dominantColors(3, opts).get
    check a.len == b.len
    for i in 0 ..< a.len:
      check a[i] == b[i]

suite "buildHistogram — reuse seam":
  test "buildHistogram returns a non-empty sparse histogram":
    let img = majorityImage()
    let h = img.buildHistogram(defaultDominantOpts()).get
    check h.bins.len >= 1
    check h.binL == 16
    check h.binC == 16
    check h.binH == 24

  test "buildHistogram accumulates pixel counts per bin (9 reds + 1 blue)":
    let img = majorityImage()
    let h = img.buildHistogram(defaultDominantOpts()).get
    var total = 0
    for k, acc in h.bins.pairs:
      total += acc.count
    check total == 10

# ===========================================================================
# Dither.
# ===========================================================================

# A 16x1 sRGB gradient black->red, converted to OKLab.
proc gradientImage(): Image {.raises: [].} =
  var pxs: seq[Color] = @[]
  for i in 0 ..< 16:
    let v = (i * 17)
    pxs.add(srgb255(v, 0, 0))
  image(16, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get

# A 4x4 constant image at a single OKLab color (an exact step for levels=4).
proc constImage(): Image {.raises: [].} =
  var pxs: seq[Color] = @[]
  for i in 0 ..< 16:
    pxs.add(srgb255(0, 0, 0)) # black -> OKLab L=0, an exact step for any levels.
  image(4, 4, pxs, tagSrgb).get.toWorkSpace(tagOklab).get

# Is `v` exactly one of the `levels` quantisation steps over [vMin, vMax]?
proc isStep(v, vMin, vMax: float64, levels: int, tol: float64): bool {.
    raises: [].} =
  if vMax <= vMin:
    return abs(v - vMin) < tol
  let step = (vMax - vMin) / float64(levels - 1)
  for k in 0 ..< levels:
    if abs(v - (vMin + float64(k) * step)) < tol:
      return true
  false

suite "dither — error contracts":
  test "levels < 2 -> err InvalidOp":
    let img = gradientImage()
    let r = img.dither(1)
    check r.isErr
    check r.error.kind == InvalidOp

  test "unknown algorithm -> err UnknownAlgorithm":
    let img = gradientImage()
    let r = img.dither(4, algo = "nope")
    check r.isErr
    check r.error.kind == UnknownAlgorithm

suite "dither — output at quantisation steps (golden: stair-step)":
  test "floydSteinberg: every output comp is one of the levels steps":
    let img = gradientImage()
    var mn = [Inf, Inf, Inf]
    var mx = [-Inf, -Inf, -Inf]
    for c in img.pixels:
      for k in 0 .. 2:
        let v = c.comp(k).float64
        mn[k] = min(mn[k], v)
        mx[k] = max(mx[k], v)
    let outImg = img.dither(4).get
    for c in outImg.pixels:
      for k in 0 .. 2:
        check isStep(c.comp(k).float64, mn[k], mx[k], 4, 1.0e-4)

  test "all four algos dispatch and return an OKLab image of the same dims":
    let img = gradientImage()
    for name in ["floydSteinberg", "atkinson", "jarvis", "bayer"]:
      let outImg = img.dither(4, algo = name).get
      check outImg.width == img.width
      check outImg.height == img.height
      check outImg.workSpace == tagOklab
      for c in outImg.pixels:
        check c.spaceTag() == tagOklab

  test "output has <= levels distinct L values (uniform quantisation)":
    let img = gradientImage()
    let outImg = img.dither(4, algo = "floydSteinberg").get
    var seen: seq[float64] = @[]
    for c in outImg.pixels:
      let v = c.comp(0).float64
      var found = false
      for s in seen:
        if abs(s - v) < 1.0e-4:
          found = true
          break
      if not found:
        seen.add(v)
    check seen.len <= 4

suite "dither — determinism (property)":
  test "floydSteinberg deterministic: same image twice -> bit-identical":
    let img = gradientImage()
    let a = img.dither(4).get
    let b = img.dither(4).get
    check a.pixels.len == b.pixels.len
    for i in 0 ..< a.pixels.len:
      check a.pixels[i] == b.pixels[i]

  test "all algos deterministic: same image twice -> bit-identical":
    let img = gradientImage()
    for name in ["floydSteinberg", "atkinson", "jarvis", "bayer"]:
      let a = img.dither(4, algo = name).get
      let b = img.dither(4, algo = name).get
      check a.pixels.len == b.pixels.len
      for i in 0 ..< a.pixels.len:
        check a.pixels[i] == b.pixels[i]

  test "bayer is ordered: a flat constant image at an exact step stays":
    # Black (OKLab L=0) is an exact step (the minimum) for any levels ->
    # Bayer's centered perturbation keeps it at the step.
    let img = constImage()
    let outImg = img.dither(4, algo = "bayer").get
    for c in outImg.pixels:
      check abs(c.comp(0).float64) < 1.0e-5
      check abs(c.comp(1).float64) < 1.0e-5
      check abs(c.comp(2).float64) < 1.0e-5

  test "error diffusion leaves a constant-at-step image unchanged":
    let img = constImage()
    for name in ["floydSteinberg", "atkinson", "jarvis"]:
      let outImg = img.dither(4, algo = name).get
      for c in outImg.pixels:
        check abs(c.comp(0).float64) < 1.0e-5
        check abs(c.comp(1).float64) < 1.0e-5
        check abs(c.comp(2).float64) < 1.0e-5

suite "dither — registry":
  test "four dither algos registered (floydSteinberg/atkinson/jarvis/bayer)":
    check ditherAlgoCount() >= 4
    let names = ditherAlgoNames()
    for n in ["floydSteinberg", "atkinson", "jarvis", "bayer"]:
      check n in names

  test "default algo is floydSteinberg":
    let img = gradientImage()
    let byDefault = img.dither(4).get
    let byName = img.dither(4, algo = "floydSteinberg").get
    check byDefault.pixels.len == byName.pixels.len
    for i in 0 ..< byDefault.pixels.len:
      check byDefault.pixels[i] == byName.pixels[i]

# ===========================================================================
# HDR (ICtCp work space).
# ===========================================================================

# Build a Color in a linear space with HDR comps (>1.0 preserved out-of-gamut).
proc linHdr(r, g, b: float32): Color {.raises: [].} =
  color(tagSrgbLin, r, g, b).get

proc nearT(a, b: float64, tol: float64): bool {.raises: [].} =
  abs(a - b) < tol

suite "hdrImage — HDR construction validation":
  test "bitDepth <= 8 -> err InvalidOp":
    let pxs = [linHdr(1.0'f32, 0.0'f32, 0.0'f32)]
    let r = hdrImage(1, 1, pxs, tagSrgbLin, bitDepth = 8, gamut = gamutPq)
    check r.isErr
    check r.error.kind == InvalidOp

  test "gamutSdr -> err InvalidOp":
    let pxs = [linHdr(1.0'f32, 0.0'f32, 0.0'f32)]
    let r = hdrImage(1, 1, pxs, tagSrgbLin, bitDepth = 10, gamut = gamutSdr)
    check r.isErr
    check r.error.kind == InvalidOp

  test "valid HDR image (bitDepth=10, gamutPq) builds with HDR markers":
    let pxs = [linHdr(1.5'f32, 0.0'f32, 0.0'f32)] # HDR red, comp > 1.
    let r = hdrImage(1, 1, pxs, tagSrgbLin, bitDepth = 10, gamut = gamutPq)
    check r.isOk
    let img = r.get
    check img.bitDepth == 10
    check img.gamut == gamutPq
    check img.isHdr()
    # HDR comp > 1 preserved (no blanket clamp).
    check img.pixels[0].comp(0).float64 > 1.0

  test "bitDepth=16 gamutHdr builds (the other HDR marker combo)":
    let pxs = [linHdr(2.0'f32, 2.0'f32, 2.0'f32)]
    let img = hdrImage(1, 1, pxs, tagSrgbLin, bitDepth = 16,
        gamut = gamutHdr).get
    check img.isHdr()

  test "hdrImage propagates image() dimension validation (0x0 -> InvalidImage)":
    let r = hdrImage(0, 0, @[], tagSrgbLin, bitDepth = 10, gamut = gamutPq)
    check r.isErr
    check r.error.kind == InvalidImage

suite "isHdr — HDR predicate":
  test "SDR image (8-bit, gamutSdr) -> not HDR":
    let pxs = [color(tagSrgb, 1.0'f32, 0.0'f32, 0.0'f32).get]
    let img = image(1, 1, pxs, tagSrgb).get
    check not img.isHdr()

  test "PQ image -> HDR":
    let pxs = [linHdr(1.0'f32, 0.0'f32, 0.0'f32)]
    let img = hdrImage(1, 1, pxs, tagSrgbLin, bitDepth = 10,
        gamut = gamutPq).get
    check img.isHdr()

  test "10-bit HDR-gamut image -> HDR (both markers present)":
    let pxs = [linHdr(1.0'f32, 0.0'f32, 0.0'f32)]
    let img = hdrImage(1, 1, pxs, tagSrgbLin, bitDepth = 12,
        gamut = gamutHdr).get
    check img.isHdr()

  test "high-bit-depth SDR gamut -> NOT HDR (both markers required)":
    # A 16-bit sRGB image is high-bit-depth SDR, not HDR: isHdr requires the
    # PQ/HLG gamut AND bitDepth > 8 (the invariant hdrImage enforces).
    let pxs = [color(tagSrgb, 1.0'f32, 0.0'f32, 0.0'f32).get]
    let img = image(1, 1, pxs, tagSrgb, bitDepth = 16, gamut = gamutSdr).get
    check not img.isHdr()

suite "toIctcpWorkSpace — HDR perceptual work space":
  test "converts an HDR image to ICtCp":
    let pxs = [linHdr(1.5'f32, 0.2'f32, 0.1'f32)]
    let img = hdrImage(1, 1, pxs, tagSrgbLin, bitDepth = 10,
        gamut = gamutPq).get
    let conv = img.toIctcpWorkSpace().get
    check conv.workSpace == tagIctcp
    for c in conv.pixels:
      check c.spaceTag() == tagIctcp

  test "immutable: the input image is untouched":
    let pxs = [linHdr(1.5'f32, 0.2'f32, 0.1'f32)]
    let img = hdrImage(1, 1, pxs, tagSrgbLin, bitDepth = 10,
        gamut = gamutPq).get
    let before = img.pixels[0]
    discard img.toIctcpWorkSpace().get
    check img.pixels[0] == before # input buffer unchanged.

  test "no-op when already in ICtCp":
    let pxs = [color(tagIctcp, 0.5'f32, 0.1'f32, -0.2'f32).get]
    let img = hdrImage(1, 1, pxs, tagIctcp, bitDepth = 10, gamut = gamutPq).get
    let conv = img.toIctcpWorkSpace().get
    check conv.pixels[0] == img.pixels[0] # copied unchanged.

suite "HDR — out-of-gamut preservation (no blanket clamp)":
  test "HDR comps (>1) survive sRGB-linear -> ICtCp -> sRGB-linear":
    # An HDR-bright linear pixel (comps > 1) converts to ICtCp and back; the
    # out-of-gamut values are preserved within TOL_ROUNDTRIP.
    let hdr = linHdr(1.5'f32, 0.3'f32, 0.2'f32)
    let toIc = hdr.to(tagIctcp).get
    let back = toIc.to(tagSrgbLin).get
    check nearT(back.comp(0).float64, 1.5, TOL_ROUNDTRIP)
    check nearT(back.comp(1).float64, 0.3, TOL_ROUNDTRIP)
    check nearT(back.comp(2).float64, 0.2, TOL_ROUNDTRIP)

  test "HDR brightness -> higher ICtCp I than SDR (PQ encodes HDR luminance)":
    # A linear pixel at HDR brightness (comp 1.5) yields a strictly greater
    # ICtCp I than the SDR version (comp 1.0) — PQ encodes 0..10000 nits.
    let sdr = linHdr(1.0'f32, 1.0'f32, 1.0'f32).to(tagIctcp).get
    let hdrB = linHdr(1.5'f32, 1.5'f32, 1.5'f32).to(tagIctcp).get
    check hdrB.comp(0).float64 > sdr.comp(0).float64

suite "HDR — ICtCp golden anchor (colour-science, sanity)":
  test "known linear-Rec2020 pixel -> ICtCp ~= (0.0735, 0.0048, 0.0935)":
    # Mirrors tests/conversion/test_hub_i7c: linear Rec2020 RGB
    # (0.4562, 0.0308, 0.0409) -> ICtCp (0.0735136, 0.0047525, 0.0935159).
    let pxs = [color(tagRec2020Lin, 0.45620519'f32, 0.03081071'f32,
        0.04091952'f32).get]
    let img = hdrImage(1, 1, pxs, tagRec2020Lin, bitDepth = 10,
        gamut = gamutPq).get
    let conv = img.toIctcpWorkSpace().get
    let ic = conv.pixels[0]
    check nearT(ic.comp(0).float64, 0.0735136, 1.0e-3)
    check nearT(ic.comp(1).float64, 0.0047525, 1.0e-3)
    check nearT(ic.comp(2).float64, 0.0935159, 1.0e-3)

# ===========================================================================
# Image-layer determinism (seed + thread-count invariance).
# ===========================================================================

# A well-separated 3-block reference image -> k-means converges to the 3 block
# centers regardless of init seed (no local-optima ambiguity).
proc threeBlockImage(): Image {.raises: [].} =
  let red = srgb255(220, 20, 20)
  let green = srgb255(20, 200, 20)
  let blue = srgb255(20, 20, 220)
  var pxs: seq[Color] = @[]
  for i in 0 ..< 30: pxs.add(red)
  for i in 0 ..< 20: pxs.add(green)
  for i in 0 ..< 10: pxs.add(blue)
  image(60, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get

# Sort a color set by (L, a, b) comps for order-independent set comparison.
proc sortedSet(cs: seq[Color]): seq[Color] {.raises: [].} =
  result = cs
  result.sort(proc(x, y: Color): int =
    let xl = x.comp(0).float64
    let yl = y.comp(0).float64
    if xl < yl: return -1
    if xl > yl: return 1
    let xa = x.comp(1).float64
    let ya = y.comp(1).float64
    if xa < ya: return -1
    if xa > ya: return 1
    let xb = x.comp(2).float64
    let yb = y.comp(2).float64
    if xb < yb: return -1
    if xb > yb: return 1
    return 0)

# Two color sets equal as sets within TOL_NUMERIC (order-independent).
proc setsEqual(a, b: seq[Color]): bool {.raises: [].} =
  if a.len != b.len: return false
  let sa = sortedSet(a)
  let sb = sortedSet(b)
  for i in 0 ..< sa.len:
    if not nearlyEqual(sa[i].comp(0).float64, sb[i].comp(0).float64):
      return false
    if not nearlyEqual(sa[i].comp(1).float64, sb[i].comp(1).float64):
      return false
    if not nearlyEqual(sa[i].comp(2).float64, sb[i].comp(2).float64):
      return false
  true

suite "image determinism — seed invariance":
  test "k-means++ (kmeansPP): different seeds -> same centroid SET":
    # The robust init (k-means++, D2-proportional) converges to the natural
    # clusters regardless of seed — only the cluster INDEX order may differ.
    let img = threeBlockImage()
    let seeds = [int64(0), 1, 42, 999, 1234567]
    var refColors: seq[Color] = @[]
    for s in seeds:
      var o = defaultQuantizeOpts()
      o.seed = s
      let pal = img.extractPalette(3, "kmeansPP", tagOklab, o).get
      let cs = pal.colors()
      check cs.len == 3
      if refColors.len == 0:
        refColors = cs
      else:
        check setsEqual(cs, refColors) # same set, any order.

  test "k-means (random init): FIXED seed -> bit-identical; <= n centroids":
    # Random init is NOT seed-invariant — it can land in a local optimum or
    # duplicate centroids. The honest property: (a) a FIXED seed is
    # deterministic, (b) it always returns <= n centroids.
    let img = threeBlockImage()
    var o = defaultQuantizeOpts()
    o.seed = 7
    let a = img.extractPalette(3, "kmeans", tagOklab, o).get.colors()
    let b = img.extractPalette(3, "kmeans", tagOklab, o).get.colors()
    check a.len <= 3 and a.len >= 1
    check a.len == b.len
    for i in 0 ..< a.len:
      check a[i] == b[i] # fixed seed -> bit-identical.

  test "Wu extractPalette: bit-identical across seeds (no RNG)":
    let img = threeBlockImage()
    var o0 = defaultQuantizeOpts()
    o0.seed = 0
    var o1 = defaultQuantizeOpts()
    o1.seed = 9999
    let p0 = img.extractPalette(3, "wu", tagOklab, o0).get
    let p1 = img.extractPalette(3, "wu", tagOklab, o1).get
    let c0 = p0.colors()
    let c1 = p1.colors()
    check c0.len == c1.len
    for i in 0 ..< c0.len:
      check c0[i] == c1[i] # bit-identical (no RNG in Wu).

  test "dominantColors: bit-identical across repeated calls (no seed, no RNG)":
    let img = threeBlockImage()
    let a = img.dominantColors(3).get
    let b = img.dominantColors(3).get
    check a.len == b.len
    for i in 0 ..< a.len:
      check a[i] == b[i]

suite "image determinism — #threads-invariance (contract surface)":
  # The image layer routes `opts.parallel`/`opts.threads` to the serial path
  # today (the deferred-parallel contract surface; real dispatch is a later
  # perf lot gated by `*MinParallelPixels`). So #threads-invariance is
  # trivially true now — these tests pin the property so the future lot
  # cannot regress it: same image + same opts -> same result.
  test "extractPalette (kmeans) called twice -> bit-identical (serial baseline)":
    let img = threeBlockImage()
    var o = defaultQuantizeOpts()
    o.seed = 0
    let a = img.extractPalette(3, "kmeans", tagOklab, o).get.colors()
    let b = img.extractPalette(3, "kmeans", tagOklab, o).get.colors()
    check a.len == b.len
    for i in 0 ..< a.len:
      check a[i] == b[i]

  test "extractPalette (wu) called twice -> bit-identical (serial baseline)":
    let img = threeBlockImage()
    let a = img.extractPalette(3, "wu", tagOklab).get.colors()
    let b = img.extractPalette(3, "wu", tagOklab).get.colors()
    check a.len == b.len
    for i in 0 ..< a.len:
      check a[i] == b[i]

  test "dominantColors called twice -> bit-identical (serial baseline)":
    let img = threeBlockImage()
    let a = img.dominantColors(3).get
    let b = img.dominantColors(3).get
    check a.len == b.len
    for i in 0 ..< a.len:
      check a[i] == b[i]

suite "image determinism — green image, same dominant colors":
  # A GREEN-dominated reference image (16 greens + 4 reds + 2 blues,
  # well-separated) -> green dominates. The image layer is serial today, so
  # this is the baseline the property pins; the future parallel lot must
  # preserve it.
  proc greenImage(): Image {.raises: [].} =
    let green = srgb255(20, 200, 20)
    let red = srgb255(210, 30, 30)
    let blue = srgb255(30, 30, 210)
    var pxs: seq[Color] = @[]
    for i in 0 ..< 16: pxs.add(green)
    for i in 0 ..< 4: pxs.add(red)
    for i in 0 ..< 2: pxs.add(blue)
    image(22, 1, pxs, tagSrgb).get.toWorkSpace(tagOklab).get

  test "green image: dominantColors called twice -> bit-identical":
    let img = greenImage()
    let a = img.dominantColors(3).get
    let b = img.dominantColors(3).get
    check a.len == b.len
    for i in 0 ..< a.len:
      check a[i] == b[i] # bit-identical, green first (the majority).

  test "green image: extractPalette(kmeans++) twice -> bit-identical":
    let img = greenImage()
    var o = defaultQuantizeOpts()
    o.seed = 0
    let a = img.extractPalette(3, "kmeansPP", tagOklab, o).get.colors()
    let b = img.extractPalette(3, "kmeansPP", tagOklab, o).get.colors()
    check a.len == b.len
    for i in 0 ..< a.len:
      check a[i] == b[i]

  test "green image: extractPalette(kmeans++) seed-invariant -> same SET":
    # Well-separated -> k-means++ converges to the same 3 block centers
    # regardless of seed (only order differs). Green (16) is the heaviest.
    let img = greenImage()
    var refColors: seq[Color] = @[]
    for s in [int64(0), 5, 50, 500]:
      var o = defaultQuantizeOpts()
      o.seed = s
      let cs = img.extractPalette(3, "kmeansPP", tagOklab, o).get.colors()
      check cs.len == 3
      if refColors.len == 0: refColors = cs
      else: check setsEqual(cs, refColors)
