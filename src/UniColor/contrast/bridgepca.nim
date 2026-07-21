# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# bridgepca — BridgePCA (Myndex bridge-pca 0.1.6 4g-W3).
# Authoritative source: Myndex bridge-pca `src/bridge-pca.js` (0.1.6, run via
# node to derive the golden vectors — the stale "EXPECTED RESULT" <pre> block
# in test.html is copied from the APCA vectors and predates the 0.1.6 `bridge`
# term; the reference run is the true anchor).
# Opt-in "experimental" (BridgePCA is an alternative, non-default metric).
#
# `bpcaContrast(text, bg)` — signed Lc. Converts both operands to sRGB-encoded
# D65 via the hub, linearizes with the BridgePCA power-2.4 luminance using the
# "future" derived sRGB coefficients (0.2126478/0.7151791/0.0721730 — NOT
# APCA's 0.2126729/0.7151522/0.0721750), then the BPCA core. Returns the hub
# error if a space is unregistered.
# DIFFERENCE FROM APCA: the WoB (reverse) branch adds a `bridge` term
# `max(0, txtY/0.84 - 1) * 0.1414`, pushing light-text/dark-bg Lc less negative
# toward WCAG 2 (backwards-compatible). The BoW (positive) branch is the APCA
# core unchanged. Active only when the text luminance exceeds the 0.84 pivot
# (else 0). Visible on #fff/#888: APCA = -68.541, BridgePCA = -65.848
# (+2.69 = the bridge term).
# SIGN CONVENTION (bridge-pca 0.1.6, authoritative): BoW (dark text/light bg,
# bgY>txtY) -> POSITIVE Lc; WoB (light text/dark bg) -> NEGATIVE Lc. Same as
# APCA.
# `bridgeRatio(lc, text, bg)` — the WCAG-aligned NUMERIC ratio derived from a
# BridgePCA Lc (bridge-pca `bridgeRatio`, BEFORE the reference's string
# formatting — the engine returns a number, not a "x to 1" string; formatting
# is a presentation concern). Takes the Lc + both colors (the maxY-based trim
# needs txtY/bgY).
# Thresholds (idealized Lc <-> WCAG mapping: 90~7:1, 75~4.5:1, 60~3:1): fine
# 90, normal 75, large 60, non-text 60, symbols 50. `BpcaExperimental = true`.
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
