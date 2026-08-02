# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# cmc — CMC(l:c) 1984 color difference (textile / graphic-arts).
#
# Reads `comp(0..2)` as CIELAB L,a,b DIRECTLY — no hub conversion (consistent
# with deltaE76/94/2000; the CMC formula is pure on Lab coords). The caller
# hands in Lab colors (`color(tagLab, ...)`); a non-Lab Color is read as Lab
# anyway (no speculative tag validation). Compute is float64.
#
# ASYMMETRIC: `a` is the reference (sample 1). S_L/S_C/S_H and the hue T all
# derive from sample 1 only, so `deltaE_cmc(a, b) != deltaE_cmc(b, a)` in
# general — CMC is a quasimetric.
#
# The canonical CMC (Clarke-McDonald-Rigg 1984 / BS 6923 / colour-science) uses
# h₁ (the REFERENCE hue), NOT the mean h̄. Verified against two independent
# published anchors: colour-science (100,21.572,272.228)/(100,426.679,72.396)
# l:c=2:1 → 172.7047712, and Skychem (50,2.5,-10)/(52,3.1,-8.8) 2:1 → ~1.75.
# Using h₁ reproduces both bit-for-bit; h̄ would not.
import std/math
import UniColor/core/core

func labComps(c: Color): (float64, float64, float64) {.inline.} =
  ## Read the three comps as CIELAB L,a,b promoted to float64.
  (c.comp(0).float64, c.comp(1).float64, c.comp(2).float64)

func deltaE_cmc*(a, b: Color, l = 2.0, c = 1.0): float64 {.raises: [].} =
  ## CMC(l:c) 1984 ΔE (colour-science). ASYMMETRIC: `a` is the reference
  ## (sample 1). `l`/`c` are the lightness/chroma tolerance ratios (textiles
  ## default 2:1 = acceptability, graphic-arts 1:1 = threshold of
  ## imperceptibility).
  ## `ΔE_cmc = √( (ΔL/(l·S_L))² + (ΔC/(c·S_C))² + (ΔH/S_H)² )`, with
  ## ΔL=L₁−L₂, ΔC=C₁−C₂, ΔH²=Δa²+Δb²−ΔC² (clamped ≥0),
  ## S_L=0.511 if L₁<16 else 0.040975·L₁/(1+0.01765·L₁),
  ## S_C=0.0638·C₁/(1+0.0131·C₁)+0.638, S_H=S_C·(f·T+1−f),
  ## f=√(C₁⁴/(C₁⁴+1900)), T=0.56+|0.2·cos(h₁+168°)| for h₁∈[164,345]
  ## else 0.36+|0.4·cos(h₁+35°)|. h₁ = atan2(b₁,a₁) mapped to [0,360).
  ## The hue term is `ΔH²/S_H²` (no sqrt round-trip) for a bit-identical match
  ## to the oracle. Achromatic C₁=0 → h₁=0 and f=0 (T drops out: S_H=S_C).
  let (l1, a1, b1) = labComps(a)
  let (l2, a2, b2) = labComps(b)
  let c1 = sqrt(a1 * a1 + b1 * b1)
  let c2 = sqrt(a2 * a2 + b2 * b2)
  let dL = l1 - l2
  let dC = c1 - c2
  let da = a1 - a2
  let db = b1 - b2
  var dH2 = da * da + db * db - dC * dC
  if dH2 < 0.0: dH2 = 0.0
  var h1 = arctan2(b1, a1).radToDeg
  if h1 < 0.0: h1 += 360.0
  let sL = if l1 < 16.0: 0.511 else: 0.040975 * l1 / (1.0 + 0.01765 * l1)
  let sC = 0.0638 * c1 / (1.0 + 0.0131 * c1) + 0.638
  let c1_4 = c1 * c1 * c1 * c1
  let f = sqrt(c1_4 / (c1_4 + 1900.0))
  let t = if h1 >= 164.0 and h1 <= 345.0:
    0.56 + abs(0.2 * cos(degToRad(h1 + 168.0)))
  else:
    0.36 + abs(0.4 * cos(degToRad(h1 + 35.0)))
  let sH = sC * (f * t + 1.0 - f)
  let termL = dL / (l * sL)
  let termC = dC / (c * sC)
  let termH2 = dH2 / (sH * sH)
  sqrt(termL * termL + termC * termC + termH2)
