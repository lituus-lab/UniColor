# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# correction — explicit color correction primitives. Three registered
# algorithms, all operating in OKLCH (D65, so the round-trip is tight):
#   - hueShift:       h -> (h + delta) mod 360  (cyclic, never clamps).
#   - luminanceShift: L -> clamp(L + delta, [0,1])  (warns when clamped).
#   - chromaCompress: C -> C * factor, factor in [0,1]  (err when out of range).
# Correction is EXPLICIT: the caller picks the algorithm and its parameters;
# nothing is applied behind their back. When a luminance shift cannot reach its
# target (clamped at 0 or 1) a warning string is returned so the caller can
# surface it — the only place a correction is lossy, reported, never swallowed.
# Each primitive returns the corrected color in the SAME space as the input,
# preserves alpha, and never mutates the input. Algorithms are registered
# descriptors so a future one registers without touching the core.
import std/options
import std/tables
import std/math # `clamp`, for the luminance clamp.
import UniColor/core/core
import UniColor/conversion/conversion # `to` (OKLCH round-trip; D65 = tight).

type
  CorrectionOpts* = object
    ## Parameters for a correction. `delta` is the hue/luminance shift; `factor`
    ## is the chroma compression factor in [0,1]. Only one is read per algorithm.
    delta*: float64
    factor*: float64

  CorrectionResult* = object
    ## The corrected color plus a `warning` that is "" when nothing lossy
    ## happened. A non-empty `warning` means the requested correction could not
    ## be applied exactly (e.g. a luminance shift clamped at 0 or 1) — surfaced
    ## explicitly, never silently.
    color*: Color
    warning*: string

  CorrectionAlgo* = object
    ## Descriptor for a registered correction algorithm (data-driven like the
    ## metric and CVD registries). `compute` returns the corrected color or a
    ## conversion error.
    name*: string
    compute*: proc(c: Color, opts: CorrectionOpts): Result[CorrectionResult,
        ColorError] {.raises: [].}

# Registry — module-level table, idempotent registration, optional seal.
var
  corrByName: Table[string, CorrectionAlgo]
  corrSealed: bool

proc registerCorrectionAlgo*(a: CorrectionAlgo): bool {.raises: [].} =
  if corrSealed or a.name.len == 0 or corrByName.hasKey(a.name):
    return false
  corrByName[a.name] = a
  true

proc lookupCorrectionAlgo*(name: string): Option[CorrectionAlgo] {.raises: [].} =
  if corrByName.hasKey(name):
    some(corrByName.getOrDefault(name))
  else:
    none(CorrectionAlgo)

proc correctionAlgoCount*(): int {.raises: [].} =
  corrByName.len

proc sealCorrectionAlgos*() {.raises: [].} =
  corrSealed = true

# Build the corrected OKLCH color and round it back to the input's space. The
# OKLCH comps are built out-of-gamut-tolerant (`color` validates tag/alpha/NaN
# but preserves comps), and the round-trip back uses the conversion hub.
proc buildBack(c: Color, L, C, h: float64): Result[Color,
    ColorError] {.raises: [].} =
  let builtR = color(tagOklch, L.float32, C.float32, h.float32, c.alpha())
  if builtR.isErr:
    return err[Color, ColorError](builtR.error)
  builtR.get.to(c.spaceTag)

proc shiftHue*(c: Color, delta: float64): Result[CorrectionResult,
    ColorError] {.raises: [].} =
  ## OKLCH hue shift: h -> (h + delta) mod 360. Hue is cyclic, so this never
  ## clamps and never warns. Achromatic inputs (C ~ 0, hue undefined) stay
  ## achromatic — no color is introduced.
  let okR = c.to(tagOklch)
  if okR.isErr:
    return err[CorrectionResult, ColorError](okR.error)
  let o = okR.get
  let h = o.comp(2).float64
  let newH = ((h + delta) mod 360.0 + 360.0) mod 360.0
  let backR = buildBack(c, o.comp(0).float64, o.comp(1).float64, newH)
  if backR.isErr:
    return err[CorrectionResult, ColorError](backR.error)
  ok[CorrectionResult, ColorError](CorrectionResult(color: backR.get, warning: ""))

