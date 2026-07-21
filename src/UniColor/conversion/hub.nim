# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# hub — XYZ hub conversion: toXYZ / fromXYZ dispatched by space family.
# A -> B = A.toXYZ() + B.fromXYZ(); all transit is float64, the final Color
# stores float32. Whitepoint adaptation (Bradford, in math/whitepoint) is
# applied when the space whitepoint differs from the hub (D65). NaN propagates:
# comparisons are false, products are NaN — no exception.
#
# Wired families: famXyz, famRgbLinear, famRgbEncoded, famXyy, famLab/famLch
# (D50 + Bradford), famOklab/famOklch (via linear-sRGB), famHsv/famHsl/famHwb
# and famYcbcr (via encoded sRGB), famIctcp, famJzazbz, famCam16, famCam16Ucs,
# famHct. CMYK returns InvalidOp (non-redeemable, no round-trip through XYZ).

import std/options
import std/math

import UniColor/core/core
import UniColor/math/math
import UniColor/spaces/spaces
import UniColor/conversion/cam16_view # vc, signum (Material DEFAULT viewing conditions)
import UniColor/conversion/hct_solver # solveToInt (HCT -> sRGB Newton solver)

# EOTF (encoded -> linear) selected by transfer kind. tkPq/tkHlg are not used by
# any famRgbEncoded space (HDR lives in famIctcp/famJzazbz), so they return NaN.
func eotfOf(k: TransferKind, gamma: float64, c: float64): float64 {.inline,
    raises: [].} =
  case k
  of tkNone: c
  of tkSrgb: srgbEotf(c)
  of tkGamma: gammaEotf(c, gamma)
  of tkProPhoto: proPhotoEotf(c)
  of tkRec2020: rec2020Eotf(c)
  of tkPq, tkHlg: NaN

func oetfOf(k: TransferKind, gamma: float64, c: float64): float64 {.inline,
    raises: [].} =
  case k
  of tkNone: c
  of tkSrgb: srgbOetf(c)
  of tkGamma: gammaOetf(c, gamma)
  of tkProPhoto: proPhotoOetf(c)
  of tkRec2020: rec2020Oetf(c)
  of tkPq, tkHlg: NaN

# --- OKLab inverse matrices (exact, via inverse3) -----------------------------
# The published Ottosson forward/inverse constants are rounded independently, so
# their product is ~1e-5 off identity — enough to break OKLCH hue round-trip at
# TOL_ROUNDTRIP. Computing the inverse from the forward matrix (inverse3 runs at
# compile time in a const context) gives an exact inverse.
const
  oklabLmsInv = inverse3(oklabLms).get
  oklabMInv = inverse3(oklabM).get

# linear-sRGB descriptor captured once: the accessor calls inverse3.expect
# (raises), so it cannot be called inside a raises:[] proc. The Rec.709 primaries
# are invertible, so this module-level let is safe.
let srgbLinDesc = srgbLinearDescriptor()

# --- CIELAB nonlinearity (eps = 6/29) ------------------------------------------
const
  eps = EPS_LAB                   # 6/29
  eps3 = eps * eps * eps          # (6/29)^3, XYZ->Lab cube-root threshold
  labToeSlope = 3.0 * eps * eps   # 108/841, Lab->XYZ linear toe slope
  invToeSlope = 1.0 / labToeSlope # 841/108, XYZ->Lab linear toe slope
  toeOffset = 4.0 / 29.0

func degToRad(d: float64): float64 {.inline, raises: [].} = d * PI / 180.0
func radToDeg(r: float64): float64 {.inline, raises: [].} = r * 180.0 / PI

# XYZ->Lab nonlinearity (cube root + linear toe). cbrtSigned preserves negative
# out-of-gamut.
func labF(t: float64): float64 {.inline, raises: [].} =
  if t > eps3: cbrtSigned(t) else: t * invToeSlope + toeOffset

# Lab->XYZ nonlinearity (cube + linear toe). t*t*t preserves the sign of
# negatives.
func labG(t: float64): float64 {.inline, raises: [].} =
  if t > eps: t * t * t else: labToeSlope * (t - toeOffset)

func xyzD50ToLab(xyz: Vec3): tuple[l, a, b: float64] {.raises: [].} =
  let fx = labF(xyz[0] / wpD50[0])
  let fy = labF(xyz[1] / wpD50[1])
  let fz = labF(xyz[2] / wpD50[2])
  (116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))

func labToXyzD50(l, a, b: float64): Vec3 {.raises: [].} =
  let fy = (l + 16.0) / 116.0
  let fx = fy + a / 500.0
  let fz = fy - b / 200.0
  [labG(fx) * wpD50[0], labG(fy) * wpD50[1], labG(fz) * wpD50[2]]

