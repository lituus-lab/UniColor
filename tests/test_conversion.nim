# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/math
import std/unittest
import UniColor

proc near(a, b: float64, tol = 1e-9): bool = abs(a - b) <= tol

test "conversion module compiles and is reachable":
  check conversionModule == "1.0.0"

# --- short-path: isShortPath predicate ----------------------------------------

suite "short-path: isShortPath predicate":
  test "exact pairs recognized (both directions)":
    check isShortPath(tagLab, tagLch)
    check isShortPath(tagLch, tagLab)
    check isShortPath(tagOklab, tagOklch)
    check isShortPath(tagOklch, tagOklab)
    check isShortPath(tagSrgb, tagSrgbLin)
    check isShortPath(tagSrgbLin, tagSrgb)
    check isShortPath(tagHsv, tagHsl)
    check isShortPath(tagHsl, tagHsv)
    check isShortPath(tagHsv, tagHwb)
    check isShortPath(tagHwb, tagHsv)
    check isShortPath(tagHsl, tagHwb)
    check isShortPath(tagHwb, tagHsl)
  test "non-pairs rejected (incl. same space)":
    check not isShortPath(tagSrgb, tagOklab)
    check not isShortPath(tagLab, tagOklch)
    check not isShortPath(tagSrgb, tagSrgb)
    check not isShortPath(tagHsv, tagLab)

# Hub 2-hop reference (the multi-bond path the short-path optimizes away).
proc hubBond(c: Color, target: SpaceTag): Color =
  fromXYZ(toXYZ(c).get, target).get

