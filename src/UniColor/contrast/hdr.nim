# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# hdr — HDR perceptual color differences: ΔE_ITP (ICtCp, BT.2408) and ΔE_Jz
# (JzAzBz, Safdar 2017).
#
# Each metric reads `comp(0..2)` as its OWN reference-space coords DIRECTLY —
# no hub conversion (consistent with deltaE_ok / deltaE_cmc). The caller hands
# in colors already in the metric's reference space (`color(tagIctcp, ...)` /
# `color(tagJzazbz, ...)`); a Color in the wrong space is read as-is (no
# speculative tag validation). Compute is float64. Both SYMMETRIC.
#
# ΔE_ITP (BT.2408, colour-science verified verbatim): the Ct channel is
# HALF-SCALED before differencing (BT.2124), so the squared Ct term is
# (0.5·ΔCt)² = 0.25·ΔCt²; the 720 factor scales the result to ~1 perceptual
# unit for HDR/PQ content. ΔE_Jz is plain euclidean on JzAzBz.
import std/math
import UniColor/core/core

func compsF64(c: Color): (float64, float64, float64) {.inline.} =
  ## Read the three comps promoted to float64 (reference-space coords,
  ## caller-supplied).
  (c.comp(0).float64, c.comp(1).float64, c.comp(2).float64)

func deltaE_itp*(a, b: Color): float64 {.raises: [].} =
  ## ΔE_ITP — ICtCp perceptual difference for HDR (BT.2408 / colour-science).
  ## SYMMETRIC. `ΔE_ITP = 720·√(ΔI² + 0.25·ΔCt² + ΔCp²)` — Ct is half-scaled
  ## before differencing (BT.2124), giving the 0.25 weight; 720 scales to ~1
  ## perceptual unit (JND-aware for HDR/PQ). Reads `comp(0..2)` as I, Ct, Cp
  ## directly.
  let (i1, ct1, cp1) = compsF64(a)
  let (i2, ct2, cp2) = compsF64(b)
  let dI = i1 - i2
  let dCt = ct1 - ct2
  let dCp = cp1 - cp2
  720.0 * sqrt(dI * dI + 0.25 * dCt * dCt + dCp * dCp)

func deltaE_jz*(a, b: Color): float64 {.raises: [].} =
  ## ΔE_Jz — JzAzBz perceptual difference for HDR (Safdar 2017). SYMMETRIC.
  ## `ΔE_Jz = √(ΔJz² + ΔAz² + ΔBz²)` — plain euclidean on JzAzBz. Reads
  ## `comp(0..2)` as Jz, Az, Bz directly. An HDR alternative to ΔE_ITP.
  let (jz1, az1, bz1) = compsF64(a)
  let (jz2, az2, bz2) = compsF64(b)
  let dJz = jz1 - jz2
  let dAz = az1 - az2
  let dBz = bz1 - bz2
  sqrt(dJz * dJz + dAz * dAz + dBz * dBz)