func oklabToLinearSrgb(l, a, b: float64): Vec3 {.raises: [].} =
  # OKLab -> (l',m',s') -> cube -> LMS -> linear-sRGB.
  let lmsP = apply3(oklabMInv, [l, a, b])
  apply3(oklabLmsInv, [lmsP[0] * lmsP[0] * lmsP[0],
                       lmsP[1] * lmsP[1] * lmsP[1],
                       lmsP[2] * lmsP[2] * lmsP[2]])

func linearSrgbToOklab(rgb: Vec3): tuple[l, a, b: float64] {.raises: [].} =
  # linear-sRGB -> LMS -> signed cube root -> OKLab.
  let lms = apply3(oklabLms, rgb)
  let lmsP = [cbrtSigned(lms[0]), cbrtSigned(lms[1]), cbrtSigned(lms[2])]
  let lab = apply3(oklabM, lmsP)
  (lab[0], lab[1], lab[2])

# --- HSV / HSL / HWB on encoded sRGB [0,1] (CSS Color 4) ----------------------
# Hue in degrees [0,360); sextant algorithm. NaN hue propagates to NaN rgb.
func hueToRgb(h, s, v: float64): Vec3 {.raises: [].} =
  let hp = (h mod 360.0) / 60.0
  let i = floor(hp)
  let f = hp - i
  let p = v * (1.0 - s)
  let q = v * (1.0 - s * f)
  let t = v * (1.0 - s * (1.0 - f))
  case i mod 6.0
  of 0.0: [v, t, p]
  of 1.0: [q, v, p]
  of 2.0: [p, v, t]
  of 3.0: [p, q, v]
  of 4.0: [t, p, v]
  else: [v, p, q]

func rgbToHue(mx, mn, d, r, g, b: float64): float64 {.inline, raises: [].} =
  # Hue in degrees [0,360); 0 when achromatic (d ~ 0). NaN mx -> comparisons
  # false -> 0. Nim float `mod` is truncated (fmod), so the red-max branch
  # yields a negative hue when g < b; normalize into [0,360) there.
  if d < TOL_NUMERIC_ABS: 0.0
  elif mx == r:
    let h = 60.0 * (((g - b) / d) mod 6.0)
    if h < 0.0: h + 360.0 else: h
  elif mx == g: 60.0 * ((b - r) / d + 2.0)
  else: 60.0 * ((r - g) / d + 4.0)

func srgbToHsv(r, g, b: float64): tuple[h, s, v: float64] {.raises: [].} =
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let d = mx - mn
  let s = if mx > TOL_NUMERIC_ABS: d / mx else: 0.0
  (rgbToHue(mx, mn, d, r, g, b), s, mx)

func hsvToSrgb(h, s, v: float64): Vec3 {.raises: [].} = hueToRgb(h, s, v)

func srgbToHsl(r, g, b: float64): tuple[h, s, l: float64] {.raises: [].} =
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let l = (mx + mn) / 2.0
  let d = mx - mn
  if d < TOL_NUMERIC_ABS:
    (0.0, 0.0, l)
  else:
    let s = if l > 0.0 and l < 1.0: d / (1.0 - abs(2.0 * l - 1.0)) else: 0.0
    (rgbToHue(mx, mn, d, r, g, b), s, l)

func hslToSrgb(h, s, l: float64): Vec3 {.raises: [].} =
  let c = (1.0 - abs(2.0 * l - 1.0)) * s
  let hp = (h mod 360.0) / 60.0
  let x = c * (1.0 - abs((hp mod 2.0) - 1.0))
  let m = l - c / 2.0
  var rgb: Vec3
  case floor(hp) mod 6.0
  of 0.0: rgb = [c, x, 0.0]
  of 1.0: rgb = [x, c, 0.0]
  of 2.0: rgb = [0.0, c, x]
  of 3.0: rgb = [0.0, x, c]
  of 4.0: rgb = [x, 0.0, c]
  else: rgb = [c, 0.0, x]
  [rgb[0] + m, rgb[1] + m, rgb[2] + m]

func srgbToHwb(r, g, b: float64): tuple[h, w, bl: float64] {.raises: [].} =
  # W = min channel, B = 1 - max channel, H shared with HSV/HSL hue (CSS Color 4).
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  (rgbToHue(mx, mn, mx - mn, r, g, b), mn, 1.0 - mx)

func hwbToSrgb(h, w, bl: float64): Vec3 {.raises: [].} =
  if w + bl >= 1.0:
    let gray = w / (w + bl)
    return [gray, gray, gray]
  # Pure hue (S=1, V=1) scaled by (1-w-bl) then whiteness added (CSS Color 4).
  let hue = hueToRgb(h, 1.0, 1.0)
  let k = 1.0 - w - bl
  [hue[0] * k + w, hue[1] * k + w, hue[2] * k + w]

