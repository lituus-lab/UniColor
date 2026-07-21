# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# apca — APCA / SAPC perceptual contrast (Myndex apca-w3 0.0.98G).
# Authoritative source: Myndex apca-w3 `src/apca-w3.js` (0.0.98G, verbatim).
# Opt-in "experimental" (APCA withdrawn from the WCAG3 draft, "TBD").
#
# `apcaContrast(text, bg)` — signed Lc. Converts both operands to sRGB-encoded
# D65 via the hub, linearizes with the APCA power-2.4 luminance (the SIMPLE
# power law `(c)^2.4`, NOT the piecewise sRGB EOTF — APCA's own "estimate
# screen luminance"), then runs the SAPC core. Returns the hub error if a space
# is unregistered.
# SIGN CONVENTION (apca-w3 0.0.98G, authoritative): dark text on a light
# background (BoW, normal polarity, bgY > txtY) -> POSITIVE Lc (~+106 for
# #000/#fff). Light text on a dark background (WoB, reverse polarity) ->
# NEGATIVE Lc (~-108 for #fff/#000).
# Thresholds: fine 90, normal 75, large 60, non-text 60, symbols 50.
# `ApcaExperimental = true` (opt-in, not the default metric).
# Constants frozen verbatim from apca-w3 SA98G (version-pinned — Lc can shift
# between releases). float64 throughout.
import std/math
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/conversion/conversion

# apca-w3 0.0.98G SA98G constants (verbatim, version-pinned).
const MainTRC* = 2.4
const SRco* = 0.2126729
const SGco* = 0.7151522
const SBco* = 0.0721750
const NormBG* = 0.56
const NormTXT* = 0.57
const RevTXT* = 0.62
const RevBG* = 0.65
const BlkThrs* = 0.022
const BlkClmp* = 1.414
const ScaleBoW* = 1.14
const ScaleWoB* = 1.14
const LoBoWoffset* = 0.027
const LoWoBoffset* = 0.027
const DeltaYmin* = 0.0005
const LoClip* = 0.1
const IcpLo* = 0.0
const IcpHi* = 1.1

# APCA thresholds (|Lc|).
const ApcaFine* = 90.0
const ApcaNormal* = 75.0
const ApcaLarge* = 60.0
const ApcaNonText* = 60.0
const ApcaSymbols* = 50.0
const ApcaExperimental* = true # opt-in, not the default.

proc srgbApcaLuminance(c: Color): Result[float64, ColorError] {.raises: [].} =
  ## APCA luminance estimate of `c`: convert to sRGB-encoded D65 via the hub,
  ## then the simple power-2.4 luminance
  ## `Y = 0.2126729·R^2.4 + 0.7151522·G^2.4 + 0.0721750·B^2.4` (NOT the
  ## piecewise sRGB EOTF — APCA's own estimate, apca-w3 `simpleExp`).
  ## Out-of-gamut/negative channels yield NaN, which the SAPC core precheck
  ## turns into Lc 0 (faithful to the reference).
  let srgbR = c.to(tagSrgb)
  if srgbR.isErr:
    return err[float64, ColorError](srgbR.error)
  let srgb = srgbR.get
  let r = srgb.comp(0).float64
  let g = srgb.comp(1).float64
  let b = srgb.comp(2).float64
  ok[float64, ColorError](SRco * pow(r, MainTRC) + SGco * pow(g, MainTRC) +
      SBco * pow(b, MainTRC))

func apcaCore(txtY, bgY: float64): float64 {.raises: [].} =
  ## SAPC core (apca-w3 0.0.98G `APCAcontrast`, verbatim): icp precheck (NaN /
  ## out-of-[0,1.1] -> 0), soft-clip near black, deltaYmin cutoff, polarity
  ## exponents, scale, offset, loClip. Pure (no conversion). SIGN: BoW
  ## (bgY>txtY, dark text/light bg) -> positive; WoB -> negative.
  if isNaN(txtY) or isNaN(bgY):
    return 0.0
  let lo = if txtY < bgY: txtY else: bgY
  let hi = if txtY < bgY: bgY else: txtY
  if lo < IcpLo or hi > IcpHi:
    return 0.0
  # Soft-clip near black (apca-w3): below BlkThrs, add (BlkThrs - Y)^BlkClmp.
  var tY = if txtY > BlkThrs: txtY else: txtY + pow(BlkThrs - txtY, BlkClmp)
  var bY = if bgY > BlkThrs: bgY else: bgY + pow(BlkThrs - bgY, BlkClmp)
  if abs(bY - tY) < DeltaYmin:
    return 0.0
  var output: float64
  if bY > tY: # normal polarity BoW (dark text / light bg) -> positive.
    let sapc = (pow(bY, NormBG) - pow(tY, NormTXT)) * ScaleBoW
    output = if sapc < LoClip: 0.0 else: sapc - LoBoWoffset
  else: # reverse polarity WoB (light text / dark bg) -> negative.
    let sapc = (pow(bY, RevBG) - pow(tY, RevTXT)) * ScaleWoB
    output = if sapc > -LoClip: 0.0 else: sapc + LoWoBoffset
  output * 100.0

proc apcaContrast*(text, bg: Color): Result[float64, ColorError] {.raises: [].} =
  ## APCA 0.0.98G perceptual contrast Lc of `text` against `bg`. Signed:
  ## positive = dark text on light bg, negative = light text on dark bg.
  ## Converts both to sRGB-encoded D65 via the hub (any registered source
  ## space), then the SAPC core. Opt-in experimental (`ApcaExperimental`).
  ## Propagates a hub error from either operand.
  let ytR = srgbApcaLuminance(text)
  if ytR.isErr:
    return err[float64, ColorError](ytR.error)
  let ybR = srgbApcaLuminance(bg)
  if ybR.isErr:
    return err[float64, ColorError](ybR.error)
  ok[float64, ColorError](apcaCore(ytR.get, ybR.get))
