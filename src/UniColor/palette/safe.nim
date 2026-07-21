# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# palette/safe — embedded CVD-safe reference palettes reproduced as EMBEDDED
# DATA (no generation): Okabe-Ito (8-color qualitative, CVD-safe by design),
# viridis (sequential, perceptually uniform + CVD-safe), and a ColorBrewer safe
# set (Set1, qualitative). All public domain.
#
# viridis: the canonical viridis is a 256-row sRGB lookup table (matplotlib).
# This ships viridis from the 5 canonical legend landmarks (#440154 / #3B528B /
# #21918C / #5EC962 / #FDE725) interpolated in OKLab — the ENDPOINTS match
# exactly and L stays monotone, but intermediate stops are an APPROXIMATION, not
# bit-exact viridis. The API is stable; the full 256-table can drop in later
# without breaking callers. Okabe-Ito and ColorBrewer Set1 ARE bit-exact (hex
# known).
import UniColor/core/core
import UniColor/interpolation/interpolation # gradient, ColorStop, GradientOpts.
import UniColor/palette/types

proc srgb(r, g, b: float64): Color {.raises: [].} =
  color(tagSrgb, r.float32, g.float32, b.float32).get

# Okabe-Ito 8 (sRGB, public — Okabe & Ito, CVD-safe qualitative reference).
const okabeItoData = [
  (0.9020, 0.6235, 0.0),    # #E69F00 orange
  (0.3373, 0.7059, 0.9137), # #56B4E9 sky blue
  (0.0, 0.6196, 0.4510),    # #009E73 bluish green
  (0.9412, 0.8941, 0.2588), # #F0E442 yellow
  (0.0, 0.4471, 0.6980),    # #0072B2 blue
  (0.8353, 0.3686, 0.0),    # #D55E00 vermillion
  (0.8, 0.4745, 0.6549),    # #CC79A7 reddish purple
  (0.0, 0.0, 0.0)           # #000000 black
]

proc okabeIto*(): Palette {.raises: [].} =
  ## The 8-color Okabe-Ito qualitative palette — CVD-safe by design, bit-exact
  ## sRGB. `palUnordered` / `intentQualitative` / seed 0.
  var cs: seq[Color] = @[]
  for c in okabeItoData:
    cs.add(srgb(c[0], c[1], c[2]))
  palette(palUnordered, cs, intentQualitative, 0).get

# viridis 5 canonical landmarks (sRGB, public — viridis legend). Interpolated
# in OKLab for a smooth perceptually-uniform ramp; endpoints are exact,
# intermediate stops are an approximation (see note above).
const viridisLandmarks = [
  (0.2667, 0.0039, 0.3294, 0.0),  # #440154 (t=0)
  (0.2314, 0.3216, 0.5451, 0.25), # #3B528B
  (0.1294, 0.5686, 0.5490, 0.5),  # #21918C
  (0.3686, 0.7882, 0.3843, 0.75), # #5EC962
  (0.9922, 0.9059, 0.1451, 1.0)   # #FDE725 (t=1)
]

proc viridis*(n: int): Result[Palette, ColorError] {.raises: [].} =
  ## A `n`-color viridis ramp — sequential, perceptually uniform, CVD-safe. Built
  ## by OKLab interpolation of the 5 canonical viridis landmarks, gamut-mapped to
  ## sRGB. `palScientific` / `intentScientific` / seed 0. `n < 1` -> `InvalidOp`.
  ## Endpoints match #440154 / #FDE725 exactly; intermediate stops are a landmark
  ## approximation (not bit-exact).
  if n < 1:
    return err[Palette, ColorError](colorError(InvalidOp, "viridis: n < 1",
        "viridis"))
  var stops: seq[ColorStop] = @[]
  for lm in viridisLandmarks:
    stops.add(ColorStop(color: srgb(lm[0], lm[1], lm[2]), pos: lm[3].float32))
  let opts = GradientOpts(space: tagOklab, gamutMap: true, target: tagSrgb)
  var cs: seq[Color] = @[]
  for i in 0 ..< n:
    let t = if n == 1: 0.0'f32 else: float32(i) / float32(n - 1)
    let gR = gradient(stops, t, opts)
    if gR.isErr:
      return err[Palette, ColorError](gR.error)
    cs.add(gR.get)
  palette(palScientific, cs, intentScientific, 0)

# ColorBrewer Set1 9 (qualitative, public domain — Brewer). Subset returned for
# n in [1, 9].
const set1Data = [
  (0.8941, 0.1019, 0.1098), # #E41A1C
  (0.2157, 0.4941, 0.7216), # #377EB8
  (0.3020, 0.6863, 0.2902), # #4DAF4A
  (0.5961, 0.3059, 0.6392), # #984EA3
  (1.0, 0.4980, 0.0),       # #FF7F00
  (1.0, 1.0, 0.2),          # #FFFF33
  (0.6510, 0.3373, 0.1569), # #A65628
  (0.9686, 0.5059, 0.7490), # #F781BF
  (0.6, 0.6, 0.6)           # #999999
]
const set1Max = 9

proc colorBrewer*(name: string, n: int): Result[Palette, ColorError] {.
    raises: [].} =
  ## A named ColorBrewer reference palette. Currently supported: "Set1"
  ## (qualitative, max 9 — returns the first `n` colors). `n` out of range or
  ## unknown name -> `InvalidOp`. Bit-exact sRGB. A single safe set here; the
  ## full catalog + registry lands with the accessibility layer.
  if n < 1:
    return err[Palette, ColorError](colorError(InvalidOp,
        "colorBrewer: n < 1", "colorBrewer"))
  if name == "Set1":
    if n > set1Max:
      return err[Palette, ColorError](colorError(InvalidOp,
          "colorBrewer: Set1 max is " & $set1Max & ", got " & $n,
          "colorBrewer"))
    var cs: seq[Color] = @[]
    for i in 0 ..< n:
      cs.add(srgb(set1Data[i][0], set1Data[i][1], set1Data[i][2]))
    return palette(palUnordered, cs, intentQualitative, 0)
  err[Palette, ColorError](colorError(InvalidOp, "colorBrewer: unknown name '" &
      name & "'", "colorBrewer"))