# --- YCbCr BT.709 full-range on encoded sRGB; chroma centered 0, span [-0.5,0.5]
const
  YcbcrKr = 0.2126
  YcbcrKb = 0.0722
  YcbcrKg = 0.7152
  YcbcrCrScale = 2.0 * (1.0 - YcbcrKr) # 1.5748
  YcbcrCbScale = 2.0 * (1.0 - YcbcrKb) # 1.8556

func srgbToYcbcr(r, g, b: float64): tuple[y, cb, cr: float64] {.raises: [].} =
  let y = YcbcrKr * r + YcbcrKg * g + YcbcrKb * b
  (y, (b - y) / YcbcrCbScale, (r - y) / YcbcrCrScale)

func ycbcrToSrgb(y, cb, cr: float64): Vec3 {.raises: [].} =
  let r = y + YcbcrCrScale * cr
  let b = y + YcbcrCbScale * cb
  let g = (y - YcbcrKr * r - YcbcrKb * b) / YcbcrKg
  [r, g, b]

# --- ICtCp (BT.2100 PQ, Rec.2020 linear, D65) ---------------------------------
# Pipeline: XYZ -> linear Rec.2020 -> LMS -> PQ OETF -> ICtCp. The LMS and ICtCp
# matrices are the BT.2100 constants (integer numerators over 4096); their
# inverses are computed exactly via inverse3 at compile time. PQ operates on
# normalized cone responses (1 = 10000 cd/m² peak), matching pqOetf/pqEotf which
# scale by PqPeakNits internally.
const
  ictcpRgbToLms: Mat3 = [[0.412109375, 0.52392578125, 0.06396484375],
                         [0.166748046875, 0.720458984375, 0.11279296875],
                         [0.024169921875, 0.075439453125, 0.900390625]]
  ictcpLmsPToIctcp: Mat3 = [[0.5, 0.5, 0.0],
                            [1.61376953125, -3.323486328125, 1.709716796875],
                            [4.378173828125, -4.2431640625, -0.132568359375]]
  ictcpRgbToLmsInv = inverse3(ictcpRgbToLms).get
  ictcpLmsPToIctcpInv = inverse3(ictcpLmsPToIctcp).get

# Rec.2020 linear descriptor captured once: the accessor calls inverse3.expect
# (raises), so it cannot be called inside a raises:[] proc body that needs const
# purity.
let rec2020LinDesc = rec2020LinearDescriptor()

# --- JzAzBz (Safdar 2017 perceptual quantizer, D65) ----------------------------
# Pipeline: X'Y'Z' pre-transform (b,g) -> LMS -> Jz-PQ OETF (re-optimized m2) ->
# IzAzBz -> Jz lightness scaling. Inverse recovers Iz, then reverses each step;
# the Y recovery uses the already-recovered X (per Safdar).
const
  jzB = 1.15
  jzG = 0.66
  jzD = -0.56
  jzD0 = 1.6295499532821566e-11
  jzXyzToLms: Mat3 = [[0.41478972, 0.579999, 0.0146480],
                      [-0.2015100, 1.120649, 0.0531008],
                      [-0.0166008, 0.264800, 0.6684799]]
  jzLmsPToIzazbz: Mat3 = [[0.5, 0.5, 0.0],
                          [3.524000, -4.066708, 0.542708],
                          [0.199076, 1.096799, -1.295875]]
  jzXyzToLmsInv = inverse3(jzXyzToLms).get
  jzLmsPToIzazbzInv = inverse3(jzLmsPToIzazbz).get

# --- CAM16 / CAM16-UCS (Material DEFAULT viewing conditions, D65 on [0,100]) ----
# Material Color Utilities works on XYZ on the [0,100] scale (WHITE_POINT_D65 =
# [95.047,100,108.883]); the hub is on [0,1], so we scale x100 at this boundary.
# Viewing conditions are frozen to Google Material DEFAULT: adapting luminance
# L_A ~ 11.726, backgroundLstar 50 -> n = Y_b = 0.18419, surround average (f=1,
# c=0.69, n_c=1), discounting illuminant false (d ~ 0.845). One condition, no
# configurability. The ViewingConditions type, `vc` let, signum, and
# yFromLstar100 live in cam16_view, shared with hct_solver so the solver can read
# `vc` without importing hub (which would cycle: hub imports hct_solver). The
# helper procs below read `vc` (procs, not funcs — funcs cannot read a
# module-level let); reading a let never throws, so raises:[] holds.

