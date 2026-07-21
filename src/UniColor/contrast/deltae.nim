# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# deltae — CIE color-difference metrics (ΔE76/94/2000).
#
# Each metric reads `comp(0..2)` as CIELAB L,a,b DIRECTLY — no hub conversion.
# The CIE ΔE formulas are pure on Lab coords (white-point independent), and the
# Sharma golden tables feed Lab coords as-is; converting through the hub (D50)
# would break the bit-identical match to the published values. The caller hands
# in Lab colors (`color(tagLab, ...)`); a non-Lab Color is read as Lab anyway
# (no speculative tag validation).
#
# Compute is float64: the float32 Color comps are promoted before the
# arithmetic (ΔE2000's unstable ΔH' term needs float64; applied uniformly).
import std/math
import UniColor/core/core

func labComps(c: Color): (float64, float64, float64) {.inline.} =
  ## Read the three comps as CIELAB L,a,b promoted to float64.
  (c.comp(0).float64, c.comp(1).float64, c.comp(2).float64)

func deltaE76*(a, b: Color): float64 {.raises: [].} =
  ## CIE 1976 ΔE — euclidean distance in CIELAB. Symmetric.
  ## `ΔE76 = √((L₁−L₂)² + (a₁−a₂)² + (b₁−b₂)²)`.
  let (l1, a1, b1) = labComps(a)
  let (l2, a2, b2) = labComps(b)
  sqrt((l1 - l2)^2 + (a1 - a2)^2 + (b1 - b2)^2)

func deltaE94*(a, b: Color): float64 {.raises: [].} =
  ## CIE 1994 ΔE. ASYMMETRIC: `a` is the reference (C1) — swapping the operands
  ## can change the result, because the S_C/S_H weights derive from C1 only.
  ## `ΔE94 = √( (ΔL/(kL·SL))² + (ΔC/(kC·SC))² + (ΔH/(kH·SH))² )`, with
  ## kL=kC=kH=1, SL=1, SC=1+0.045·C1, SH=1+0.015·C1, ΔC=C1−C2,
  ## ΔH²=Δa²+Δb²−ΔC² (clamped ≥0). The hue term is evaluated as `ΔH²/SH²`
  ## (NOT `(√ΔH²/SH)²`) — the round-trip sqrt·square would lose precision and
  ## break the bit-identical match to the reference.
  let (l1, a1, b1) = labComps(a)
  let (l2, a2, b2) = labComps(b)
  let c1 = sqrt(a1^2 + b1^2)
  let c2 = sqrt(a2^2 + b2^2)
  let dC = c1 - c2
  let da = a1 - a2
  let db = b1 - b2
  var dH2 = da^2 + db^2 - dC^2
  if dH2 < 0.0: dH2 = 0.0
  let dL = l1 - l2
  let sL = 1.0
  let sC = 1.0 + 0.045 * c1
  let sH = 1.0 + 0.015 * c1
  sqrt((dL / sL)^2 + (dC / sC)^2 + dH2 / (sH * sH))

func huePrime(bi, aip: float64): float64 =
  ## atan2(b, a') in degrees, mapped to [0, 360). Achromatic (a'=0, b=0) → 0.
  if bi == 0.0 and aip == 0.0: 0.0
  else:
    var h = arctan2(bi, aip).radToDeg
    if h < 0.0: h += 360.0
    h

