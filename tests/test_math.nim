# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/math
import std/unittest
import UniColor

proc near(a, b: float64; tol = 1e-9): bool = abs(a - b) <= tol

suite "Mat3":
  test "identity, transpose, mul-by-identity":
    let id = identity3()
    check near(det3(id), 1.0)
    let m = [[4.0, 3.0, 0.0], [3.0, 2.0, 0.0], [0.0, 0.0, 1.0]]
    check transpose3(transpose3(m)) == m
    check mul3(m, id) == m
  test "apply3 is matrix·vector":
    let m = [[1.0, 0.0, 0.0], [0.0, 2.0, 0.0], [0.0, 0.0, 3.0]]
    let r = apply3(m, [1.0, 1.0, 1.0])
    check near(r[0], 1.0)
    check near(r[1], 2.0)
    check near(r[2], 3.0)
  test "det3 of a known matrix":
    check near(det3([[2.0, 0.0, 0.0], [0.0, 3.0, 0.0], [0.0, 0.0, 4.0]]), 24.0)
  test "inverse3 round-trips to identity":
    let m = [[4.0, 3.0, 0.0], [3.0, 2.0, 0.0], [0.0, 0.0, 1.0]] # det = -1
    let inv = inverse3(m)
    check inv.isOk
    let p = mul3(m, inv.get)
    for i in 0 ..< 3:
      for j in 0 ..< 3:
        check near(p[i][j], if i == j: 1.0 else: 0.0)
  test "inverse3 rejects a singular matrix":
    let m = [[1.0, 2.0, 3.0], [2.0, 4.0, 6.0], [1.0, 1.0, 1.0]] # row2 = 2*row1
    let inv = inverse3(m)
    check inv.isErr
    check inv.error.kind == NumericalError
  test "inverse3 rejects a NaN entry":
    let m = [[1.0, 2.0, 3.0], [NaN, 5.0, 6.0], [7.0, 8.0, 9.0]]
    check inverse3(m).isErr
  test "inverse3 rejects an Inf entry":
    let m = [[1.0, 2.0, 3.0], [Inf, 5.0, 6.0], [7.0, 8.0, 9.0]]
    check inverse3(m).isErr
    check inverse3(m).error.kind == NumericalError

suite "linalg":
  test "dot of orthogonal vectors is 0":
    check near(dot([1.0, 0.0, 0.0], [0.0, 1.0, 0.0]), 0.0)
  test "norm and normalize":
    check near(norm([3.0, 4.0, 0.0]), 5.0)
    let u = normalize([3.0, 4.0, 0.0])
    check near(norm(u), 1.0)
  test "normalize of zero stays zero (no NaN)":
    let z = normalize([0.0, 0.0, 0.0])
    check z == [0.0, 0.0, 0.0]
  test "lerp endpoints and midpoint":
    check near(lerp(0.0, 10.0, 0.0), 0.0)
    check near(lerp(0.0, 10.0, 1.0), 10.0)
    check near(lerp(0.0, 10.0, 0.5), 5.0)

suite "transfer — sRGB":
  test "endpoints":
    check near(srgbEotf(0.0), 0.0)
    check near(srgbEotf(1.0), 1.0)
    check near(srgbOetf(0.0), 0.0)
    check near(srgbOetf(1.0), 1.0)
  test "EOTF/OETF round-trip":
    for x in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]:
      check near(srgbOetf(srgbEotf(x)), x)

suite "transfer — gamma and linear":
  test "gamma round-trip":
    for x in [0.0, 0.2, 0.5, 1.0]:
      check near(gammaOetf(gammaEotf(x, 2.2), 2.2), x)
  test "linear is identity":
    check near(linearTransfer(0.42), 0.42)

suite "transfer — ProPhoto":
  test "endpoints and round-trip":
    check near(proPhotoEotf(0.0), 0.0)
    check near(proPhotoEotf(1.0), 1.0)
    for x in [0.0, 0.1, 0.5, 0.9, 1.0]:
      check near(proPhotoOetf(proPhotoEotf(x)), x)

suite "transfer — PQ BT.2100":
  test "endpoints":
    check near(pqEotf(0.0), 0.0, 1e-6)
    check near(pqEotf(1.0), 10000.0, 1e-6)
    check near(pqOetf(10000.0), 1.0, 1e-9)
  test "OETF/EOTF round-trip":
    for l in [0.0, 1.0, 100.0, 1000.0, 10000.0]:
      check near(pqEotf(pqOetf(l)), l, 1e-6)

suite "transfer — HLG BT.2100":
  test "endpoints":
    check near(hlgOetf(0.0), 0.0)
    # The rounded HLG constants (a/b/c to 8 decimals) give oetf/eotf(1.0) ≈
    # 0.9999, not exactly 1.0; the round-trip below is tight (errors cancel).
    check near(hlgOetf(1.0), 1.0, 1e-4)
    check near(hlgEotf(1.0), 1.0, 1e-4)
  test "round-trip":
    for x in [0.0, 0.1, 0.5, 0.9, 1.0]:
      check near(hlgEotf(hlgOetf(x)), x, 1e-9)

suite "transfer — JzAzBz quantizer":
  test "endpoints map [0,1] -> [0,1]":
    check near(pqOetfJz(0.0), 0.0, 1e-6)
    check near(pqOetfJz(1.0), 1.0, 1e-9)
    check near(pqEotfJz(0.0), 0.0, 1e-9)
    check near(pqEotfJz(1.0), 1.0, 1e-9)
  test "round-trip":
    for x in [0.0, 0.1, 0.5, 0.9, 1.0]:
      check near(pqEotfJz(pqOetfJz(x)), x, 1e-6)

suite "whitepoint — Bradford":
  test "adapt(D65 -> D50) reproduces wpD50 (Lindbloom golden)":
    let r = adapt(wpD65, wpD65, wpD50)
    check near(r[0], 0.964296, 1e-6)
    check near(r[1], 1.000000, 1e-6)
    check near(r[2], 0.825105, 1e-6)
  test "identity adaptation (src == dst) is a no-op":
    let xyz = [0.5, 0.6, 0.7]
    let r = adapt(xyz, wpD65, wpD65)
    # bradfordMInv * bradfordM ≈ I only to ~1e-7 (Lindbloom's inverse is rounded
    # to 7 decimals), so the no-op holds at single-precision tolerance.
    check near(r[0], 0.5, 1e-6)
    check near(r[1], 0.6, 1e-6)
    check near(r[2], 0.7, 1e-6)

suite "rng — determinism":
  test "SplitMix64: same seed -> same sequence":
    var a = initSplitMix64(0)
    var b = initSplitMix64(0)
    for _ in 0 ..< 5:
      check a.next() == b.next()
  test "SplitMix64: different seeds diverge":
    var a = initSplitMix64(0)
    var c = initSplitMix64(1)
    check a.next() != c.next()
  test "SplitMix64 nextFloat in [0,1)":
    var r = initSplitMix64(42)
    for _ in 0 ..< 100:
      let f = r.nextFloat()
      check f >= 0.0 and f < 1.0
  test "Pcg32: same seed -> same sequence":
    var a = initPcg32(0)
    var b = initPcg32(0)
    for _ in 0 ..< 5:
      check a.next() == b.next()
  test "Pcg32: different seeds diverge":
    var a = initPcg32(0)
    var c = initPcg32(1)
    check a.next() != c.next()
  test "Pcg32 nextFloat in [0,1)":
    var r = initPcg32(42)
    for _ in 0 ..< 100:
      let f = r.nextFloat()
      check f >= 0.0 and f < 1.0
