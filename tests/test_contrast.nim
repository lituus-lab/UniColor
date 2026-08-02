# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import UniColor

proc near(a, b: float64, tol = 1.0e-3): bool = abs(a - b) <= tol

test "contrast module compiles and is reachable":
  check contrastModule == "1.0.0"

suite "deltaE metrics":
  test "identical colors are zero distance":
    let a = color(tagOklab, 0.5'f32, 0.1'f32, 0.05'f32).get
    check near(deltaE_ok(a, a), 0.0)
    let lab = color(tagLab, 50.0'f32, 2.0'f32, -10.0'f32).get
    check near(deltaE76(lab, lab), 0.0)
    check near(deltaE2000(lab, lab), 0.0)
  test "distinct colors are positive":
    let a = color(tagOklab, 0.5'f32, 0.1'f32, 0.05'f32).get
    let b = color(tagOklab, 0.5'f32, -0.1'f32, -0.05'f32).get
    check deltaE_ok(a, b) > 0.0
  test "deltaE2000 Sharma reference pair":
    # Sharma 2005 test pair: ΔE00 = 2.0425.
    let a = color(tagLab, 50.0'f32, 2.6772'f32, -79.7751'f32).get
    let b = color(tagLab, 50.0'f32, 0.0'f32, -82.748'f32).get
    check near(deltaE2000(a, b), 2.0425, 5.0e-3)

suite "WCAG contrast":
  test "black/white is 21:1":
    let k = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let w = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    check near(contrastRatio(k, w).get, 21.0, 5.0e-2)
  test "identical colors are 1:1":
    let c = color(tagSrgb, 0.3'f32, 0.4'f32, 0.5'f32).get
    check near(contrastRatio(c, c).get, 1.0, 1.0e-6)

suite "APCA":
  test "dark text on light bg is positive (BoW)":
    let k = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let w = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    check apcaContrast(k, w).get > 100.0
  test "light text on dark bg is negative (WoB)":
    let k = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let w = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    check apcaContrast(w, k).get < -100.0

suite "registry dispatch":
  test "distance dispatches by name":
    let a = color(tagOklab, 0.5'f32, 0.1'f32, 0.05'f32).get
    let b = color(tagOklab, 0.5'f32, -0.1'f32, -0.05'f32).get
    check near(distance(a, b, "deltaE_ok").get, deltaE_ok(a, b), 1.0e-9)
  test "unknown metric is an error":
    let a = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    check distance(a, b, "nope").error.kind == UnknownMetric
  test "default contrast metric is wcag22":
    let k = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let w = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    check near(contrast(k, w).get, contrastRatio(k, w).get, 1.0e-9)
    check contrastMetricCount() >= 3
    check distanceMetricCount() >= 8

suite "deltaEOkBatch":
  test "batch matches scalar per pair":
    let a = @[color(tagOklab, 0.5'f32, 0.1'f32, 0.0'f32).get,
              color(tagOklab, 0.6'f32, -0.1'f32, 0.05'f32).get,
              color(tagOklab, 0.4'f32, 0.2'f32, -0.1'f32).get,
              color(tagOklab, 0.7'f32, 0.0'f32, 0.1'f32).get]
    let b = @[color(tagOklab, 0.5'f32, -0.1'f32, 0.0'f32).get,
              color(tagOklab, 0.6'f32, 0.1'f32, -0.05'f32).get,
              color(tagOklab, 0.4'f32, -0.2'f32, 0.1'f32).get,
              color(tagOklab, 0.7'f32, 0.0'f32, -0.1'f32).get]
    let r = deltaEOkBatch(a, b).get
    check r.len == 4
    for i in 0 ..< a.len:
      check near(r[i], deltaE_ok(a[i], b[i]), 1.0e-9)
  test "length mismatch is InvalidOp":
    let a = @[color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get]
    let b = @[color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get,
              color(tagSrgb, 0.5'f32, 0.5'f32, 0.5'f32).get]
    check deltaEOkBatch(a, b).error.kind == InvalidOp
