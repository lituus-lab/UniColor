# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# Vec[N,T] SIMD128 lane abstraction. Pins that every Vec op matches the scalar
# float op it stands in for, within 1e-15 (bit-identical under RNE + no-fast-math
# in release where the C compiler auto-vectorizes, and 2/4-way scalar in debug —
# same values either way). `Vec[4, float32]` and `Vec[2, float64]` (both 128-bit)
# are both exercised. The op ORDER is pinned (left-assoc `+`/`*`) so downstream
# batch procs stay within TOL_NUMERIC of their scalar reference.
import std/unittest
import std/math
import UniColor

const TOL = 1.0e-15

proc near(a, b: float64): bool = abs(a - b) <= TOL

suite "Vec[4, float32] ops == scalar":
  test "construct + lane access":
    let v = vec([1.0'f32, 2.0'f32, 3.0'f32, 4.0'f32])
    check v[0] == 1.0'f32
    check v[3] == 4.0'f32

  test "vset1 broadcast":
    let v = vset1[4, float32](0.5'f32)
    for i in 0 ..< 4:
      check v[i] == 0.5'f32

  test "add / sub / mul per lane":
    let x = vec([1.0'f32, 2.0'f32, 3.0'f32, 4.0'f32])
    let y = vec([10.0'f32, 20.0'f32, 30.0'f32, 40.0'f32])
    let s = x + y
    let d = y - x
    let p = x * y
    check s[0] == 11.0'f32 and s[1] == 22.0'f32 and s[2] == 33.0'f32 and s[3] == 44.0'f32
    check d[0] == 9.0'f32 and d[1] == 18.0'f32 and d[2] == 27.0'f32 and d[3] == 36.0'f32
    check p[0] == 10.0'f32 and p[1] == 40.0'f32 and p[2] == 90.0'f32 and p[3] == 160.0'f32

  test "vsqrt per lane == math.sqrt":
    let x = vec([0.0'f32, 1.0'f32, 4.0'f32, 9.0'f32])
    let r = vsqrt(x)
    for i in 0 ..< 4:
      check abs(float64(r[i]) - sqrt(float64(x[i]))) <= TOL

suite "Vec[2, float64] ops == scalar (ΔE_OK lane)":
  test "add / sub / mul per lane":
    let x = vec([1.5, 2.5])
    let y = vec([0.5, 1.5])
    let s = x + y
    let d = x - y
    let p = x * y
    check near(float64(s[0]), 2.0) and near(float64(s[1]), 4.0)
    check near(float64(d[0]), 1.0) and near(float64(d[1]), 1.0)
    check near(float64(p[0]), 0.75) and near(float64(p[1]), 3.75)

  test "vsqrt per lane == math.sqrt":
    let x = vec([2.0, 16.0])
    let r = vsqrt(x)
    check near(float64(r[0]), sqrt(2.0))
    check near(float64(r[1]), 4.0)

  test "left-assoc sum-of-squares matches scalar order":
    # d² = (dl² + da²) + db² — the ΔE_OK reduction order (bit-identical to
    # scalar left-assoc).
    let dl = vec([0.3, 1.0])
    let da = vec([0.4, 2.0])
    let db = vec([0.5, 3.0])
    let d2 = dl * dl + da * da + db * db
    let s0 = (0.3 * 0.3 + 0.4 * 0.4) + 0.5 * 0.5
    let s1 = (1.0 * 1.0 + 2.0 * 2.0) + 3.0 * 3.0
    check near(float64(d2[0]), s0)
    check near(float64(d2[1]), s1)
