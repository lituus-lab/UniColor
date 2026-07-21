# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# simd — portable SIMD128 lane abstraction.
# `Vec[N, T]` is a fixed N-lane float vector: `Vec[4, float32]` = 128-bit f32x4,
# `Vec[2, float64]` = 128-bit f64x2. Ops are plain Nim over `array[N, T]` written
# as straight-line fixed-N loops, so the C compiler emits SIMD128 at -O3
# (release / `--opt:speed`) and N-way scalar in debug.
#
# BIT-IDENTICAL under frozen RNE + no-fast-math: IEEE754 add/mul/sqrt are
# correctly-rounded on BOTH the scalar FPU and the SIMD unit, so the result does
# NOT depend on whether the compiler vectorized — only the op ORDER matters, and
# it is pinned to match the scalar procs (left-assoc `+`, explicit `*`). No FMA
# contraction (needs `-ffast-math` / `-ffp-contract=fast`, both OFF). No
# hand-written intrinsics → portable across x86 (SSE/AVX), ARM (NEON) and WASM.
# Determinism contract: SIMD batch procs stay within TOL_NUMERIC of the scalar
# reference (same op order as the scalar procs).
#
# Why Vec[2, float64] (not f32x4) for ΔE_OK: the scalar `deltaE_ok` promotes
# comps to float64 and computes in float64. A float32 SIMD lane would accumulate
# ~1e-7 relative error and violate TOL_NUMERIC for small distances. float64
# SIMD128 is 2-wide (128/64) but matches the scalar precision bit-for-bit.

import std/math

type
  Vec*[N: static int, T: SomeFloat] = object
    ## Fixed N-lane float vector. `Vec[4, float32]` and `Vec[2, float64]` both
    ## occupy 128 bits.
    data*: array[N, T]

func `[]`*[N: static int, T: SomeFloat](x: Vec[N, T], i: range[0 .. N - 1]): T {.
    inline, raises: [].} =
  ## Lane access (bounds-pinned to `0 .. N-1`).
  x.data[i]

func vec*[N: static int, T: SomeFloat](xs: array[N, T]): Vec[N, T] {.inline,
    raises: [].} =
  ## Construct from a fixed-size array literal — e.g. `vec([a, b])` infers
  ## `Vec[2, float64]`.
  result.data = xs

func vset1*[N: static int, T: SomeFloat](s: T): Vec[N, T] {.inline, raises: [].} =
  ## Broadcast a scalar to all N lanes.
  for i in 0 ..< N:
    result.data[i] = s

func `+`*[N: static int, T: SomeFloat](x, y: Vec[N, T]): Vec[N, T] {.inline,
    raises: [].} =
  ## Per-lane add (correctly rounded, RNE).
  for i in 0 ..< N:
    result.data[i] = x.data[i] + y.data[i]

func `-`*[N: static int, T: SomeFloat](x, y: Vec[N, T]): Vec[N, T] {.inline,
    raises: [].} =
  ## Per-lane subtract (correctly rounded, RNE).
  for i in 0 ..< N:
    result.data[i] = x.data[i] - y.data[i]

func `*`*[N: static int, T: SomeFloat](x, y: Vec[N, T]): Vec[N, T] {.inline,
    raises: [].} =
  ## Per-lane multiply (correctly rounded, RNE — NOT fused into an FMA without
  ## -ffast-math).
  for i in 0 ..< N:
    result.data[i] = x.data[i] * y.data[i]

func vsqrt*[N: static int, T: SomeFloat](x: Vec[N, T]): Vec[N, T] {.inline,
    raises: [].} =
  ## Per-lane correctly-rounded sqrt (IEEE — bit-identical to `math.sqrt` per lane).
  for i in 0 ..< N:
    result.data[i] = sqrt(x.data[i])
