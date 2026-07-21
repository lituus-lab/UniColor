# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# loader — `ImageLoader` registry: injected decoding, narrow pipeline.
# UniColor does NOT parse image formats. Decoding is DELEGATED to an injected
# loader — a proc the caller registers by name that turns encoded `bytes` into
# an `Image`. The engine stays format-free (no stb_image/libvips/libpng in the
# core); the caller registers a PNG/JPEG/WebP loader from whichever library
# they chose. This is the Open/Closed seam: a new format = a new registered
# loader, no core change.
#
# Layer-0 rule: UniColor ships NO PNG/JPEG/WebP encode or decode. PNG lives in
# the later UniImage repo. The engine ships ONE default loader — "nimraw" — a
# trivial engine-native raw format (`u32 LE width` | `u32 LE height` | RGBA8
# pixels) used by tests/golden so the pipeline can be exercised without an
# external image dependency. It is NOT a real format; real decoders are
# caller-registered. Fuzz: empty bytes / 0x0 dims / truncated buffer ->
# `InvalidImage`.
#
# Layer: image (consumer of core + image/internal). Deterministic, no input
# mutation.
import std/options
import std/tables
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/core/result
import UniColor/core/color_error
import UniColor/image/internal # `Image`, `image()`, `Gamut`.

type
  ImageLoader* = object
    ## Descriptor for a registered image decoder (data-driven like the
    ## metric/CVD/correction registries). `decode` turns encoded `bytes` into
    ## an `Image` (validating per its format); on a malformed/empty/truncated
    ## input it returns `err InvalidImage`.
    name*: string
    decode*: proc(bytes: openArray[byte]): Result[Image, ColorError] {.raises: [].}

# Registry — module-level table, idempotent registration, optional seal
# (mirrors the other registries). Extensible: a downstream user registers
# their own format decoder.
var
  loaderByName: Table[string, ImageLoader]
  loaderSealed: bool

proc registerImageLoader*(l: ImageLoader): bool {.raises: [].} =
  ## Register a loader by name. Idempotent: a sealed registry or an
  ## empty/duplicate name or a nil `decode` is rejected (returns false).
  if loaderSealed or l.name.len == 0 or loaderByName.hasKey(l.name) or
      l.decode.isNil:
    return false
  loaderByName[l.name] = l
  true

proc lookupImageLoader*(name: string): Option[ImageLoader] {.raises: [].} =
  if loaderByName.hasKey(name):
    some(loaderByName.getOrDefault(name))
  else:
    none(ImageLoader)

proc imageLoaderCount*(): int {.raises: [].} =
  loaderByName.len

proc imageLoaderNames*(): seq[string] {.raises: [].} =
  result = @[]
  for k in keys(loaderByName):
    result.add(k)

proc sealImageLoaders*() {.raises: [].} =
  loaderSealed = true

proc decode*(name: string, bytes: openArray[byte]): Result[Image,
    ColorError] {.raises: [].} =
  ## Decode `bytes` with the registered loader `name`. Unknown name -> `err
  ## UnknownAlgorithm` (the decoder is absent); a malformed input ->
  ## `InvalidImage` from the loader itself (propagated). Deterministic, no
  ## input mutation.
  let l = lookupImageLoader(name)
  if l.isNone:
    return err[Image, ColorError](colorError(UnknownAlgorithm,
        "unknown image loader: " & name, "decode"))
  l.get.decode(bytes)

# --- default "nimraw" loader -------------------------------------------------
# Engine-native raw format: [u32 LE width][u32 LE height][RGBA8 pixels,
# row-major]. Used by tests/golden so the pipeline runs without an external
# image dependency. NOT a real format.
proc u32le(b: openArray[byte], i: int): uint32 {.raises: [].} =
  # Little-endian uint32 at byte offset `i` (manual decode — portable, no
  # endianness assumption).
  b[i].uint32 or (b[i + 1].uint32 shl 8) or (b[i + 2].uint32 shl 16) or
      (b[i + 3].uint32 shl 24)

const
  NimrawHeader = 8   # two u32 (width, height).
  NimrawChannels = 4 # RGBA8.

proc decodeNimraw*(bytes: openArray[byte]): Result[Image,
    ColorError] {.raises: [].} =
  ## "nimraw" decoder: u32-LE width + u32-LE height + RGBA8 pixels. Validates
  ## header presence, positive dims, and exact payload size; each channel byte
  ## maps to sRGB gamma-encoded [0,1] (r/255 — the sRGB convention). Pixels are
  ## built directly in `tagSrgb` (no OKLab conversion here — that is the
  ## `toWorkSpace` step). alpha = a/255.
  if bytes.len < NimrawHeader:
    return err[Image, ColorError](colorError(InvalidImage,
        "nimraw: header truncated (need " & $NimrawHeader & " bytes, got " &
        $bytes.len & ")", "decodeNimraw"))
  let w = int(u32le(bytes, 0))
  let h = int(u32le(bytes, NimrawHeader div 2))
  if w <= 0 or h <= 0:
    return err[Image, ColorError](colorError(InvalidImage,
        "nimraw: dimensions must be > 0, got " & $w & "x" & $h, "decodeNimraw"))
  let expected = NimrawHeader + w * h * NimrawChannels
  if bytes.len != expected:
    return err[Image, ColorError](colorError(InvalidImage,
        "nimraw: payload size " & $(bytes.len - NimrawHeader) &
        " != width*height*4 (" & $(w * h * NimrawChannels) & ")",
        "decodeNimraw"))
  var pxs = newSeq[Color](w * h)
  var off = NimrawHeader
  for i in 0 ..< w * h:
    let r = bytes[off].float32 / 255.0'f32
    let g = bytes[off + 1].float32 / 255.0'f32
    let b = bytes[off + 2].float32 / 255.0'f32
    let a = bytes[off + 3].float32 / 255.0'f32
    let cR = color(tagSrgb, r, g, b, a)
    if cR.isErr:
      return err[Image, ColorError](cR.error)
    pxs[i] = cR.get
    off += NimrawChannels
  image(w, h, pxs, tagSrgb, 8, gamutSdr)

# Bootstrap — register the default raw loader. Real format decoders
# (PNG/JPEG/WebP) are caller-registered via `registerImageLoader` (the engine
# ships none — layer-0 no-PNG rule).
discard registerImageLoader(ImageLoader(name: "nimraw", decode: decodeNimraw))