# XYZ [0,100] -> CAM16 forward: returns J, C, h plus the UCS coordinates
# j*, a*, b* (cam16.ts).
proc xyz100ToCam16(x, y, z: float64): tuple[j, c, h, jstar, astar,
    bstar: float64] {.
    raises: [].} =
  let rC = 0.401288 * x + 0.650173 * y - 0.051461 * z
  let gC = -0.250268 * x + 1.204414 * y + 0.045854 * z
  let bC = -0.002079 * x + 0.048952 * y + 0.953127 * z
  let rD = vc.rgbD[0] * rC
  let gD = vc.rgbD[1] * gC
  let bD = vc.rgbD[2] * bC
  let rAf = pow(vc.fl * abs(rD) / 100.0, 0.42)
  let gAf = pow(vc.fl * abs(gD) / 100.0, 0.42)
  let bAf = pow(vc.fl * abs(bD) / 100.0, 0.42)
  let rA = signum(rD) * 400.0 * rAf / (rAf + 27.13)
  let gA = signum(gD) * 400.0 * gAf / (gAf + 27.13)
  let bA = signum(bD) * 400.0 * bAf / (bAf + 27.13)
  let a = (11.0 * rA - 12.0 * gA + bA) / 11.0
  let b = (rA + gA - 2.0 * bA) / 9.0
  let u = (20.0 * rA + 20.0 * gA + 21.0 * bA) / 20.0
  let p2 = (40.0 * rA + 20.0 * gA + bA) / 20.0
  var hue = radToDeg(arctan2(b, a))
  if hue < 0.0: hue += 360.0
  let hRad = degToRad(hue)
  let ac = p2 * vc.nbb
  let j = 100.0 * pow(ac / vc.aw, vc.c * vc.z)
  let huePrime = if hue < 20.14: hue + 360.0 else: hue
  let eHue = 0.25 * (cos(degToRad(huePrime) + 2.0) + 3.8)
  let p1 = (50000.0 / 13.0) * eHue * vc.nc * vc.ncb
  let t = p1 * sqrt(a * a + b * b) / (u + 0.305)
  let alpha = pow(t, 0.9) * pow(1.64 - pow(0.29, vc.n), 0.73)
  let c = alpha * sqrt(j / 100.0)
  let m = c * vc.flRoot
  let jstar = (1.0 + 100.0 * 0.007) * j / (1.0 + 0.007 * j)
  let mstar = ln(1.0 + 0.0228 * m) / 0.0228
  let astar = mstar * cos(hRad)
  let bstar = mstar * sin(hRad)
  (j, c, hue, jstar, astar, bstar)

# CAM16 inverse: J, C, h -> XYZ [0,100] (cam16.ts viewed/xyzInViewingConditions).
proc cam16ToXyz100(j, c, h: float64): Vec3 {.raises: [].} =
  let alpha = if c == 0.0 or j == 0.0: 0.0 else: c / sqrt(j / 100.0)
  let t = pow(alpha / pow(1.64 - pow(0.29, vc.n), 0.73), 1.0 / 0.9)
  let hRad = degToRad(h)
  let eHue = 0.25 * (cos(hRad + 2.0) + 3.8)
  let ac = vc.aw * pow(j / 100.0, 1.0 / (vc.c * vc.z))
  let p1 = eHue * (50000.0 / 13.0) * vc.nc * vc.ncb
  let p2 = ac / vc.nbb
  let hSin = sin(hRad)
  let hCos = cos(hRad)
  let gamma = 23.0 * (p2 + 0.305) * t / (23.0 * p1 + 11.0 * t * hCos + 108.0 *
      t * hSin)
  let a = gamma * hCos
  let b = gamma * hSin
  let rA = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0
  let gA = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0
  let bA = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0
  let rCBase = max(0.0, 27.13 * abs(rA) / (400.0 - abs(rA)))
  let gCBase = max(0.0, 27.13 * abs(gA) / (400.0 - abs(gA)))
  let bCBase = max(0.0, 27.13 * abs(bA) / (400.0 - abs(bA)))
  let rC = signum(rA) * (100.0 / vc.fl) * pow(rCBase, 1.0 / 0.42)
  let gC = signum(gA) * (100.0 / vc.fl) * pow(gCBase, 1.0 / 0.42)
  let bC = signum(bA) * (100.0 / vc.fl) * pow(bCBase, 1.0 / 0.42)
  let rF = rC / vc.rgbD[0]
  let gF = gC / vc.rgbD[1]
  let bF = bC / vc.rgbD[2]
  [1.86206786 * rF - 1.01125463 * gF + 0.14918677 * bF,
   0.38752654 * rF + 0.62144744 * gF - 0.00897398 * bF,
   -0.01584150 * rF - 0.03412294 * gF + 1.04996444 * bF]