proc shiftL*(c: Color, delta: float64): Result[CorrectionResult,
    ColorError] {.raises: [].} =
  ## OKLCH luminance shift: L -> clamp(L + delta, [0,1]). Warns (non-empty
  ## `warning`) when the target was clamped at 0 or 1 — explicit, never silent.
  ## Hue and chroma are preserved.
  let okR = c.to(tagOklch)
  if okR.isErr:
    return err[CorrectionResult, ColorError](okR.error)
  let o = okR.get
  let l0 = o.comp(0).float64 + delta
  let newL = clamp(l0, 0.0, 1.0)
  let warn = if newL != l0: "luminance clamped to [0,1]" else: ""
  let backR = buildBack(c, newL, o.comp(1).float64, o.comp(2).float64)
  if backR.isErr:
    return err[CorrectionResult, ColorError](backR.error)
  ok[CorrectionResult, ColorError](CorrectionResult(color: backR.get,
      warning: warn))

proc compressChroma*(c: Color, factor: float64): Result[CorrectionResult,
    ColorError] {.raises: [].} =
  ## OKLCH chroma compression: C -> C * factor, factor in [0,1]. factor out of
  ## range is an `InvalidColor` (a programming error, not a clampable value).
  ## factor = 0 collapses to achromatic. No warning — scaling is the requested
  ## operation, not a lossy clamp.
  if factor < 0.0 or factor > 1.0:
    return err[CorrectionResult, ColorError](colorError(InvalidColor,
        "chroma compression factor must be in [0,1], got " & $factor,
        "compressChroma"))
  let okR = c.to(tagOklch)
  if okR.isErr:
    return err[CorrectionResult, ColorError](okR.error)
  let o = okR.get
  let newC = o.comp(1).float64 * factor
  let backR = buildBack(c, o.comp(0).float64, newC, o.comp(2).float64)
  if backR.isErr:
    return err[CorrectionResult, ColorError](backR.error)
  ok[CorrectionResult, ColorError](CorrectionResult(color: backR.get, warning: ""))

# Registered compute wrappers (close over the primitives so `correct` can
# dispatch by name).
proc computeHueShift(c: Color, opts: CorrectionOpts): Result[CorrectionResult,
    ColorError] {.raises: [].} =
  shiftHue(c, opts.delta)

proc computeLuminanceShift(c: Color, opts: CorrectionOpts): Result[
    CorrectionResult, ColorError] {.raises: [].} =
  shiftL(c, opts.delta)

proc computeChromaCompress(c: Color, opts: CorrectionOpts): Result[
    CorrectionResult, ColorError] {.raises: [].} =
  compressChroma(c, opts.factor)

proc correct*(c: Color, algo: string, opts: CorrectionOpts): Result[
    CorrectionResult, ColorError] {.raises: [].} =
  ## Dispatched correction: look up `algo` and apply it with `opts`. Returns
  ## `err` with `UnknownAlgorithm` if the algorithm is absent, or the
  ## conversion error from the underlying primitive otherwise. Deterministic,
  ## no input mutation.
  let a = lookupCorrectionAlgo(algo)
  if a.isNone:
    return err[CorrectionResult, ColorError](colorError(UnknownAlgorithm,
        "unknown correction algorithm: " & algo, "correct"))
  a.get.compute(c, opts)

# Bootstrap — register the three primitives. A future correction algorithm
# registers here via the same `registerCorrectionAlgo` (extensible, no core
# change).
discard registerCorrectionAlgo(CorrectionAlgo(name: "hueShift",
    compute: computeHueShift))
discard registerCorrectionAlgo(CorrectionAlgo(name: "luminanceShift",
    compute: computeLuminanceShift))
discard registerCorrectionAlgo(CorrectionAlgo(name: "chromaCompress",
    compute: computeChromaCompress))
