# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# internal — `Image` value type: pixels + metadata. The narrow color pipeline
# starts here: an `Image` is a decoded pixel buffer tagged with its origin
# space, bit depth and gamut (SDR/HDR/PQ), so the rest of the image module
# (histogram, dominant colors, quantization) can convert pixels into a
# perceptual work space (OKLab) without losing the origin context.
#
# Storage: AoS `seq[Color]` — the simple pixel-at-a-time interface. The SoA
# `OklabPlanes` view (L/a/b/alpha planes) is derived from an OKLab image for
# vectorized quantization (SoA internal, AoS interface; the SIMD reorg that
# makes SoA the canonical store is a later perf lot, not this scope).
#
# `Image` OWNS its pixels (value type, ARC move semantics). No shared mutable
# view. Layer: image (consumer of core + conversion). Deterministic.
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/core/result
import UniColor/core/color_error
import UniColor/conversion/conversion # `to` for the OKLab work space conversion.

type
  Gamut* {.pure.} = enum
    ## Dynamic range of the image. SDR = conventional 8-bit display; HDR =
    ## wide-gamut/extended; PQ = perceptual quantizer (HLG/PQ transfer). Most
    ## loaders produce SDR; HDR support (float pixels, ICtCp) lives in `hdr`.
    gamutSdr
    gamutHdr
    gamutPq

  Image* = object
    ## Decoded image: a pixel buffer + its origin context. `pixels` are `Color`
    ## values in `workSpace` (starts at `originSpace` for a freshly loaded
    ## image — sRGB by default — and becomes OKLab after `toWorkSpace`),
    ## row-major (row 0 = top). `width` and `height` are strictly positive (a
    ## 0x0 image is `InvalidImage`, never constructed). The AoS `seq[Color]` is
    ## the access interface; `oklabPlanes` exposes the SoA L/a/b/alpha planes
    ## derived from it for vectorized quantization.
    ##
    ## Encapsulation: the fields are PRIVATE. Reads happen through the
    ## same-named exported accessor procs below (`img.width`, `img.pixels`, ...)
    ## — Nim resolves `obj.field` to the field inside this module and to the
    ## proc outside (UFCS), so read sites are unchanged. Only `image()`
    ## constructs an `Image`, so the "dims>0, pixel count matches, known space"
    ## invariant cannot be bypassed by out-of-module construction.
    width: int
    height: int
    pixels: seq[Color]
    originSpace: SpaceTag
    workSpace: SpaceTag
    bitDepth: int
    gamut: Gamut

  OklabPlanes* = object
    ## SoA view of an OKLab image: the L, a, b and alpha component planes as
    ## separate `seq[float32]` (SIMD-friendly). Derived from an `Image` whose
    ## `workSpace == tagOklab`. The quantizer reads these planes; the
    ## SoA<->AoS equivalence (planes == per-pixel comps) is the zero-cost
    ## bridge property verified in tests.
    l*: seq[float32]
    a*: seq[float32]
    b*: seq[float32]
    alpha*: seq[float32]

# Encapsulation accessors: same-named procs so external `img.width` /
# `img.pixels` read the private field via UFCS — read sites stay unchanged,
# only construction is gated by `image()`. `lent` returns a read-only borrow of
# the pixel buffer (no copy); metadata scalars return by value.
proc width*(i: Image): int {.inline, raises: [].} = i.width
proc height*(i: Image): int {.inline, raises: [].} = i.height
proc pixels*(i: Image): lent seq[Color] {.inline, raises: [].} = i.pixels
proc originSpace*(i: Image): SpaceTag {.inline, raises: [].} = i.originSpace
proc workSpace*(i: Image): SpaceTag {.inline, raises: [].} = i.workSpace
proc bitDepth*(i: Image): int {.inline, raises: [].} = i.bitDepth
proc gamut*(i: Image): Gamut {.inline, raises: [].} = i.gamut

