# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# cam16ucs — ΔE_CAM16-UCS (CAM16 uniform colour space, Li/Luo et al.).
#
# Reads `comp(0..2)` as the CAM16-UCS coords J', a', b' DIRECTLY — no hub
# conversion. The UCS *transform* (CAM16 J,C,h → J',a',b', with the KL/Ka/Kb
# UCS rescaling and the viewing-condition parameters L_A/Y_b/surround) is the
# SPACE's job (cam16.nim / the hub) — it is already applied when the CAM16-UCS
# color is built, so this metric is plain euclidean and takes NO
# viewing-condition arguments: the coords already encode them. SYMMETRIC.
# float64.
import std/math
import UniColor/core/core

func compsF64(c: Color): (float64, float64, float64) {.inline.} =
  ## Read the three comps promoted to float64 (CAM16-UCS J', a', b',
  ## caller-supplied).
  (c.comp(0).float64, c.comp(1).float64, c.comp(2).float64)

func deltaE_cam16Ucs*(a, b: Color): float64 {.raises: [].} =
  ## ΔE_CAM16-UCS — euclidean distance in the CAM16 uniform colour space
  ## (Li/Luo). SYMMETRIC. `ΔE = √(ΔJ'² + Δa'² + Δb'²)` on the UCS coords. The
  ## UCS transform and viewing conditions (L_A, Y_b, surround) are baked into
  ## the CAM16-UCS color itself (cam16.nim), so this primitive carries no
  ## view-param args. Reads `comp(0..2)` as J', a', b' directly.
  let (j1, a1, b1) = compsF64(a)
  let (j2, a2, b2) = compsF64(b)
  let dJ = j1 - j2
  let dA = a1 - a2
  let dB = b1 - b2
  sqrt(dJ * dJ + dA * dA + dB * dB)
