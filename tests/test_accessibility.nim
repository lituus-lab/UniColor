# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/options
import std/math # `Inf`.
import std/unittest
import UniColor

let white = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
let black = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
let red = color(tagSrgb, 1.0'f32, 0.0'f32, 0.0'f32).get
let greenHalf = color(tagSrgb, 0.0'f32, 0.5'f32, 0.0'f32).get

const cvdMargin = 0.1'f64 ## CVD safety-margin threshold: red and a dark green
                          ## stay above the raw JND (0.02) but collapse within 0.1 ΔE_OK under
                          ## protanopia — a realistic margin for flagging CVD-confusable pairs.

test "accessibility module compiles and is reachable":
  check accessibilityModule == "0.1.0"

suite "cvd simulation":
  test "simulateCvd default model returns a color":
    let r = simulateCvd(red, cvdProtanopia, 1.0)
    check r.isOk
    check r.get.spaceTag() == red.spaceTag()
  test "simulateCvd rejects out-of-range severity":
    let r = simulateCvd(red, cvdProtanopia, 1.5)
    check r.error.kind == InvalidColor
  test "simulateCvd rejects unknown model":
    let r = simulateCvd(red, "nope", cvdProtanopia, 1.0)
    check r.error.kind == UnknownCvdModel
  test "cvdReport flags a red/green confusable pair under protanopia":
    let rep = cvdReport([red, greenHalf], DefaultCvdModel, cvdProtanopia, 1.0,
        cvdMargin)
    check rep.simulated.len == 2
    check rep.pairs.len >= 1
  test "cvdReport on a single color has no pairs":
    let rep = cvdReport([red], DefaultCvdModel, cvdProtanopia, 1.0, TOL_JND)
    check rep.pairs.len == 0

suite "role/size metrics":
  test "contrastForRole black-on-white text.primary passes AA":
    let v = contrastForRole(black, white, roleTextPrimary)
    check v.isOk
    check v.get.pass
    check v.get.value > 4.5
  test "contrastForRole rejects signed-Lc metric":
    let v = contrastForRole(black, white, roleTextPrimary, "apca")
    check v.error.kind == InvalidOp
  test "contrastForSize rejects wcag22 ratio":
    let v = contrastForSize(black, white, sizeNormal, "wcag22")
    check v.error.kind == UnknownMetric

suite "correction primitives":
  test "shiftHue moves hue and never warns":
    let r = shiftHue(red, 30.0)
    check r.isOk
    check r.get.warning.len == 0
  test "compressChroma rejects factor outside [0,1]":
    let r = compressChroma(red, 1.5)
    check r.error.kind == InvalidColor
  test "correct rejects unknown algorithm":
    let r = correct(red, "nope", CorrectionOpts())
    check r.error.kind == UnknownAlgorithm

suite "cvd-safe registry + audit":
  test "okabeIto is registered and 8 colors":
    let p = safePalette("okabeIto", 8)
    check p.isOk
    check p.get.len == 8
  test "okabeIto is CVD-safe across the three dichromacies":
    check isCvdSafe(safePalette("okabeIto", 8).get.colors)
  test "red/dark-green are NOT CVD-safe at a safety margin":
    check not isCvdSafe([red, greenHalf], threshold = cvdMargin)
  test "auditSafeColors reports the confusable pair":
    let a = auditSafeColors([red, greenHalf], threshold = cvdMargin)
    check not a.safe
    check a.minDeltaE < cvdMargin
  test "unknown safe palette name":
    let p = safePalette("nope", 4)
    check p.error.kind == UnknownAlgorithm

suite "dynamic adjustForContrast":
  test "lift a dark fg to WCAG AA on white":
    let dark = color(tagSrgb, 0.10'f32, 0.10'f32, 0.10'f32).get
    let r = adjustForContrast(dark, white, 4.5)
    check r.isOk
    check r.get.met
    check r.get.finalContrast >= 4.5
  test "unreachable threshold returns met=false + warning":
    let r = adjustForContrast(black, white, 100.0)
    check r.isOk
    check not r.get.met
    check r.get.warning.len != 0
  test "non-positive stepSize is InvalidColor":
    let opts = AdjustOpts(direction: adAuto, stepSize: 0.0)
    let r = adjustForContrast(black, white, 4.5, "wcag22", opts)
    check r.error.kind == InvalidColor

suite "cvdSafe constraint":
  test "okabeIto satisfies cvdSafe":
    let cs = [cvdSafe()]
    let rep = checkConstraints(safePalette("okabeIto", 8).get.colors, cs)
    check rep.satisfied
  test "red/dark-green violate cvdSafe at a safety margin":
    let rep = checkConstraints([red, greenHalf], [cvdSafe(
        threshold = cvdMargin)])
    check not rep.satisfied
    check rep.results[0].violation > 0.0

suite "pairless palettes (Inf margin)":
  # Regression: a single-color (or empty) palette has no confusable pairs, so it
  # is vacuously CVD-safe — `minDeltaE` is `Inf` (not 0.0) so `cvdSafe` does not
  # flag it as a violation (threshold - Inf = 0 <= EPS).
  test "single color audits safe with Inf margin":
    let a = auditSafeColors([red])
    check a.safe
    check a.minDeltaE == Inf
  test "single color satisfies cvdSafe":
    let rep = checkConstraints([red], [cvdSafe()])
    check rep.satisfied
    check rep.results[0].violation <= 1.0e-12
