# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# rng — deterministic seeded RNG for reproducible palette/theme generation.
# SplitMix64 (Steele, Allen, Lea 2014;
# https://www.pcg-random.org/posts/splitmix-floats.html) seeds and derives
# streams; PCG32 (O'Neill 2014; https://www.pcg-random.org) is the statistical-
# quality generator used for the actual draws. Both are seeded and deterministic:
# the same seed yields the same sequence, and `seed = 0` is the canonical
# reference seed. No Math.random / Date.now — all randomness derives from `seed`.
# PCG32 is re-implemented here from O'Neill's published algorithm (Apache-2.0 /
# MIT); attribution kept, no code copied.

const
  # SplitMix64: the golden-ratio increment and two MurmurHash3 mixers.
  SmGamma* = 0x9E3779B97F4A7C15'u64
  SmM1* = 0xBF58476D1CE4E5B9'u64
  SmM2* = 0x94D049BB133111EB'u64
  # PCG32 (setseq): LCG multiplier (the increment is set odd at construction).
  PcgMult* = 0x5851F42D4C957F2D'u64

type
  SplitMix64* = object
    ## 64-bit bijective mixing generator. `state` advances by the golden-ratio
    ## increment on every draw; the output is a MurmurHash3-style mix of the new
    ## state. Cheap, jumpable, the canonical way to seed PCG.
    state: uint64

  Pcg32* = object
    ## PCG32 (setseq): a 32-bit-output generator — an LCG on a 64-bit state
    ## followed by a permutation (xorshift + rotate). `inc` must be odd.
    state: uint64
    inc: uint64

proc initSplitMix64*(seed: uint64): SplitMix64 {.raises: [].} =
  ## Seed a SplitMix64. `seed = 0` is the canonical reference. The first draw
  ## advances by the golden-ratio increment, so seed = 0 still yields a
  ## non-trivial stream.
  SplitMix64(state: seed)

proc next*(r: var SplitMix64): uint64 {.raises: [].} =
  ## Advance the state and return the next 64-bit value.
  r.state += SmGamma
  var z = r.state
  z = (z xor (z shr 30)) * SmM1
  z = (z xor (z shr 27)) * SmM2
  z = z xor (z shr 31)
  z

proc nextFloat*(r: var SplitMix64): float64 {.raises: [].} =
  ## Uniform float in [0,1) with 53 bits of precision (top 53 bits / 2^53).
  (r.next() shr 11).float64 * (1.0 / 9007199254740992.0)

proc initPcg32*(seed: uint64, stream = 0'u64): Pcg32 {.raises: [].} =
  ## Seed a PCG32 (setseq). `inc = (stream << 1) | 1` (must be odd); the state is
  ## warmed up with two LCG steps interleaved with the seed (O'Neill's
  ## pcg32_sinit). `seed = 0` is the canonical reference.
  result.inc = (stream shl 1) or 1'u64
  result.state = 0'u64
  result.state = result.state * PcgMult + result.inc
  result.state = result.state + seed
  result.state = result.state * PcgMult + result.inc

proc next*(r: var Pcg32): uint32 {.raises: [].} =
  ## Advance the state and return the next 32-bit value. The xorshifted value is
  ## truncated to uint32 BEFORE the rotation: `((oldstate>>18)^oldstate)>>27` is
  ## 37 bits, and rotating the 37-bit value would let the upper 5 bits leak into
  ## the low 32 via the OR. The standard PCG casts to uint32 first, then rotates
  ## within 32 bits.
  let oldstate = r.state
  r.state = oldstate * PcgMult + r.inc
  let xs = uint32(((oldstate shr 18) xor oldstate) shr 27)
  let rot = uint32((oldstate shr 59) and 31'u64)
  let rotInv = (32'u32 - rot) and 31'u32
  (xs shr rot) or (xs shl rotInv)

proc nextFloat*(r: var Pcg32): float64 {.raises: [].} =
  ## Uniform float in [0,1) — 32 bits / 2^32 (full uint32 range).
  r.next().float64 / 4294967296.0