proc image*(width, height: int, pixels: openArray[Color],
    originSpace: SpaceTag, bitDepth = 8, gamut = gamutSdr): Result[Image,
    ColorError] {.raises: [].} =
  ## Build an `Image` from a pixel buffer. Validates: positive dimensions,
  ## pixel count matches `width*height`, known origin space. Returns
  ## `InvalidImage` on a 0x0 / mismatched buffer and `UnknownSpace` on an
  ## untagged origin. No pixel is converted here — `workSpace` starts equal to
  ## `originSpace`; `toWorkSpace` moves it to OKLab.
  if width <= 0 or height <= 0:
    return err[Image, ColorError](colorError(InvalidImage,
        "image dimensions must be > 0, got " & $width & "x" & $height, "image"))
  if pixels.len != width * height:
    return err[Image, ColorError](colorError(InvalidImage,
        "pixel count (" & $pixels.len & ") must equal width*height (" &
        $(width * height) & ")", "image"))
  if originSpace == tagUnknown:
    return err[Image, ColorError](colorError(UnknownSpace,
        "image origin space is unknown", "image"))
  if bitDepth <= 0:
    return err[Image, ColorError](colorError(InvalidImage,
        "bit depth must be > 0, got " & $bitDepth, "image"))
  ok[Image, ColorError](Image(width: width, height: height,
      pixels: @pixels, originSpace: originSpace, workSpace: originSpace,
      bitDepth: bitDepth, gamut: gamut))

proc pixelAt*(img: Image, x, y: int): Result[Color, ColorError] {.raises: [].} =
  ## AoS pixel accessor: the `Color` at column `x`, row `y` (row 0 = top), in
  ## `img.workSpace`. Out-of-bounds -> err `InvalidImage` (a programming
  ## error, not a recoverable domain value). The SoA bridge (`oklabPlanes`,
  ## when workSpace is OKLab) resolves to the same value.
  if x < 0 or x >= img.width or y < 0 or y >= img.height:
    return err[Color, ColorError](colorError(InvalidImage,
        "pixel (" & $x & "," & $y & ") out of " & $img.width & "x" &
        $img.height, "pixelAt"))
  ok[Color, ColorError](img.pixels[y * img.width + x])

proc len*(img: Image): int {.raises: [].} =
  ## Total pixel count (`width*height`).
  img.width * img.height

proc isEmpty*(img: Image): bool {.raises: [].} =
  ## Whether the image has no pixels. Always false for a validated `Image`
  ## (dims > 0); kept for defensive checks on values not built via `image()`.
  img.width == 0 or img.height == 0 or img.pixels.len == 0

proc toWorkSpace*(img: Image, target: SpaceTag): Result[Image,
    ColorError] {.raises: [].} =
  ## Return a NEW `Image` with all pixels converted to the `target` work space.
  ## Immutable: `img` is untouched; a fresh buffer is built. `originSpace` and
  ## the other metadata are preserved; only `workSpace` becomes `target`. When
  ## `img.workSpace` already equals `target`, the pixels are copied unchanged.
  ## Conversion error (unknown space / unreachable hub) is propagated.
  ## Deterministic, single-threaded (parallel bulk is a later perf lot).
  if target == tagUnknown:
    return err[Image, ColorError](colorError(UnknownSpace,
        "target work space is unknown", "toWorkSpace"))
  var outPx = newSeq[Color](img.pixels.len)
  for i, c in img.pixels:
    if img.workSpace == target:
      outPx[i] = c
    else:
      let cR = c.to(target)
      if cR.isErr:
        return err[Image, ColorError](cR.error)
      outPx[i] = cR.get
  ok[Image, ColorError](Image(width: img.width, height: img.height,
      pixels: outPx, originSpace: img.originSpace, workSpace: target,
      bitDepth: img.bitDepth, gamut: img.gamut))

proc oklabPlanes*(img: Image): Result[OklabPlanes, ColorError] {.raises: [].} =
  ## SoA view of an OKLab image: the L/a/b/alpha component planes as separate
  ## `seq[float32]`. Requires `img.workSpace == tagOklab` (the caller converts
  ## once via `toWorkSpace`); otherwise returns `err InvalidOp` — the planes are
  ## the OKLab comps, not a silent cross-space derivation. The planes are read
  ## directly from the OKLab `Color` comps, so they are bit-identical to
  ## `pixelAt` comps (the SoA<->AoS zero-cost bridge property).
  if img.workSpace != tagOklab:
    return err[OklabPlanes, ColorError](colorError(InvalidOp,
        "oklabPlanes requires workSpace == oklab, got " & $img.workSpace,
        "oklabPlanes"))
  var p: OklabPlanes
  let n = img.pixels.len
  p.l = newSeq[float32](n)
  p.a = newSeq[float32](n)
  p.b = newSeq[float32](n)
  p.alpha = newSeq[float32](n)
  for i, c in img.pixels:
    p.l[i] = c.comp(0)
    p.a[i] = c.comp(1)
    p.b[i] = c.comp(2)
    p.alpha[i] = c.alpha()
  ok[OklabPlanes, ColorError](p)