func deltaE2000*(a, b: Color): float64 {.raises: [].} =
  ## CIEDE2000 ΔE (Sharma 2005). SYMMETRIC: `deltaE2000(a, b) ==
  ## deltaE2000(b, a)` by construction (the Δh'/h̄' branch logic cancels the
  ## operand order). float64 throughout (the ΔH' term is numerically unstable).
  ##
  ## Steps follow the canonical Sharma pseudo-code (ciede2000noteCRNA.pdf):
  ##   G = 0.5·(1 − √(C̄⁷/(C̄⁷+25⁷))) ; a' = (1+G)·a ; C' = √(a'²+b²) ;
  ##   h' = atan2(b,a') ∈[0,360)
  ##   ΔL' = L2−L1 ; ΔC' = C2'−C1' ; Δh' (wrapped to ±180) ;
  ##   ΔH' = 2·√(C1'C2')·sin(Δh'/2)
  ##   T = 1 − 0.17·cos(h̄'−30) + 0.24·cos(2h̄') + 0.32·cos(3h̄'+6)
  ##       − 0.20·cos(4h̄'−63)
  ##   Δθ = 30·exp(−((h̄'−275)/25)²) ; R_C = 2·√(C̄'⁷/(C̄'⁷+25⁷)) ;
  ##   R_T = −sin(2Δθ)·R_C
  ##   S_L = 1 + 0.015·(L̄'−50)²/√(20+(L̄'−50)²) ; S_C = 1+0.045·C̄' ;
  ##   S_H = 1+0.015·C̄'·T
  ##   ΔE00 = √( (ΔL'/S_L)² + (ΔC'/S_C)² + (ΔH'/S_H)²
  ##             + R_T·(ΔC'/S_C)·(ΔH'/S_H) ), kL=kC=kH=1.
  ## Edge case: C1'·C2' = 0 (achromatic) → Δh' = 0 and h̄' = h1'+h2' (no wrap);
  ## R_T's rotation is then governed by h̄' alone. Angles in degrees; sin/cos
  ## take radians.
  const TWENTYFIVE_7 = 6103515625.0 # 25^7, exact in float64.
  let (l1, a1, b1) = labComps(a)
  let (l2, a2, b2) = labComps(b)

  # Step 1-3: mean chroma and the a-axis scale factor G.
  let c1 = sqrt(a1 * a1 + b1 * b1)
  let c2 = sqrt(a2 * a2 + b2 * b2)
  let cBar = (c1 + c2) / 2.0
  let cBar7 = pow(cBar, 7.0)
  let g = 0.5 * (1.0 - sqrt(cBar7 / (cBar7 + TWENTYFIVE_7)))

  # Step 4-6: adjusted a', chroma C', hue h' ∈ [0,360).
  let a1p = (1.0 + g) * a1
  let a2p = (1.0 + g) * a2
  let c1p = sqrt(a1p * a1p + b1 * b1)
  let c2p = sqrt(a2p * a2p + b2 * b2)
  let h1p = huePrime(b1, a1p)
  let h2p = huePrime(b2, a2p)

  # Step 7-10: ΔL', ΔC', Δh' (wrapped), ΔH'.
  let dLp = l2 - l1
  let dCp = c2p - c1p
  var dhpDeg: float64
  if c1p * c2p == 0.0:
    dhpDeg = 0.0
  else:
    let diff = h2p - h1p
    if abs(diff) <= 180.0: dhpDeg = diff
    elif diff > 180.0: dhpDeg = diff - 360.0
    else: dhpDeg = diff + 360.0
  let dHp = 2.0 * sqrt(c1p * c2p) * sin(degToRad(dhpDeg / 2.0))

  # Step 11-13: means L̄', C̄', h̄' (wrap rules).
  let lBarp = (l1 + l2) / 2.0
  let cBarp = (c1p + c2p) / 2.0
  var hBarp: float64
  if c1p * c2p == 0.0:
    hBarp = h1p + h2p
  elif abs(h1p - h2p) <= 180.0:
    hBarp = (h1p + h2p) / 2.0
  elif (h1p + h2p) < 360.0:
    hBarp = (h1p + h2p + 360.0) / 2.0
  else:
    hBarp = (h1p + h2p - 360.0) / 2.0

  # Step 14-20: T, Δθ, R_C, S_L, S_C, S_H, R_T.
  let t = 1.0 - 0.17 * cos(degToRad(hBarp - 30.0)) +
      0.24 * cos(degToRad(2.0 * hBarp)) +
      0.32 * cos(degToRad(3.0 * hBarp + 6.0)) - 0.20 * cos(degToRad(4.0 *
          hBarp - 63.0))
  let dTheta = 30.0 * exp(-pow((hBarp - 275.0) / 25.0, 2.0))
  let cBarp7 = pow(cBarp, 7.0)
  let rC = 2.0 * sqrt(cBarp7 / (cBarp7 + TWENTYFIVE_7))
  let sL = 1.0 + (0.015 * (lBarp - 50.0) * (lBarp - 50.0)) / sqrt(20.0 + (
      lBarp - 50.0) * (lBarp - 50.0))
  let sC = 1.0 + 0.045 * cBarp
  let sH = 1.0 + 0.015 * cBarp * t
  let rT = -sin(degToRad(2.0 * dTheta)) * rC

  # Step 21-22: compose (kL=kC=kH=1).
  let termL = dLp / sL
  let termC = dCp / sC
  let termH = dHp / sH
  sqrt(termL * termL + termC * termC + termH * termH + rT * termC * termH)
