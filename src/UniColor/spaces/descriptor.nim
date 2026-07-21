# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# descriptor — SpaceDescriptor: data-driven description of a color space.
# DATA only (no conversion logic -> module `conversion`). Each descriptor
# carries the identity, arity, ranges, whitepoint, transfer, primaries
# toXYZ/fromXYZ matrices (RGB family) and redeemability. The achromatic
# predicate selects how `isAchromatic` tests a color in this space.

import std/math
import UniColor/core/space_tag
import UniColor/core/result
import UniColor/math/matrices
import UniColor/math/whitepoint

type
  SpaceFamily* {.pure.} = enum
    ## Conversion family (tells module `conversion` which analytical path to apply).
    famRgbEncoded # sRGB/P3/Rec2020/A98/ProPhoto: encoded -> linear -> XYZ (matrix)
    famRgbLinear # linear-RGB: matrix -> XYZ (no transfer)
    famXyz       # hub: toXYZ = identity
    famXyy       # xyY: analytical conversion (chromaticity + Y)
    famLab       # CIELAB: analytical (epsilon 6/29)
    famLch       # CIELCH: polar over Lab
    famOklab     # OKLab: analytical (signed cbrt, Ottosson)
    famOklch     # OKLCH: polar over OKLab (perceptual hub)
    famHsv       # RGB derivative (cylindrical)
    famHsl
    famHwb
    famCmyk      # 4-chrom, info loss (-> ColorX)
    famYcbcr     # info loss
    famIctcp     # HDR PQ BT.2100
    famJzazbz    # HDR
    famCam16     # appearance
    famCam16Ucs  # CAM16-UCS: rectangular variant J'a'b' (deltaE_CAM16-UCS)
    famHct       # Material bonus (iterative)

  TransferKind* {.pure.} = enum
    ## Transfer reference (the function itself lives in math/transfer).
    tkNone     # linear / identity (linear-RGB, XYZ, Lab, OKLab, ...)
    tkSrgb     # IEC 61966-2-1 piecewise 2.4
    tkGamma    # simple gamma (A98 = 2.2; param `gamma`)
    tkProPhoto # 1.8 piecewise (ISO 22028-2)
    tkRec2020  # BT.2020 OETF (4.5 linear / 0.45 power, ITU-R BT.2020-2)
    tkPq       # BT.2100 PQ / ST 2084
    tkHlg      # BT.2100 HLG

  RangeKind* {.pure.} = enum
    rkStrict  # encoded bounded (e.g. sRGB [0,1]); out-of-gamut allowed but documented bounded
    rkNatural # unbounded (XYZ, OKLab, linear-RGB); out-of-gamut preserved

  AchromaticKind* {.pure.} = enum
    ## Selects how `isAchromatic` tests a color. An enum (not a proc field) keeps
    ## the descriptor a POD object and lets `isAchromatic` stay raises-free.
    achNone # no predicate (RGB: needs equal channels, handled in conversion)
    achPolarChroma # polar space: chroma (component 1) ~ 0 (LCH, OKLCH, HCT)
    achRectAB # rectangular space: a,b (components 1,2) ~ 0 (Lab, OKLab)

  SpaceDescriptor* = object
    ## Data-driven descriptor of a space. Immutability via init-once / read-only
    ## registration: we register, we do not modify.
    name*: string # canonical name (e.g. "srgb", "oklch")
    tag*: SpaceTag
    family*: SpaceFamily
    chromaticCount*: int # 3 (most) or 4 (CMYK)
    compNames*: array[4, string] # names of the chromatic components
    compMin*: array[4, float64] # canonical lower bound (-Inf if natural)
    compMax*: array[4, float64] # canonical upper bound (+Inf if natural)
    rangeKind*: RangeKind
    whitepoint*: Whitepoint
    transferKind*: TransferKind
    gamma*: float64 # gamma parameter (tkGamma; 0.0 otherwise)
    toXYZ*: Mat3 # primaries -> XYZ matrix (RGB family); identity for XYZ
    fromXYZ*: Mat3 # precomputed inverse (round-trip stable)
    redeemable*: bool # round-trip guaranteed (false for CMYK/YCbCr/terminals)
    achromaticKind*: AchromaticKind # how isAchromatic tests this space (default achNone)

