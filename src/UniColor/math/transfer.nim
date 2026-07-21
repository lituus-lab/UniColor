# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# transfer — color space transfer functions. Pure float64; NaN propagated.
#   sRGB (IEC 61966-2-1), simple gamma, linear, ProPhoto/ROMM (ISO 22028-2),
#   PQ BT.2100 (SMPTE ST 2084), HLG BT.2100, and the JzAzBz perceptual
#   quantizer (Safdar 2017, re-optimized ST 2084).

import std/math

# --- sRGB (IEC 61966-2-1) ------------------------------------------------------

const
  SrgbThreshold* = 0.04045
  SrgbLinearSlope* = 12.92
  SrgbAlpha* = 1.055
  SrgbBeta* = 0.055
  SrgbGamma* = 2.4
  SrgbInvThreshold* = 0.0031308 # = 0.04045 / 12.92

func srgbEotf*(c: float64): float64 {.inline, raises: [].} =
  ## sRGB EOTF (encoded -> linear). c ∈ [0,1] -> [0,1]. NaN propagated.
  if c <= SrgbThreshold:
    c / SrgbLinearSlope
  else:
    pow((c + SrgbBeta) / SrgbAlpha, SrgbGamma)

func srgbOetf*(c: float64): float64 {.inline, raises: [].} =
  ## sRGB OETF (linear -> encoded). Inverse of `srgbEotf`. NaN propagated.
  if c <= SrgbInvThreshold:
    c * SrgbLinearSlope
  else:
    SrgbAlpha * pow(c, 1.0 / SrgbGamma) - SrgbBeta

# --- Simple gamma (e.g. Adobe RGB 2.2) ----------------------------------------

func gammaEotf*(c, gamma: float64): float64 {.inline, raises: [].} =
  ## Gamma EOTF: c^gamma. A negative base yields NaN (propagated).
  pow(c, gamma)

func gammaOetf*(c, gamma: float64): float64 {.inline, raises: [].} =
  ## Gamma OETF: c^(1/gamma). Inverse of `gammaEotf`.
  pow(c, 1.0 / gamma)

func linearTransfer*(c: float64): float64 {.inline, raises: [].} =
  ## Identity transfer (linear spaces). NaN propagated.
  c

# --- ProPhoto RGB / ROMM (ISO 22028-2) ----------------------------------------

const
  ProPhotoThreshold* = 1.0 / 32.0 # EOTF toe: enc <= 0.03125 -> lin = enc/16
  ProPhotoLinearSlope* = 1.0 / 16.0
  ProPhotoInvThreshold* = 1.0 / 512.0 # OETF toe: lin <= 0.001953125 -> enc = 16*lin
  ProPhotoOetfSlope* = 16.0
  ProPhotoGamma* = 1.8

func proPhotoEotf*(c: float64): float64 {.inline, raises: [].} =
  ## ProPhoto (ROMM) EOTF (encoded -> linear). Toe: enc <= 1/32 -> enc/16, else
  ## enc^1.8. The 1/32 junction is where enc^1.8 = enc/16 (ISO 22028-2). Negatives
  ## fall through the toe (preserved).
  if c <= ProPhotoThreshold:
    c * ProPhotoLinearSlope
  else:
    pow(c, ProPhotoGamma)

func proPhotoOetf*(c: float64): float64 {.inline, raises: [].} =
  ## ProPhoto (ROMM) OETF (linear -> encoded), inverse of `proPhotoEotf`.
  if c <= ProPhotoInvThreshold:
    c * ProPhotoOetfSlope
  else:
    pow(c, 1.0 / ProPhotoGamma)

# --- PQ BT.2100 (SMPTE ST 2084, peak 10000 cd/m²) -----------------------------

const
  PqM1* = 0.1593017578125
  PqM2* = 78.84375
  PqC1* = 0.8359375
  PqC2* = 18.8515625
  PqC3* = 18.6875
  PqPeakNits* = 10000.0

func pqOetf*(l: float64): float64 {.inline, raises: [].} =
  ## PQ OETF (linear luminance cd/m² -> encoded [0,1]). l=0 -> 0, l=10000 -> 1.
  let f = l / PqPeakNits
  pow((PqC1 + PqC2 * pow(f, PqM1)) / (1.0 + PqC3 * pow(f, PqM1)), PqM2)

func pqEotf*(v: float64): float64 {.inline, raises: [].} =
  ## PQ EOTF (encoded [0,1] -> linear luminance cd/m²). v=0 -> 0, v=1 -> 10000.
  ## Exponent 1/m1 on the ratio (ST 2084): with Q = L^m1 from the OETF,
  ## Q^(1/m1) = L, giving exact invertibility.
  let em = pow(v, 1.0 / PqM2)
  let num = max(em - PqC1, 0.0)
  PqPeakNits * pow(num / (PqC2 - PqC3 * em), 1.0 / PqM1)

# --- JzAzBz perceptual quantizer (Safdar 2017) --------------------------------
# Same ST 2084 form as PQ with m2 = 1.7*2523/2^5 = 133.4034375, re-optimized for
# JzAzBz. The input is a normalized cone response in [0,1] (1 = 10000 cd/m²
# peak) — passed directly, NOT scaled by PqPeakNits, so both functions map
# [0,1] -> [0,1]. c1 + c2 = 1 + c3 (exact dyadic) pins the 1.0 endpoint.
const JzM2* = 1.7 * 2523.0 / 32.0 # 133.4034375

func pqOetfJz*(l: float64): float64 {.inline, raises: [].} =
  ## JzAzBz perceptual quantizer OETF (normalized cone response [0,1] -> encoded
  ## [0,1], 1 = 10000 cd/m² peak). l=0 -> 0, l=1 -> 1. NaN propagated.
  pow((PqC1 + PqC2 * pow(l, PqM1)) / (1.0 + PqC3 * pow(l, PqM1)), JzM2)

func pqEotfJz*(v: float64): float64 {.inline, raises: [].} =
  ## JzAzBz perceptual quantizer EOTF, inverse of `pqOetfJz` ([0,1] -> [0,1]).
  ## v=0 -> 0, v=1 -> 1.
  let em = pow(v, 1.0 / JzM2)
  let num = max(em - PqC1, 0.0)
  pow(num / (PqC2 - PqC3 * em), 1.0 / PqM1)

# --- HLG BT.2100 (scene linear) -----------------------------------------------

const
  HlgA* = 0.17883277
  HlgB* = 0.28466892
  HlgC* = 0.55991073
  HlgKnee* = 1.0 / 12.0 # OETF threshold (linear)
  HlgKneeEnc* = 0.5     # inverse EOTF threshold (encoded)

func hlgOetf*(l: float64): float64 {.inline, raises: [].} =
  ## HLG OETF (scene linear [0,1] -> encoded [0,1]). l=0 -> 0, l=1 -> 1.
  if l <= HlgKnee:
    sqrt(3.0 * l)
  else:
    HlgA * ln(12.0 * l - HlgB) + HlgC

func hlgEotf*(v: float64): float64 {.inline, raises: [].} =
  ## HLG EOTF inverse-OETF (encoded [0,1] -> scene linear [0,1]).
  if v <= HlgKneeEnc:
    (v * v) / 3.0
  else:
    (exp((v - HlgC) / HlgA) + HlgB) / 12.0
