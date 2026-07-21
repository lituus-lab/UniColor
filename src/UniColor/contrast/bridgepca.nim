# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# bridgepca — BridgePCA (Myndex bridge-pca 0.1.6 4g-W3, BSD-3; see NOTICE).
# `bpcaContrast(text, bg)` returns a signed Lc: operands are converted to
# sRGB-encoded D65 via the hub, linearized with the BridgePCA power-2.4
# luminance (derived sRGB coefficients, not APCA's), then the BPCA core. WoB
# (reverse polarity) adds a `bridge` term that pulls light-text/dark-bg Lc
# toward WCAG 2; the BoW branch is the APCA core unchanged. Sign convention:
# BoW -> positive, WoB -> negative (same as APCA). `bridgeRatio(lc, text, bg)`
# returns the WCAG-aligned numeric ratio (a number, not a formatted string).
# Constants frozen verbatim from bridge-pca 0.1.6 (version-pinned). float64.
import std/math
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/conversion/conversion

# bridge-pca 0.1.6 4g-W3 constants (verbatim, version-pinned). NOTE: the sRGB
# coefficients here are the "future" derived primaries (0.2126478...), distinct
# from APCA's (0.2126729...).
const MainTRC* = 2.4
const SRco* = 0.2126478133913640
const SGco* = 0.7151791475336150
const SBco* = 0.0721730390750208
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
const BridgeWoBfact* = 0.1414 # bridge term factor (WoB only).
const BridgeWoBpivot* = 0.84 # bridge term pivot: bridge = max(0, txtY/pivot - 1)*factor.
const DeltaYmin* = 0.0005
const LoClip* = 0.1
const IcpLo* = 0.0
const IcpHi* = 1.1

# bridgeRatio constants (bridge-pca `bridgeRatio`, Jan 16 2022 set).
const OffsetA* = 0.2693
const PreScale* = -0.0561
const PowerShift* = 4.537
const MainFactor* = 1.113946
const LoThresh* = 0.3
const LoExp* = 0.48
const PreEmph* = 0.42
const PostDe* = 0.6594
const HiTrim* = 0.0785
const LoTrim* = 0.0815
const TrimThresh* = 0.506 # #c0c0c0: above this, the trim tapers with maxY.

# BridgePCA thresholds (|Lc|). Same nominal values as APCA (idealized Lc <-> WCAG).
const BpcaFine* = 90.0
const BpcaNormal* = 75.0
const BpcaLarge* = 60.0
const BpcaNonText* = 60.0
const BpcaSymbols* = 50.0
const BpcaExperimental* = true # opt-in alternative, not the default.

proc bpcaLuminance(c: Color): Result[float64, ColorError] {.raises: [].} =
  ## BridgePCA luminance of `c`: convert to sRGB-encoded D65 via the hub, then
  ## the simple power-2.4 luminance
  ## `Y = 0.2126478·R^2.4 + 0.7151791·G^2.4 + 0.0721730·B^2.4` (bridge-pca
  ## `simpleExp`, the "future" coefficients). Out-of-gamut/negative channels
  ## yield NaN, which the BPCA core precheck turns into Lc 0 (faithful to the
  ## reference).
  let srgbR = c.to(tagSrgb)
  if srgbR.isErr:
    return err[float64, ColorError](srgbR.error)
  let srgb = srgbR.get
  let r = srgb.comp(0).float64
  let g = srgb.comp(1).float64
  let b = srgb.comp(2).float64
  ok[float64, ColorError](SRco * pow(r, MainTRC) + SGco * pow(g, MainTRC) +
      SBco * pow(b, MainTRC))

