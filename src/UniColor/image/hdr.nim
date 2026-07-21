# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# hdr — HDR image support (float pixels, ICtCp perceptual work space). HDR
# images carry `bitDepth > 8` and `gamut` in {gamutHdr, gamutPq} (PQ/HLG,
# BT.2100); the perceptual work space is ICtCp. Out-of-gamut comps (> 1.0)
# are preserved (no blanket clamp). For HDR clustering, pass `space = tagIctcp`
# to the quantize/histogram/dither entry points.
#
# Layer: image (consumer of image/internal). Deterministic.
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/core/result
import UniColor/core/color_error
import UniColor/image/internal

const
  DefaultHdrWorkSpace* = tagIctcp ## ICtCp — HDR perceptual work space
                                  ## (parallels OKLab for SDR).
  HdrMinBitDepth* = 9             ## `bitDepth > 8` marks HDR (10/12/16 typical); 8-bit is SDR.

proc isHdr*(img: Image): bool {.raises: [].} =
  ## Whether `img` is HDR: both markers — PQ/HLG gamut AND bit depth > 8 (the
  ## invariant `hdrImage` enforces; a high-bit-depth SDR image is not HDR).
  img.gamut in {gamutHdr, gamutPq} and img.bitDepth > 8

proc hdrImage*(width, height: int, pixels: openArray[Color],
    originSpace: SpaceTag, bitDepth: int, gamut: Gamut): Result[Image,
        ColorError] {.raises: [].} =
  ## Build an HDR `Image`: enforces HDR semantics — `bitDepth > 8` and `gamut`
  ## in {gamutHdr, gamutPq} — then delegates dimension/space validation to
  ## `image()`. Float pixels (comps > 1.0 for HDR brightness) are preserved
  ## out-of-gamut (no blanket clamp). `bitDepth <= 8` or `gamutSdr` -> `err
  ## InvalidOp` (an SDR image mislabelled HDR is rejected, not silently
  ## built). `image()`'s own `InvalidImage` / `UnknownSpace` propagate.
  if bitDepth <= HdrMinBitDepth - 1: # bitDepth <= 8.
    return err[Image, ColorError](colorError(InvalidOp,
        "hdrImage: bitDepth must be > 8 for HDR, got " & $bitDepth, "hdrImage"))
  if gamut == gamutSdr:
    return err[Image, ColorError](colorError(InvalidOp,
        "hdrImage: gamut must be gamutHdr or gamutPq for HDR, got gamutSdr",
        "hdrImage"))
  image(width, height, pixels, originSpace, bitDepth, gamut)

proc toIctcpWorkSpace*(img: Image): Result[Image, ColorError] {.raises: [].} =
  ## Convert `img` to ICtCp — the HDR perceptual work space (the HDR analogue
  ## of `toWorkSpace(tagOklab)` for SDR). Immutable (a fresh buffer is built;
  ## `img` untouched). HDR / out-of-gamut comps are preserved (no blanket
  ## clamp). Conversion error (unknown space / unreachable hub) propagates.
  ## Deterministic.
  img.toWorkSpace(DefaultHdrWorkSpace)
