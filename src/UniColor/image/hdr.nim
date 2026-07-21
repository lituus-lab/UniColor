# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# hdr — HDR image support (float pixels, ICtCp perceptual work space). HDR
# images carry `bitDepth > 8` and `gamut` in {gamutHdr, gamutPq} (PQ/HLG
# transfer, BT.2100). The pipeline is identical to SDR; the perceptual work
# space for HDR is ICtCp (BT.2100 PQ, Rec2020) instead of OKLab — ICtCp is the
# HDR-aware perceptual space. Out-of-gamut / HDR values (comps > 1.0) are
# PRESERVED — no blanket clamp: the `Color` constructor already rejects only
# NaN/Inf and out-of-range alpha, keeping out-of-gamut comps verbatim, and
# `to`/`toWorkSpace` propagate them.
#
# This module adds HDR-specific construction + the ICtCp work-space seam. The
# existing quantize / histogram / dither algos run unchanged in any work space
# — for HDR the caller passes `space = tagIctcp` (euclidean on the ICtCp
# comps; the half-scaling of Ct in ΔE_ITP is a refinement deferred to a future
# HDR-clustering lot — documented, out of scope here).
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
  ## Whether `img` is HDR: PQ/HLG gamut, or bit depth > 8 (the two HDR markers).
  img.gamut in {gamutHdr, gamutPq} or img.bitDepth > 8

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
  ## `img` untouched). HDR / out-of-gamut comps are preserved through the
  ## conversion (no blanket clamp — the hub routes via XYZ -> PQ, which
  ## encodes 0..10000 nits). Conversion error (unknown space / unreachable
  ## hub) propagates. Deterministic, single-threaded (parallel bulk is a
  ## later perf lot).
  img.toWorkSpace(DefaultHdrWorkSpace)