suite "short-path: Lab <-> LCH (polar, exact)":
  test "Lab(50, 60, 40) -> LCH (L, C=hypot, h=atan2)":
    let c = color(tagLab, 50.0'f32, 60.0'f32, 40.0'f32).get
    let r = to(c, tagLch).get
    check near(r.comp(0).float64, 50.0, 1e-4)
    check near(r.comp(1).float64, hypot(60.0, 40.0), 1e-3)
    check near(r.comp(2).float64, arctan2(40.0, 60.0) * 180.0 / PI, 1e-3)
  test "LCH -> Lab round-trips":
    let c = color(tagLch, 50.0'f32, float32(hypot(60.0, 40.0)),
                  float32(arctan2(40.0, 60.0) * 180.0 / PI)).get
    let back = to(c, tagLab).get
    check near(back.comp(0).float64, 50.0, 1e-4)
    check near(back.comp(1).float64, 60.0, 1e-3)
    check near(back.comp(2).float64, 40.0, 1e-3)
  test "short-path == hub multi-bond (TOL_ROUNDTRIP for the D50 CAT pair)":
    let c = color(tagLab, 50.0'f32, 40.0'f32, -30.0'f32).get
    let sp = to(c, tagLch).get
    let mb = hubBond(c, tagLch)
    check near(sp.comp(0).float64, mb.comp(0).float64, TOL_ROUNDTRIP)
    check near(sp.comp(1).float64, mb.comp(1).float64, TOL_ROUNDTRIP)
    check near(sp.comp(2).float64, mb.comp(2).float64, TOL_ROUNDTRIP)

suite "short-path: OKLab <-> OKLCH (polar, exact)":
  test "OKLab(0.5, 0.1, 0.05) -> OKLCH":
    let c = color(tagOklab, 0.5'f32, 0.1'f32, 0.05'f32).get
    let r = to(c, tagOklch).get
    check near(r.comp(0).float64, 0.5, 1e-5)
    check near(r.comp(1).float64, hypot(0.1, 0.05), 1e-4)
    check near(r.comp(2).float64, arctan2(0.05, 0.1) * 180.0 / PI, 1e-3)
  test "OKLCH -> OKLab round-trips":
    let c = color(tagOklch, 0.5'f32, float32(hypot(0.1, 0.05)),
                  float32(arctan2(0.05, 0.1) * 180.0 / PI)).get
    let back = to(c, tagOklab).get
    check near(back.comp(0).float64, 0.5, 1e-5)
    check near(back.comp(1).float64, 0.1, 1e-4)
    check near(back.comp(2).float64, 0.05, 1e-4)
  test "short-path == hub multi-bond (TOL_EQUAL)":
    let c = color(tagOklab, 0.6'f32, 0.08'f32, -0.05'f32).get
    let sp = to(c, tagOklch).get
    let mb = hubBond(c, tagOklch)
    check near(sp.comp(0).float64, mb.comp(0).float64, TOL_EQUAL)
    check near(sp.comp(1).float64, mb.comp(1).float64, TOL_EQUAL)
    check near(sp.comp(2).float64, mb.comp(2).float64, TOL_EQUAL)

suite "short-path: sRGB <-> sRGB-linear (EOTF/OETF only)":
  test "sRGB(0.5, 0.2, 0.8) -> sRGB-linear = srgbEotf per channel":
    let c = color(tagSrgb, 0.5'f32, 0.2'f32, 0.8'f32).get
    let r = to(c, tagSrgbLin).get
    check near(r.comp(0).float64, srgbEotf(0.5), 1e-5)
    check near(r.comp(1).float64, srgbEotf(0.2), 1e-5)
    check near(r.comp(2).float64, srgbEotf(0.8), 1e-5)
  test "sRGB-linear -> sRGB round-trips":
    let c = color(tagSrgbLin, float32(srgbEotf(0.5)), float32(srgbEotf(0.2)),
                  float32(srgbEotf(0.8))).get
    let back = to(c, tagSrgb).get
    check near(back.comp(0).float64, 0.5, 1e-4)
    check near(back.comp(1).float64, 0.2, 1e-4)
    check near(back.comp(2).float64, 0.8, 1e-4)

suite "short-path: HSV / HSL / HWB trio (sRGB-anchored)":
  test "HSV(120, 1, 1) green -> HSL(120, 1, 0.5)":
    let c = color(tagHsv, 120.0'f32, 1.0'f32, 1.0'f32).get
    let r = to(c, tagHsl).get
    check near(r.comp(0).float64, 120.0, 1e-4)
    check near(r.comp(1).float64, 1.0, 1e-4)
    check near(r.comp(2).float64, 0.5, 1e-4)
  test "HSV(120, 1, 1) green -> HWB(120, 0, 0)":
    let c = color(tagHsv, 120.0'f32, 1.0'f32, 1.0'f32).get
    let r = to(c, tagHwb).get
    check near(r.comp(0).float64, 120.0, 1e-4)
    check near(r.comp(1).float64, 0.0, 1e-4)
    check near(r.comp(2).float64, 0.0, 1e-4)
  test "HSV <-> HSL <-> HSV round-trips":
    let c = color(tagHsv, 200.0'f32, 0.7'f32, 0.8'f32).get
    let back = to(to(c, tagHsl).get, tagHsv).get
    check near(back.comp(0).float64, 200.0, 1e-4)
    check near(back.comp(1).float64, 0.7, 1e-4)
    check near(back.comp(2).float64, 0.8, 1e-4)
  test "HSV <-> HWB <-> HSV round-trips":
    let c = color(tagHsv, 200.0'f32, 0.7'f32, 0.8'f32).get
    let back = to(to(c, tagHwb).get, tagHsv).get
    check near(back.comp(0).float64, 200.0, 1e-4)
    check near(back.comp(1).float64, 0.7, 1e-4)
    check near(back.comp(2).float64, 0.8, 1e-4)
  test "HSL <-> HWB <-> HSL round-trips":
    let c = color(tagHsl, 30.0'f32, 0.6'f32, 0.55'f32).get
    let back = to(to(c, tagHwb).get, tagHsl).get
    check near(back.comp(0).float64, 30.0, 1e-4)
    check near(back.comp(1).float64, 0.6, 1e-4)
    check near(back.comp(2).float64, 0.55, 1e-4)
  test "HSV -> HSL short-path == hub multi-bond (TOL_EQUAL)":
    let c = color(tagHsv, 200.0'f32, 0.7'f32, 0.8'f32).get
    let sp = to(c, tagHsl).get
    let mb = hubBond(c, tagHsl)
    check near(sp.comp(0).float64, mb.comp(0).float64, TOL_EQUAL)
    check near(sp.comp(1).float64, mb.comp(1).float64, TOL_EQUAL)
    check near(sp.comp(2).float64, mb.comp(2).float64, TOL_EQUAL)
  test "red-max with g < b normalizes hue into [0,360) (no fmod leak)":
    # sRGB(1, 0, 0.5): red is max, g < b -> hue must be 330, not -30.
    let c = color(tagSrgb, 1.0'f32, 0.0'f32, 0.5'f32).get
    let h = to(c, tagHsv).get
    check near(h.comp(0).float64, 330.0, 1e-3)
    check h.comp(0).float64 >= 0.0 and h.comp(0).float64 < 360.0

suite "short-path: alpha preserved + dispatch":
  test "Lab(alpha=0.3) -> LCH keeps alpha=0.3":
    let c = color(tagLab, 50.0'f32, 60.0'f32, 40.0'f32, 0.3'f32).get
    let r = to(c, tagLch).get
    check near(r.alpha.float64, 0.3, 1e-6)
  test "HSV(alpha=0.4) -> HSL keeps alpha=0.4":
    let c = color(tagHsv, 120.0'f32, 1.0'f32, 1.0'f32, 0.4'f32).get
    let r = to(c, tagHsl).get
    check near(r.alpha.float64, 0.4, 1e-6)
  test "to(c, tagLch) dispatches to shortPath (structural equality)":
    let c = color(tagLab, 50.0'f32, 40.0'f32, -30.0'f32).get
    check to(c, tagLch).get == shortPath(c, tagLch).get

# --- round-trip all-pairs: A -> B -> A recovers source ------------------------
# Each hub bond is bounded by TOL_ROUNDTRIP, so the two-bond composition is
# bounded by 2x TOL_ROUNDTRIP. Samples are sRGB-gamut (the smallest common
# gamut): valid in every RGB space and in every perceptual/cylindrical space.
# Excludes CMYK (non-redeemable), YCbCr (spec-classified non-revertible), HCT
# (loose at JND scale — tracked separately below).

const reversible = [
  tagSrgb, tagSrgbLin, tagP3, tagP3Lin, tagRec2020, tagRec2020Lin, tagA98,
  tagA98Lin, tagProPhoto, tagProPhotoLin,
  tagXyz, tagXyy, tagLab, tagLch, tagOklab, tagOklch, tagHsv, tagHsl, tagHwb,
  tagIctcp, tagJzazbz, tagCam16, tagCam16Ucs
]

const srgbSamples = [[0.2'f32, 0.5'f32, 0.8'f32], [0.8'f32, 0.3'f32, 0.1'f32],
                     [0.1'f32, 0.7'f32, 0.3'f32]]

const tolAllPairs = 2.0 * TOL_ROUNDTRIP

suite "round-trip all-pairs: A -> B -> A recovers source":
  test "every reversible pair round-trips within 2x TOL_ROUNDTRIP":
    var worst = 0.0
    var nFail = 0
    for a in reversible:
      for b in reversible:
        if a == b:
          continue
        for si, s in srgbSamples:
          let label = spaceName(a) & "->" & spaceName(b) & " s=" & $si
          let cSrgb = color(tagSrgb, s[0], s[1], s[2]).get
          let cA = to(cSrgb, a).get
          let cB = to(cA, b)
          if cB.isErr:
            checkpoint(label & " A->B err " & $cB.error.kind)
            check false
            continue
          let back = to(cB.get, a)
          if back.isErr:
            checkpoint(label & " B->A err " & $back.error.kind)
            check false
            continue
          for k in 0 .. 2:
            let d = abs(back.get.comp(k).float64 - cA.comp(k).float64)
            if d > worst: worst = d
            if d >= tolAllPairs:
              inc nFail
              checkpoint(label & " comp=" & $k & " d=" & $d)
              check d < tolAllPairs
    check nFail == 0
    check worst < tolAllPairs

suite "round-trip: documented exclusions":
  test "CMYK is not wired -> InvalidOp":
    let c = color(tagSrgb, 0.5'f32, 0.5'f32, 0.5'f32).get
    check to(c, tagCmyk).error.kind == InvalidOp
  test "YCbCr is a lossless matrix here (smoke check, engine path invertible)":
    let c = color(tagSrgb, 0.2'f32, 0.5'f32, 0.8'f32).get
    let back = to(to(c, tagYcbcr).get, tagSrgb).get
    check near(back.comp(0).float64, 0.2, TOL_ROUNDTRIP)
    check near(back.comp(1).float64, 0.5, TOL_ROUNDTRIP)
    check near(back.comp(2).float64, 0.8, TOL_ROUNDTRIP)
  test "HCT round-trip is loose at JND scale (gamut-map + 8-bit quantize)":
    let c = color(tagHct, 285.0'f32, 40.0'f32, 60.0'f32).get
    let back = to(to(c, tagSrgb).get, tagHct).get
    check near(back.comp(0).float64, 285.0, 1.0) # H preserved
    check near(back.comp(2).float64, 60.0, 1.0) # T preserved
    check back.comp(1).float64 < 60.0 # C stays bounded; in-gamut source ->
                                                # no map, 8-bit quantize noise
                                                # can drift C above source

# --- gamut map: CSS Color 4 golden vectors (Color.js reference) --------------
# Golden sRGB output tolerance: same algorithm + same matrices as Color.js ->
# results match to ~1e-3. In-gamut/achromatic/edge cases are exact (~1e-7).
const tolGolden = 1e-3
const tolJnd = TOL_JND

type Gold = tuple[L, C, H: float32; srgb: array[3, float64]]

const golds: array[10, Gold] = [
  (L: 1.0'f32, C: 0.399'f32, H: 336.3'f32, srgb: [1.0, 1.0, 1.0]),
  (L: 0.0'f32, C: 0.399'f32, H: 336.3'f32, srgb: [0.0, 0.0, 0.0]),
  (L: 0.6'f32, C: 0.2'f32, H: 264.0'f32, srgb: [0.2503531, 0.4625214,
      0.9626733]),
  (L: 0.5'f32, C: 0.0'f32, H: 0.0'f32, srgb: [0.3885729, 0.3885729, 0.3885729]),
  (L: 0.7'f32, C: 0.3'f32, H: 30.0'f32, srgb: [1.0, 0.3451351, 0.2645751]),
  (L: 0.7'f32, C: 0.25'f32, H: 145.0'f32, srgb: [0.0, 0.7636864, 0.0415866]),
  (L: 0.8'f32, C: 0.32'f32, H: 0.0'f32, srgb: [1.0, 0.5713072, 0.7281196]),
  (L: 0.75'f32, C: 0.4'f32, H: 200.0'f32, srgb: [0.0, 0.7863885, 0.8247335]),
  (L: 0.62'f32, C: 0.28'f32, H: 130.0'f32, srgb: [0.3672563, 0.6059645, 0.0]),
  (L: 0.9'f32, C: 0.15'f32, H: 90.0'f32, srgb: [1.0, 0.8510862, 0.3518984])
]

suite "gamut map: CSS Color 4 golden vectors (sRGB target)":
  for g in golds:
    test "oklch(" & $g.L & " " & $g.C & " " & $g.H & ") -> sRGB matches Color.js":
      let c = color(tagOklch, g.L, g.C, g.H).get
      let r = gamutMap(c, tagSrgb).get
      check r.spaceTag == tagSrgb
      check near(r.comp(0).float64, g.srgb[0], tolGolden)
      check near(r.comp(1).float64, g.srgb[1], tolGolden)
      check near(r.comp(2).float64, g.srgb[2], tolGolden)

suite "gamut map: relative colorimetric + boundary":
  test "in-gamut color is returned unchanged (no chroma reduction)":
    let c = color(tagOklch, 0.6'f32, 0.2'f32, 264.0'f32).get
    let r = gamutMap(c, tagSrgb).get
    let back = to(r, tagOklch).get
    check near(back.comp(0).float64, 0.6, tolJnd)
    check near(back.comp(1).float64, 0.2, tolJnd)
    check near(back.comp(2).float64, 264.0, tolJnd)
  test "out-of-gamut reduces chroma, preserves L":
    let c = color(tagOklch, 0.8'f32, 0.32'f32, 0.0'f32).get
    let r = gamutMap(c, tagSrgb).get
    let back = to(r, tagOklch).get
    check near(back.comp(0).float64, 0.8, tolJnd)
    check back.comp(1).float64 < 0.32
    # Perpendicular distance to the source-hue ray (h=0 -> +a axis, b=0) <= JND.
    let rOkl = to(r, tagOklab).get
    let perp = abs(rOkl.comp(2).float64)
    check perp <= tolJnd
  test "L >= 100% maps to white in target":
    let c = color(tagOklch, 1.0'f32, 0.399'f32, 336.3'f32).get
    let r = gamutMap(c, tagSrgb).get
    check near(r.comp(0).float64, 1.0, tolGolden)
    check near(r.comp(1).float64, 1.0, tolGolden)
    check near(r.comp(2).float64, 1.0, tolGolden)
  test "L <= 0% maps to black in target":
    let c = color(tagOklch, 0.0'f32, 0.399'f32, 336.3'f32).get
    let r = gamutMap(c, tagSrgb).get
    check near(r.comp(0).float64, 0.0, tolGolden)
    check near(r.comp(1).float64, 0.0, tolGolden)
    check near(r.comp(2).float64, 0.0, tolGolden)
  test "unbounded target (XYZ) -> no mapping, returns the converted color":
    let c = color(tagOklch, 0.7'f32, 0.3'f32, 30.0'f32).get
    let gm = gamutMap(c, tagXyz).get
    let cv = to(c, tagXyz).get
    check near(gm.comp(0).float64, cv.comp(0).float64, tolGolden)
    check near(gm.comp(1).float64, cv.comp(1).float64, tolGolden)
    check near(gm.comp(2).float64, cv.comp(2).float64, tolGolden)
  test "alpha is preserved through gamut mapping":
    let c = color(tagOklch, 0.7'f32, 0.3'f32, 30.0'f32, 0.4'f32).get
    let r = gamutMap(c, tagSrgb).get
    check near(r.alpha.float64, 0.4, 1e-6)
  test "wide-gamut source (rec2020 red) maps into sRGB":
    let c = color(tagRec2020, 1.0'f32, 0.0'f32, 0.0'f32).get
    let r = gamutMap(c, tagSrgb).get
    check r.spaceTag == tagSrgb
    for k in 0 .. 2:
      check r.comp(k).float64 >= -tolGolden and r.comp(k).float64 <= 1.0 +
          tolGolden

# --- clamp: targeted per-channel clip -----------------------------------------

suite "clamp: targeted per-channel clip":
  test "out-of-gamut sRGB channel is clamped to [0,1]":
    let c = color(tagOklab, 0.7'f32, 0.3'f32, 0.0'f32).get # saturated, out of
 # sRGB gamut
    let r = clamp(c, tagSrgb).get
    check r.spaceTag == tagSrgb
    for k in 0 .. 2:
      check r.comp(k).float64 >= -1e-6 and r.comp(k).float64 <= 1.0 + 1e-6
  test "unbounded target (XYZ) -> clamp == to (no-op)":
    let c = color(tagSrgb, 0.2'f32, 0.5'f32, 0.8'f32).get
    let cl = clamp(c, tagXyz).get
    let cv = to(c, tagXyz).get
    check near(cl.comp(0).float64, cv.comp(0).float64, 1e-6)
    check near(cl.comp(1).float64, cv.comp(1).float64, 1e-6)
    check near(cl.comp(2).float64, cv.comp(2).float64, 1e-6)
  test "alpha is preserved through clamp":
    let c = color(tagOklab, 0.7'f32, 0.3'f32, 0.0'f32, 0.5'f32).get
    let r = clamp(c, tagSrgb).get
    check near(r.alpha.float64, 0.5, 1e-6)
  test "CMYK -> InvalidOp":
    let c = color(tagSrgb, 0.5'f32, 0.5'f32, 0.5'f32).get
    check clamp(c, tagCmyk).error.kind == InvalidOp

# --- batch: parity with per-color scalar API ----------------------------------

suite "batch: parity with scalar API":
  test "toBatch == to per element":
    let src = [color(tagSrgb, 0.2'f32, 0.5'f32, 0.8'f32).get,
               color(tagSrgb, 0.8'f32, 0.3'f32, 0.1'f32).get,
               color(tagSrgb, 0.1'f32, 0.7'f32, 0.3'f32).get]
    let batch = toBatch(src, tagOklch).get
    for i in 0 ..< src.len:
      let scalar = to(src[i], tagOklch).get
      check batch[i] == scalar
  test "gamutMapBatch == gamutMap per element":
    let src = [color(tagRec2020, 1.0'f32, 0.0'f32, 0.0'f32).get,
               color(tagOklch, 0.8'f32, 0.32'f32, 0.0'f32).get,
               color(tagSrgb, 0.2'f32, 0.5'f32, 0.8'f32).get]
    let batch = gamutMapBatch(src, tagSrgb).get
    for i in 0 ..< src.len:
      let scalar = gamutMap(src[i], tagSrgb).get
      check batch[i] == scalar
  test "empty input -> empty output":
    let batch = toBatch([], tagSrgb).get
    check batch.len == 0

# --- errors: UnknownSpace, InvalidColor ---------------------------------------

suite "conversion errors":
  test "to an unregistered tag -> UnknownSpace":
    let c = color(tagSrgb, 0.5'f32, 0.5'f32, 0.5'f32).get
    check to(c, SpaceTag(9999)).error.kind == UnknownSpace
  test "xyY with y=0 -> InvalidColor":
    let c = color(tagXyy, 0.3'f32, 0.0'f32, 0.5'f32).get
    check to(c, tagXyz).error.kind == InvalidColor
  test "static to[tagOklch] matches runtime to(tagOklch)":
    let c = color(tagSrgb, 0.2'f32, 0.5'f32, 0.8'f32).get
    # Call syntax, not method syntax: `c.to[T]` parses as indexing.
    check to[tagOklch](c).get == to(c, tagOklch).get