func bpcaCore(txtY, bgY: float64): float64 {.raises: [].} =
  ## BPCA core (bridge-pca 0.1.6 `BPCAcontrast`, verbatim): icp precheck (NaN /
  ## out-of-[0,1.1] -> 0), soft-clip near black, deltaYmin cutoff, polarity
  ## exponents, scale, offset, loClip, PLUS the `bridge` term on the WoB branch
  ## (`max(0, txtY/0.84 - 1) * 0.1414`). Pure (no conversion). SIGN: BoW
  ## (bgY>txtY, dark text/light bg) -> positive; WoB -> negative (less so than
  ## APCA).
  if isNaN(txtY) or isNaN(bgY):
    return 0.0
  let lo = if txtY < bgY: txtY else: bgY
  let hi = if txtY < bgY: bgY else: txtY
  if lo < IcpLo or hi > IcpHi:
    return 0.0
  var tY = if txtY > BlkThrs: txtY else: txtY + pow(BlkThrs - txtY, BlkClmp)
  var bY = if bgY > BlkThrs: bgY else: bgY + pow(BlkThrs - bgY, BlkClmp)
  if abs(bY - tY) < DeltaYmin:
    return 0.0
  var output: float64
  if bY > tY: # normal polarity BoW (dark text / light bg) -> positive (identical to APCA core).
    let sapc = (pow(bY, NormBG) - pow(tY, NormTXT)) * ScaleBoW
    output = if sapc < LoClip: 0.0 else: sapc - LoBoWoffset
  else: # reverse polarity WoB (light text / dark bg) -> negative, with the bridge term added.
    let sapc = (pow(bY, RevBG) - pow(tY, RevTXT)) * ScaleWoB
    let bridge = max(0.0, tY / BridgeWoBpivot - 1.0) * BridgeWoBfact
    output = if sapc > -LoClip: 0.0 else: sapc + LoWoBoffset + bridge
  output * 100.0

proc bpcaContrast*(text, bg: Color): Result[float64, ColorError] {.raises: [].} =
  ## BridgePCA 0.1.6 perceptual contrast Lc of `text` against `bg`. Signed: BoW
  ## positive, WoB negative (less negative than APCA — the `bridge` term aligns
  ## WoB with WCAG 2). Converts both to sRGB-encoded D65 via the hub (any
  ## registered source space), then the BPCA core. Opt-in experimental
  ## (`BpcaExperimental`). Propagates a hub error from either operand.
  let ytR = bpcaLuminance(text)
  if ytR.isErr:
    return err[float64, ColorError](ytR.error)
  let ybR = bpcaLuminance(bg)
  if ybR.isErr:
    return err[float64, ColorError](ybR.error)
  ok[float64, ColorError](bpcaCore(ytR.get, ybR.get))

func bridgeRatioRaw(lc: float64, txtY, bgY: float64): float64 {.raises: [].} =
  ## bridge-pca `bridgeRatio` core, returning the numeric WCAG-aligned ratio
  ## (BEFORE the reference's `.toFixed(places) + " to 1"` string formatting).
  ## The maxY-based trim tapers addTrim above the #c0c0c0 luminance pivot. See
  ## bridge-pca src/bridge-pca.js `bridgeRatio`.
  if isNaN(lc) or isNaN(txtY) or isNaN(bgY):
    return 0.0
  let maxY = max(txtY, bgY)
  var addTrim = LoTrim + HiTrim
  if maxY > TrimThresh:
    let adjFact = (1.0 - maxY) / (1.0 - TrimThresh)
    addTrim = LoTrim * adjFact + HiTrim
  let c = max(0.0, abs(lc * 0.01))
  var wcagContrast = (pow(c + PreScale, PowerShift) + OffsetA) * MainFactor *
      c + addTrim
  if wcagContrast > LoThresh:
    wcagContrast = 10.0 * wcagContrast
  elif c < 0.06:
    wcagContrast = 0.0
  else:
    wcagContrast = 10.0 * wcagContrast - (pow(LoThresh - wcagContrast + PreEmph,
        LoExp) - PostDe)
  wcagContrast

proc bridgeRatio*(lc: float64, text, bg: Color): Result[float64,
    ColorError] {.raises: [].} =
  ## WCAG-aligned numeric ratio derived from a BridgePCA `lc` and the two colors
  ## ("recalculated to align WCAG"). The maxY-based trim needs the text/bg
  ## luminances, hence the colors. Returns the numeric ratio (NOT the
  ## reference's "x to 1" string). Propagates a hub error from either operand.
  ## Pass the Lc returned by `bpcaContrast` for the same pair.
  let ytR = bpcaLuminance(text)
  if ytR.isErr:
    return err[float64, ColorError](ytR.error)
  let ybR = bpcaLuminance(bg)
  if ybR.isErr:
    return err[float64, ColorError](ybR.error)
  ok[float64, ColorError](bridgeRatioRaw(lc, ytR.get, ybR.get))
