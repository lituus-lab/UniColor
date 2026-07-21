# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/options
import std/unittest
import UniColor

proc near(a, b: float64; tol = 1e-9): bool = abs(a - b) <= tol

suite "spaces — registration":
  test "all built-in spaces registered":
    check spacesCount() == 26
  test "lookup by name resolves tag, family, transfer, whitepoint":
    let d = lookupSpace("srgb").get
    check d.tag == tagSrgb
    check d.family == famRgbEncoded
    check d.transferKind == tkSrgb
    check d.whitepoint == wpD65
    check d.redeemable
    check d.rangeKind == rkStrict
  test "lookup by tag resolves name":
    check spaceByTag(tagOklch).get.name == "oklch"
    check spaceByTag(tagXyz).get.name == "xyz"
  test "absent name and unknown tag return none":
    check lookupSpace("nope").isNone
    check spaceByTag(tagUnknown).isNone
  test "registration is idempotent (no overwrite)":
    check registerSpace(srgbDescriptor()) == false
  test "spaceByTag is raises-free for an unregistered user tag":
    check spaceByTag(TAG_USER_BASE).isNone
  test "registry is sealed after UniColor import (no new registration)":
    let d = makeAnalyticDescriptor("test-only-sealed", SpaceTag(1001), famXyz,
        ["x", "y", "z"], [0.0, 0.0, 0.0], [1.0, 1.0, 1.0], rkStrict, wpD65,
        true)
    check registerSpace(d) == false
    check lookupSpace("test-only-sealed").isNone

suite "spaces — RGB family":
  test "fromXYZ is the inverse of toXYZ":
    let d = srgbDescriptor()
    let p = mul3(d.toXYZ, d.fromXYZ)
    for i in 0 ..< 3:
      for j in 0 ..< 3:
        check near(p[i][j], if i == j: 1.0 else: 0.0)
  test "linear variant shares primaries, drops transfer, goes natural":
    let enc = p3Descriptor()
    let lin = p3LinearDescriptor()
    check enc.toXYZ == lin.toXYZ
    check enc.transferKind == tkSrgb
    check lin.transferKind == tkNone
    check lin.rangeKind == rkNatural
  test "a98 carries gamma 2.2":
    let d = a98Descriptor()
    check d.transferKind == tkGamma
    check near(d.gamma, 2.2)
  test "rec2020 carries the BT.2020 transfer (not sRGB)":
    let d = rec2020Descriptor()
    check d.transferKind == tkRec2020
  test "prophoto is D50, 1.8 piecewise":
    let d = proPhotoDescriptor()
    check d.whitepoint == wpD50
    check d.transferKind == tkProPhoto

suite "spaces — analytic families":
  test "lab is D50, rectangular achromatic":
    let d = labDescriptor()
    check d.whitepoint == wpD50
    check d.achromaticKind == achRectAB
  test "oklch is polar achromatic, D65":
    let d = oklchDescriptor()
    check d.achromaticKind == achPolarChroma
    check d.whitepoint == wpD65
  test "cmyk has 4 chromatic channels and is non-redeemable":
    let d = cmykDescriptor()
    check d.chromaticCount == 4
    check not d.redeemable
  test "hct is non-redeemable (iterative solver)":
    check not hctDescriptor().redeemable
  test "ictcp carries tkPq":
    check ictcpDescriptor().transferKind == tkPq
  test "oklab exposes the Ottosson matrices":
    check oklabLms.len == 3
    check oklabM.len == 3

suite "spaces — isAchromatic":
  test "lab a=b=0 is achromatic":
    let c = color(tagLab, 50.0'f32, 0.0'f32, 0.0'f32).get
    check isAchromatic(c)
  test "lab a=50 is chromatic":
    let c = color(tagLab, 50.0'f32, 50.0'f32, 10.0'f32).get
    check not isAchromatic(c)
  test "oklch C=0 is achromatic (hue irrelevant)":
    let c = color(tagOklch, 0.5'f32, 0.0'f32, 200.0'f32).get
    check isAchromatic(c)
  test "srgb has no predicate (always false here)":
    let c = color(tagSrgb, 0.5'f32, 0.5'f32, 0.5'f32).get
    check not isAchromatic(c)
