# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# image — Image value type + quantize / histogram / dither / HDR. Umbrella
# re-exporting the submodules so callers reach them via
# `UniColor/image/image`.
import UniColor/image/internal
import UniColor/image/loader
import UniColor/image/quantize
import UniColor/image/quantize_wu
import UniColor/image/quantize_kmeans
import UniColor/image/quantize_misc
import UniColor/image/histogram
import UniColor/image/dither
import UniColor/image/hdr

export internal
export loader
export quantize
export quantize_wu
export quantize_kmeans
export quantize_misc
export histogram
export dither
export hdr

## Immutable `Image` value type (width, height, pixels in a work space,
## bitDepth, gamut) plus the image-layer tools: a format-free loader registry
## (caller-registered decoders; the engine ships only "nimraw"), a
## data-driven quantizer registry (Wu default; k-means / k-means++ / WSM,
## medianCut, octree, NeuQuant), a 3D OKLCH histogram + dominant-color
## extractor, error-diffusion + ordered dithering, and HDR construction
## (ICtCp perceptual work space). All algos are deterministic and run in
## the image's work space (default OKLab, ICtCp for HDR).
runnableExamples:
  import UniColor/core/core
  let red = color(tagSrgb, 1.0'f32, 0.0'f32, 0.0'f32).get
  let blu = color(tagSrgb, 0.0'f32, 0.0'f32, 1.0'f32).get
  let img = image(2, 2, [red, blu, red, blu], tagSrgb).get
  # Default quantizer (Wu) into a 2-color OKLab palette:
  let pal = extractPalette(img, 2).get
  doAssert pal.len <= 2
  # Dominant colors (histogram modes) in OKLab:
  doAssert dominantColors(img, 2).get.len <= 2

const imageModule* = "0.1.0"