# CAM16-UCS -> CAM16 J/C/h (cam16.ts fromUcs): M* -> M -> C, hue from a*/b*, J from
# j*.
proc ucsToCam16Jch(jstar, astar, bstar: float64): tuple[j, c,
    h: float64] {.raises: [].} =
  let m = sqrt(astar * astar + bstar * bstar)
  let bigM = (exp(m * 0.0228) - 1.0) / 0.0228
  let c = bigM / vc.flRoot
  var h = radToDeg(arctan2(bstar, astar))
  if h < 0.0: h += 360.0
  let j = jstar / (1.0 - (jstar - 100.0) * 0.007)
  (j, c, h)

proc toXYZ*(c: Color): Result[Vec3, ColorError] {.raises: [].} =
  ## Convert `c` (any registered space) to hub XYZ (D65). Returns InvalidOp for
  ## CMYK (non-redeemable), UnknownSpace for an unregistered tag.
  let d = spaceByTag(c.spaceTag)
  if d.isNone:
    return err[Vec3, ColorError](colorError(UnknownSpace,
        "space not registered", $c.spaceTag))
  let desc = d.get
  let comps: Vec3 = [toF64(c.comp(0)), toF64(c.comp(1)), toF64(c.comp(2))]
  var xyz: Vec3
  case desc.family
  of famXyz:
    xyz = comps
  of famRgbLinear:
    xyz = apply3(desc.toXYZ, comps)
    if desc.whitepoint != wpD65:
      xyz = adapt(xyz, desc.whitepoint, wpD65)
  of famRgbEncoded:
    let lin: Vec3 = [
      eotfOf(desc.transferKind, desc.gamma, comps[0]),
      eotfOf(desc.transferKind, desc.gamma, comps[1]),
      eotfOf(desc.transferKind, desc.gamma, comps[2])
    ]
    xyz = apply3(desc.toXYZ, lin)
    if desc.whitepoint != wpD65:
      xyz = adapt(xyz, desc.whitepoint, wpD65)
  of famXyy:
    let y = comps[1]
    if abs(y) < TOL_NUMERIC_ABS:
      return err[Vec3, ColorError](colorError(InvalidColor,
          "xyY with y=0 is undefined", "xyyToXYZ"))
    let Y = comps[2]
    xyz = [comps[0] * Y / y, Y, (1.0 - comps[0] - comps[1]) * Y / y]
  of famLab:
    xyz = adapt(labToXyzD50(comps[0], comps[1], comps[2]), wpD50, wpD65)
  of famLch:
    let hr = degToRad(comps[2] mod 360.0)
    xyz = adapt(labToXyzD50(comps[0], comps[1] * cos(hr), comps[1] * sin(hr)),
        wpD50, wpD65)
  of famOklab:
    xyz = apply3(srgbLinDesc.toXYZ, oklabToLinearSrgb(comps[0], comps[1], comps[2]))
  of famOklch:
    let hr = degToRad(comps[2] mod 360.0)
    let oklab = color(tagOklab, toF32(comps[0]), toF32(comps[1] * cos(hr)),
                      toF32(comps[1] * sin(hr)))
    if oklab.isErr:
      return err[Vec3, ColorError](oklab.error)
    return toXYZ(oklab.get)
  of famHsv:
    let rgb = hsvToSrgb(comps[0], comps[1], comps[2])
    let srgb = color(tagSrgb, toF32(rgb[0]), toF32(rgb[1]), toF32(rgb[2]))
    if srgb.isErr:
      return err[Vec3, ColorError](srgb.error)
    return toXYZ(srgb.get)
  of famHsl:
    let rgb = hslToSrgb(comps[0], comps[1], comps[2])
    let srgb = color(tagSrgb, toF32(rgb[0]), toF32(rgb[1]), toF32(rgb[2]))
    if srgb.isErr:
      return err[Vec3, ColorError](srgb.error)
    return toXYZ(srgb.get)
  of famHwb:
    let rgb = hwbToSrgb(comps[0], comps[1], comps[2])
    let srgb = color(tagSrgb, toF32(rgb[0]), toF32(rgb[1]), toF32(rgb[2]))
    if srgb.isErr:
      return err[Vec3, ColorError](srgb.error)
    return toXYZ(srgb.get)
  of famYcbcr:
    let rgb = ycbcrToSrgb(comps[0], comps[1], comps[2])
    let srgb = color(tagSrgb, toF32(rgb[0]), toF32(rgb[1]), toF32(rgb[2]))
    if srgb.isErr:
      return err[Vec3, ColorError](srgb.error)
    return toXYZ(srgb.get)
  of famIctcp:
    let lmsP = apply3(ictcpLmsPToIctcpInv, comps)
    let lms = [pqEotf(lmsP[0]), pqEotf(lmsP[1]), pqEotf(lmsP[2])]
    let lin = apply3(ictcpRgbToLmsInv, lms)
    xyz = apply3(rec2020LinDesc.toXYZ, lin)
  of famJzazbz:
    let jp = comps[0] + jzD0
    let iz = jp / (1.0 + jzD - jzD * jp)
    let lmsP = apply3(jzLmsPToIzazbzInv, [iz, comps[1], comps[2]])
    let lms = [pqEotfJz(lmsP[0]), pqEotfJz(lmsP[1]), pqEotfJz(lmsP[2])]
    let xpYpZp = apply3(jzXyzToLmsInv, lms)
    let x = (xpYpZp[0] + (jzB - 1.0) * xpYpZp[2]) / jzB
    let y = (xpYpZp[1] + (jzG - 1.0) * x) / jzG
    xyz = [x, y, xpYpZp[2]]
  of famCam16:
    # CAM16 J/C/h -> XYZ [0,100] -> hub [0,1].
    let v = cam16ToXyz100(comps[0], comps[1], comps[2])
    xyz = [v[0] / 100.0, v[1] / 100.0, v[2] / 100.0]
  of famCam16Ucs:
    # CAM16-UCS j*/a*/b* -> J/C/h -> XYZ [0,100] -> hub [0,1].
    let jch = ucsToCam16Jch(comps[0], comps[1], comps[2])
    let v = cam16ToXyz100(jch.j, jch.c, jch.h)
    xyz = [v[0] / 100.0, v[1] / 100.0, v[2] / 100.0]
  of famHct:
    # HCT H/C/T -> 8-bit sRGB (Material Newton solver, gamut-mapped) -> hub XYZ
    # via sRGB.
    let argb = solveToInt(comps[0], comps[1], comps[2])
    let srgb = color(tagSrgb,
                     float32((argb shr 16) and 255) / 255.0'f32,
                     float32((argb shr 8) and 255) / 255.0'f32,
                     float32(argb and 255) / 255.0'f32)
    if srgb.isErr:
      return err[Vec3, ColorError](srgb.error)
    return toXYZ(srgb.get)
  else:
    return err[Vec3, ColorError](colorError(InvalidOp,
        "toXYZ not implemented for family", $desc.family))
  ok[Vec3, ColorError](xyz)

proc fromXYZ*(xyz: Vec3, target: SpaceTag): Result[Color,
    ColorError] {.raises: [].} =
  ## Convert hub XYZ (D65) to a Color in `target`. Inverse of `toXYZ` for the
  ## wired families; InvalidOp for CMYK, UnknownSpace for an unregistered tag.
  let d = spaceByTag(target)
  if d.isNone:
    return err[Color, ColorError](colorError(UnknownSpace,
        "target space not registered", $target))
  let desc = d.get
  case desc.family
  of famXyz:
    color(target, toF32(xyz[0]), toF32(xyz[1]), toF32(xyz[2]))
  of famRgbLinear:
    var x = xyz
    if desc.whitepoint != wpD65:
      x = adapt(x, wpD65, desc.whitepoint)
    let lin = apply3(desc.fromXYZ, x)
    color(target, toF32(lin[0]), toF32(lin[1]), toF32(lin[2]))
  of famRgbEncoded:
    var x = xyz
    if desc.whitepoint != wpD65:
      x = adapt(x, wpD65, desc.whitepoint)
    let lin = apply3(desc.fromXYZ, x)
    color(target,
          toF32(oetfOf(desc.transferKind, desc.gamma, lin[0])),
          toF32(oetfOf(desc.transferKind, desc.gamma, lin[1])),
          toF32(oetfOf(desc.transferKind, desc.gamma, lin[2])))
  of famXyy:
    let sum = xyz[0] + xyz[1] + xyz[2]
    if abs(sum) < TOL_NUMERIC_ABS:
      return err[Color, ColorError](colorError(InvalidColor,
          "XYZ sum=0 -> xyY undefined", "xyzToXyy"))
    color(target, toF32(xyz[0] / sum), toF32(xyz[1] / sum), toF32(xyz[1]))
  of famLab:
    let lab = xyzD50ToLab(adapt(xyz, wpD65, wpD50))
    color(target, toF32(lab.l), toF32(lab.a), toF32(lab.b))
  of famLch:
    let lab = xyzD50ToLab(adapt(xyz, wpD65, wpD50))
    let c = hypot(lab.a, lab.b)
    var h = radToDeg(arctan2(lab.b, lab.a)) mod 360.0
    if h < 0.0: h += 360.0
    color(target, toF32(lab.l), toF32(c), toF32(h))
  of famOklab:
    let o = linearSrgbToOklab(apply3(srgbLinDesc.fromXYZ, xyz))
    color(target, toF32(o.l), toF32(o.a), toF32(o.b))
  of famOklch:
    let o = linearSrgbToOklab(apply3(srgbLinDesc.fromXYZ, xyz))
    let c = hypot(o.a, o.b)
    var h = radToDeg(arctan2(o.b, o.a)) mod 360.0
    if h < 0.0: h += 360.0
    color(target, toF32(o.l), toF32(c), toF32(h))
  of famHsv:
    let srgb = fromXYZ(xyz, tagSrgb)
    if srgb.isErr:
      return err[Color, ColorError](srgb.error)
    let s = srgb.get
    let hsv = srgbToHsv(toF64(s.comp(0)), toF64(s.comp(1)), toF64(s.comp(2)))
    color(target, toF32(hsv.h), toF32(hsv.s), toF32(hsv.v))
  of famHsl:
    let srgb = fromXYZ(xyz, tagSrgb)
    if srgb.isErr:
      return err[Color, ColorError](srgb.error)
    let s = srgb.get
    let hsl = srgbToHsl(toF64(s.comp(0)), toF64(s.comp(1)), toF64(s.comp(2)))
    color(target, toF32(hsl.h), toF32(hsl.s), toF32(hsl.l))
  of famHwb:
    let srgb = fromXYZ(xyz, tagSrgb)
    if srgb.isErr:
      return err[Color, ColorError](srgb.error)
    let s = srgb.get
    let hwb = srgbToHwb(toF64(s.comp(0)), toF64(s.comp(1)), toF64(s.comp(2)))
    color(target, toF32(hwb.h), toF32(hwb.w), toF32(hwb.bl))
  of famYcbcr:
    let srgb = fromXYZ(xyz, tagSrgb)
    if srgb.isErr:
      return err[Color, ColorError](srgb.error)
    let s = srgb.get
    let ycc = srgbToYcbcr(toF64(s.comp(0)), toF64(s.comp(1)), toF64(s.comp(2)))
    color(target, toF32(ycc.y), toF32(ycc.cb), toF32(ycc.cr))
  of famIctcp:
    let lin = apply3(rec2020LinDesc.fromXYZ, xyz)
    let lms = apply3(ictcpRgbToLms, lin)
    let lmsP = [pqOetf(lms[0]), pqOetf(lms[1]), pqOetf(lms[2])]
    let ic = apply3(ictcpLmsPToIctcp, lmsP)
    color(target, toF32(ic[0]), toF32(ic[1]), toF32(ic[2]))
  of famJzazbz:
    let xp = jzB * xyz[0] - (jzB - 1.0) * xyz[2]
    let yp = jzG * xyz[1] - (jzG - 1.0) * xyz[0]
    let lms = apply3(jzXyzToLms, [xp, yp, xyz[2]])
    let lmsP = [pqOetfJz(lms[0]), pqOetfJz(lms[1]), pqOetfJz(lms[2])]
    let iz = apply3(jzLmsPToIzazbz, lmsP)
    let jz = (1.0 + jzD) * iz[0] / (1.0 + jzD * iz[0]) - jzD0
    color(target, toF32(jz), toF32(iz[1]), toF32(iz[2]))
  of famCam16:
    # Hub XYZ [0,1] -> XYZ [0,100] -> CAM16 J/C/h (forward).
    let cam = xyz100ToCam16(xyz[0] * 100.0, xyz[1] * 100.0, xyz[2] * 100.0)
    color(target, toF32(cam.j), toF32(cam.c), toF32(cam.h))
  of famCam16Ucs:
    # Hub XYZ [0,1] -> XYZ [0,100] -> CAM16-UCS j*/a*/b* (forward).
    let cam = xyz100ToCam16(xyz[0] * 100.0, xyz[1] * 100.0, xyz[2] * 100.0)
    color(target, toF32(cam.jstar), toF32(cam.astar), toF32(cam.bstar))
  of famHct:
    # Hub XYZ -> HCT (closed-form): T = L* from Y, H/C from CAM16 forward. No
    # solver here — the solver is only needed to invert HCT (T fixed) back to a
    # displayable sRGB color.
    let cam = xyz100ToCam16(xyz[0] * 100.0, xyz[1] * 100.0, xyz[2] * 100.0)
    let tone = 116.0 * labF(xyz[1]) - 16.0 # lstarFromY, xyz[1] on [0,1] = Y/100
    color(target, toF32(cam.h), toF32(cam.c), toF32(tone))
  else:
    err[Color, ColorError](colorError(InvalidOp,
        "fromXYZ not implemented for family", $desc.family))

# --- Shortest-paths (exact pairs) ----------------------------------------------
# Direct conversions for pair-exact spaces, bypassing the XYZ hub to avoid the
# double round and stay exact: polar <-> rectangular (Lab<->LCH, OKLab<->OKLCH),
# sRGB <-> sRGB-linear (EOTF/OETF only), and the HSV/HSL/HWB trio (anchored on
# encoded sRGB, bridged through sRGB without XYZ). The public `to` API (to.nim)
# routes exact pairs here first, then falls back to the 2-hop hub path. Results
# agree with the hub multi-bond path within TOL_EQUAL — the hub's
# same-whitepoint round-trip is sub-1e-6, so bypassing it only removes
# unnecessary ops, it does not change the answer at that tolerance.

func isShortPath*(src, target: SpaceTag): bool {.inline, raises: [].} =
  ## True iff (src, target) is an exact pair with a direct short-path.
  (src == tagLab and target == tagLch) or (src == tagLch and target ==
      tagLab) or
    (src == tagOklab and target == tagOklch) or (src == tagOklch and target ==
        tagOklab) or
    (src == tagSrgb and target == tagSrgbLin) or (src == tagSrgbLin and
        target == tagSrgb) or
    (src == tagHsv and target == tagHsl) or (src == tagHsl and target ==
        tagHsv) or
    (src == tagHsv and target == tagHwb) or (src == tagHwb and target ==
        tagHsv) or
    (src == tagHsl and target == tagHwb) or (src == tagHwb and target == tagHsl)

func toPolar(a, b: float64): tuple[c, h: float64] {.inline, raises: [].} =
  let c = hypot(a, b)
  var h = radToDeg(arctan2(b, a))
  if h < 0.0:
    h += 360.0
  (c, h)

func toRect(c, h: float64): tuple[a, b: float64] {.inline, raises: [].} =
  let r = degToRad(h)
  (c * cos(r), c * sin(r))

proc shortPath*(c: Color, target: SpaceTag): Result[Color,
    ColorError] {.raises: [].} =
  ## Direct conversion for an exact pair. Caller MUST check `isShortPath` first
  ## — this returns InvalidOp for a non-pair. Bypasses the XYZ hub: exact, single
  ## rounding to float32, alpha preserved.
  let src = c.spaceTag
  let x0 = toF64(c.comp(0))
  let x1 = toF64(c.comp(1))
  let x2 = toF64(c.comp(2))
  let a = c.alpha()
  if (src == tagLab and target == tagLch) or (src == tagOklab and target == tagOklch):
    let (c2, h) = toPolar(x1, x2)
    color(target, toF32(x0), toF32(c2), toF32(h), a) # L unchanged, (a,b) -> (C,h)
  elif (src == tagLch and target == tagLab) or (src == tagOklch and target == tagOklab):
    let (a2, b2) = toRect(x1, x2)
    color(target, toF32(x0), toF32(a2), toF32(b2), a) # L unchanged, (C,h) -> (a,b)
  elif src == tagSrgb and target == tagSrgbLin:
    color(target, toF32(srgbEotf(x0)), toF32(srgbEotf(x1)), toF32(srgbEotf(x2)), a)
  elif src == tagSrgbLin and target == tagSrgb:
    color(target, toF32(srgbOetf(x0)), toF32(srgbOetf(x1)), toF32(srgbOetf(x2)), a)
  elif src == tagHsv and target == tagHsl:
    let rgb = hsvToSrgb(x0, x1, x2)
    let (h, s, l) = srgbToHsl(rgb[0], rgb[1], rgb[2])
    color(target, toF32(h), toF32(s), toF32(l), a)
  elif src == tagHsl and target == tagHsv:
    let rgb = hslToSrgb(x0, x1, x2)
    let (h, s, v) = srgbToHsv(rgb[0], rgb[1], rgb[2])
    color(target, toF32(h), toF32(s), toF32(v), a)
  elif src == tagHsv and target == tagHwb:
    let rgb = hsvToSrgb(x0, x1, x2)
    let (h, w, bl) = srgbToHwb(rgb[0], rgb[1], rgb[2])
    color(target, toF32(h), toF32(w), toF32(bl), a)
  elif src == tagHwb and target == tagHsv:
    let rgb = hwbToSrgb(x0, x1, x2)
    let (h, s, v) = srgbToHsv(rgb[0], rgb[1], rgb[2])
    color(target, toF32(h), toF32(s), toF32(v), a)
  elif src == tagHsl and target == tagHwb:
    let rgb = hslToSrgb(x0, x1, x2)
    let (h, w, bl) = srgbToHwb(rgb[0], rgb[1], rgb[2])
    color(target, toF32(h), toF32(w), toF32(bl), a)
  elif src == tagHwb and target == tagHsl:
    let rgb = hwbToSrgb(x0, x1, x2)
    let (h, s, l) = srgbToHsl(rgb[0], rgb[1], rgb[2])
    color(target, toF32(h), toF32(s), toF32(l), a)
  else:
    err[Color, ColorError](colorError(InvalidOp, "not a short-path pair",
        $src & " -> " & $target))
