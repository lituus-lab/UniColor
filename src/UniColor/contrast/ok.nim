# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# ok — ΔE_OK (Ottosson 2020, OKLab euclidean).
#
# Reads `comp(0..2)` as OKLab L,a,b DIRECTLY — no hub conversion. The metric is
# pure euclidean on OKLab coords (white-point independent in the OKLab sense);
# the dispatched `distance(a, b, "deltaE_ok")` API handles conversion for
# arbitrary colors through the hub. The caller hands in OKLab colors
# (`color(tagOklab, ...)`); a non-OKLab Color is read as OKLab anyway (no
# speculative tag validation). SYMMETRIC. Compute is float64. JND ≈ 0.02.
import std/math
import UniColor/core/core

func okComps(c: Color): (float64, float64, float64) {.inline.} =
  ## Read the three comps as OKLab L,a,b promoted to float64.
  (c.comp(0).float64, c.comp(1).float64, c.comp(2).float64)

func deltaE_ok*(a, b: Color): float64 {.raises: [].} =
  ## ΔE_OK — euclidean distance in OKLab (Ottosson 2020). SYMMETRIC.
  ## `ΔE_OK = √((L₁−L₂)² + (a₁−a₂)² + (b₁−b₂)²)`. JND ≈ 0.02; the modern
  ## reference for gamut mapping (CSS Color 4). No pathological cases — OKLab
  ## has no hue wrap before polarisation, so (unlike ΔE2000/CMC) there is no
  ## achromatic edge case and no rotation term.
  let (l1, a1, b1) = okComps(a)
  let (l2, a2, b2) = okComps(b)
  sqrt((l1 - l2)^2 + (a1 - a2)^2 + (b1 - b2)^2)
