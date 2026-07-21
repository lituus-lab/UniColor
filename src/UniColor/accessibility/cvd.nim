# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# cvd — color vision deficiency simulation + confusability report.
# Machado 2009 (the default): severity-1.0 dichromat matrices (Machado,
# Oliveira & Fernandes, IEEE TVCG 15(6), 2009; supplementary at
# https://www.inf.ufrgs.br/~oliveira/pubs_files/CVD_Simulation/). Applied in
# LINEAR sRGB; severity in [0,1] interpolates M(s) = (1-s)·I + s·M_dichromat.
# Out-of-gamut channels are preserved (no clamp). Achromatopsia is a Rec.709
# luma collapse (Y,Y,Y), not a Machado matrix; interpolated by severity the
# same way (rod-monochromacy is not a dichromacy). Models are registered
# descriptors — Brettel 1997 / Vienot 1999 register later without touching the
# core. All procs pure: no Color mutation, deterministic, no side effects.
import std/options
import std/tables
import std/math # `Inf` — failed-distance sentinel in `cvdReport`.
import UniColor/core/core
import UniColor/conversion/conversion # `to` (sRGB<->linear short-path is exact).
import UniColor/contrast/contrast # `distance(a, b, "deltaE_ok")`.

type
  CvdType* = enum
    cvdProtanopia
    cvdDeuteranopia
    cvdTritanopia
    cvdAchromatopsia

  CvdModel* = object
    ## Descriptor for a CVD simulation model (data-driven like the metric
    ## registries). `simulate` converts to linear sRGB, applies the model's
    ## transform, and returns sRGB.
    name*: string
    simulate*: proc(c: Color, t: CvdType, severity: float64): Result[Color,
        ColorError] {.raises: [].}

  CvdConfusablePair* = object
    ## Two palette colors (by index into `simulated`) that collapse to within
    ## `threshold` ΔE_OK under the simulated CVD — confusable for that
    ## deficiency.
    i*, j*: int
    deltaE*: float64

  CvdReport* = object
    model*: string
    cvdType*: CvdType
    severity*: float64
    threshold*: float64
    pairs*: seq[CvdConfusablePair] # confusable pairs (ΔE_OK < threshold).
    maxDeltaE*: float64            # worst-case ΔE_OK over all pairs.
    simulated*: seq[Color]         # simulated colors, for inspection / audit.

const DefaultCvdModel* = "machado"

# Machado 2009 severity-1.0 dichromat matrices (published). Each row sums to
# 1.0 (white preserved). Out-of-gamut outputs (e.g. tritan on red -> R=1.2555)
# are preserved, not clamped.
const
  MachadoProtan: array[3, array[3, float64]] = [
    [0.152286, 1.052583, -0.204868],
    [0.114503, 0.786281, 0.099216],
    [-0.003882, -0.048116, 1.051998]
  ]
  MachadoDeuter: array[3, array[3, float64]] = [
    [0.367322, 0.860646, -0.227968],
    [0.280085, 0.672501, 0.047413],
    [-0.011820, 0.042940, 0.968881]
  ]
  MachadoTritan: array[3, array[3, float64]] = [
    [1.255528, -0.076749, -0.178779],
    [-0.078411, 0.930809, 0.147602],
    [0.004733, 0.691367, 0.303900]
  ]
  # Rec.709 luma weights for achromatopsia (luminance collapse).
  LumaR = 0.2126
  LumaG = 0.7152
  LumaB = 0.0722

# Registry — module-level table, idempotent registration, optional seal.
# Extensible for Brettel/Vienot without touching the core.
var
  cvdByName: Table[string, CvdModel]
  cvdSealed: bool

proc registerCvdModel*(m: CvdModel): bool {.raises: [].} =
  if cvdSealed or m.name.len == 0 or cvdByName.hasKey(m.name):
    return false
  cvdByName[m.name] = m
  true

proc lookupCvdModel*(name: string): Option[CvdModel] {.raises: [].} =
  if cvdByName.hasKey(name):
    some(cvdByName.getOrDefault(name))
  else:
    none(CvdModel)

proc cvdModelCount*(): int {.raises: [].} =
  cvdByName.len

proc sealCvdModels*() {.raises: [].} =
  cvdSealed = true

# Machado dichromat output: M_dich · (r, g, b) for the given type. Achromatopsia
# is handled separately (luminance collapse, not a 3×3 matrix) so it is NOT
# routed through here.
func machadoDichromat(t: CvdType, r, g, b: float64): tuple[r, g,
    b: float64] {.raises: [].} =
  let m = case t
    of cvdProtanopia: MachadoProtan
    of cvdDeuteranopia: MachadoDeuter
    of cvdTritanopia: MachadoTritan
    of cvdAchromatopsia: MachadoProtan # unused (achromatopsia branch below).
  (m[0][0] * r + m[0][1] * g + m[0][2] * b,
      m[1][0] * r + m[1][1] * g + m[1][2] * b,
      m[2][0] * r + m[2][1] * g + m[2][2] * b)