func makeRgbDescriptor*(name: string, tag: SpaceTag, family: SpaceFamily,
                       whitepoint: Whitepoint, transferKind: TransferKind,
                       gamma: float64, toXYZ: Mat3, redeemable: bool,
                       compNames: array[3, string] = ["r", "g",
                           "b"]): SpaceDescriptor =
  ## RGB descriptor (encoded or linear). Bounds channels to [0,1] when encoded
  ## (strict), leaves them unbounded when linear. Precomputes fromXYZ as the
  ## inverse of toXYZ.
  let isEncoded = family == famRgbEncoded
  result = SpaceDescriptor(
    name: name,
    tag: tag,
    family: family,
    chromaticCount: 3,
    compNames: [compNames[0], compNames[1], compNames[2], ""],
    transferKind: transferKind,
    gamma: gamma,
    toXYZ: toXYZ,
    fromXYZ: inverse3(toXYZ).expect("RGB primaries matrix must be invertible"),
    whitepoint: whitepoint,
    redeemable: redeemable)
  let lo = if isEncoded: 0.0 else: NegInf
  let hi = if isEncoded: 1.0 else: Inf
  for i in 0 ..< 3:
    result.compMin[i] = lo
    result.compMax[i] = hi
  result.rangeKind = if isEncoded: rkStrict else: rkNatural

func makeAnalyticDescriptor*(name: string, tag: SpaceTag, family: SpaceFamily,
                            compNames: array[3, string], compMin,
                                compMax: array[3, float64],
                            rangeKind: RangeKind, whitepoint: Whitepoint,
                            redeemable: bool,
                            achromaticKind: AchromaticKind = achNone,
                            transferKind: TransferKind = tkNone,
                            gamma: float64 = 0.0): SpaceDescriptor =
  ## Analytic descriptor (XYZ, xyY, Lab, OKLab, ...). No primaries matrix:
  ## toXYZ/fromXYZ stay identity and the conversion module dispatches on
  ## `family` for the real transform. `transferKind` defaults to tkNone (most
  ## analytic spaces); ICtCp passes tkPq.
  result = SpaceDescriptor(
    name: name,
    tag: tag,
    family: family,
    chromaticCount: 3,
    compNames: [compNames[0], compNames[1], compNames[2], ""],
    whitepoint: whitepoint,
    transferKind: transferKind,
    gamma: gamma,
    toXYZ: identity3(),
    fromXYZ: identity3(),
    redeemable: redeemable,
    achromaticKind: achromaticKind)
  for i in 0 ..< 3:
    result.compMin[i] = compMin[i]
    result.compMax[i] = compMax[i]
  result.rangeKind = rangeKind

func makeAnalyticDescriptor*(name: string, tag: SpaceTag, family: SpaceFamily,
                            compNames: array[4, string], compMin,
                                compMax: array[4, float64],
                            rangeKind: RangeKind, whitepoint: Whitepoint,
                            redeemable: bool,
                            achromaticKind: AchromaticKind = achNone,
                            transferKind: TransferKind = tkNone,
                            gamma: float64 = 0.0): SpaceDescriptor =
  ## 4-chromatic analytic descriptor (CMYK). Same as the 3-chromatic variant but
  ## with chromaticCount=4 and four named/bounded channels. No primaries matrix;
  ## conversion dispatches on `family`.
  result = SpaceDescriptor(
    name: name,
    tag: tag,
    family: family,
    chromaticCount: 4,
    compNames: compNames,
    whitepoint: whitepoint,
    transferKind: transferKind,
    gamma: gamma,
    toXYZ: identity3(),
    fromXYZ: identity3(),
    redeemable: redeemable,
    achromaticKind: achromaticKind)
  for i in 0 ..< 4:
    result.compMin[i] = compMin[i]
    result.compMax[i] = compMax[i]
  result.rangeKind = rangeKind