# Achromatopsia luminance collapse: Y = LumaR·R + LumaG·G + LumaB·B.
func achromatopsiaCollapse(r, g, b: float64): float64 {.raises: [].} =
  LumaR * r + LumaG * g + LumaB * b

proc machadoSimulate(c: Color, t: CvdType, severity: float64): Result[Color,
    ColorError] {.raises: [].} =
  if severity < 0.0 or severity > 1.0:
    return err[Color, ColorError](colorError(InvalidColor,
        "CVD severity must be in [0,1], got " & $severity, "machadoSimulate"))
  let linR = c.to(tagSrgbLin) # to linear sRGB (exact short-path from sRGB).
  if linR.isErr:
    return err[Color, ColorError](linR.error)
  let lin = linR.get
  let r = lin.comp(0).float64
  let g = lin.comp(1).float64
  let b = lin.comp(2).float64
  # M(s) = (1-s)·I + s·M_dich. Achromatopsia's "dichromat" target is the
  # luminance collapse (Y,Y,Y), not a 3×3 matrix — handled in its own branch.
  let (nr, ng, nb) = if t == cvdAchromatopsia:
    let y = achromatopsiaCollapse(r, g, b)
    ((1.0 - severity) * r + severity * y,
        (1.0 - severity) * g + severity * y,
        (1.0 - severity) * b + severity * y)
  else:
    let d = machadoDichromat(t, r, g, b)
    ((1.0 - severity) * r + severity * d.r,
        (1.0 - severity) * g + severity * d.g,
        (1.0 - severity) * b + severity * d.b)
  # Build the result in linear sRGB (out-of-gamut comps preserved by `color`,
  # no clamp) and round back to sRGB via the exact short-path. Alpha preserved.
  let outLinR = color(tagSrgbLin, nr.float32, ng.float32, nb.float32, c.alpha())
  if outLinR.isErr:
    return err[Color, ColorError](outLinR.error)
  outLinR.get.to(tagSrgb)

proc simulateCvd*(c: Color, model: string, t: CvdType,
    severity: float64): Result[Color, ColorError] {.raises: [].} =
  ## Dispatched CVD simulation: look up `model` and call its `simulate`.
  ## `UnknownCvdModel` if the model is absent, `InvalidColor` if severity is
  ## outside [0,1], or the hub conversion error otherwise. Deterministic, no
  ## input mutation.
  let m = lookupCvdModel(model)
  if m.isNone:
    return err[Color, ColorError](colorError(UnknownCvdModel,
        "unknown CVD model: " & model, "simulateCvd"))
  m.get.simulate(c, t, severity)

proc simulateCvd*(c: Color, t: CvdType, severity: float64): Result[Color,
    ColorError] {.raises: [].} =
  ## Convenience overload — the default model (Machado).
  simulateCvd(c, DefaultCvdModel, t, severity)

proc cvdReport*(colors: openArray[Color], model: string, t: CvdType,
    severity: float64, threshold: float64): CvdReport {.raises: [].} =
  ## Confusability report: simulate every color under the given CVD, then
  ## measure ΔE_OK between every pair of simulated colors. Pairs with ΔE_OK <
  ## `threshold` are confusable. `maxDeltaE` is the worst-case pair distance.
  ## `severity` is validated by `simulateCvd` (out-of-range -> the simulated
  ## slot is skipped from pairing; deterministic, no raise). Input is
  ## `openArray[Color]` (a palette's colors); a theme wrapper extracts colors.
  result = CvdReport(model: model, cvdType: t, severity: severity,
      threshold: threshold, pairs: @[], maxDeltaE: 0.0, simulated: @[])
  # Simulate each color; skip on simulation error so a bad input cannot crash
  # the whole report — `pairs` indices reference `simulated` positions, not
  # `colors` positions.
  var sim: seq[Color] = @[]
  for col in colors:
    let s = simulateCvd(col, model, t, severity)
    if s.isErr:
      continue
    sim.add(s.get)
  result.simulated = sim
  for i in 0 ..< sim.len:
    for j in (i + 1) ..< sim.len:
      let dR = distance(sim[i], sim[j], "deltaE_ok")
      let d = if dR.isErr: Inf else: dR.get
      if d > result.maxDeltaE:
        result.maxDeltaE = d
      if d < threshold:
        result.pairs.add(CvdConfusablePair(i: i, j: j, deltaE: d))

# Bootstrap — register Machado 2009 as the default (and, for now, only) CVD
# model. Brettel/Vienot register here in a follow-up lot.
discard registerCvdModel(CvdModel(name: "machado", simulate: machadoSimulate))
