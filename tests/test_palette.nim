# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/math
import std/options
import std/tables
import std/unittest
import UniColor

proc near(a, b: float64, tol = 1.0e-2): bool = abs(a - b) <= tol

let baseOklch = color(tagOklch, 0.6'f32, 0.15'f32, 250.0'f32).get

test "palette module compiles and is reachable":
  check paletteModule == "1.0.0"

suite "palette ctor and indexing":
  test "empty colors is InvalidOp":
    let r = palette(palUnordered, @[], intentQualitative, 0)
    check r.error.kind == InvalidOp
  test "accessors and discrete colorAt":
    let a = color(tagSrgb, 0.8'f32, 0.2'f32, 0.2'f32).get
    let b = color(tagSrgb, 0.2'f32, 0.4'f32, 0.8'f32).get
    let p = palette(palUnordered, [a, b], intentQualitative, 42).get
    check p.len == 2
    check p.tag == palUnordered
    check p.intent == intentQualitative
    check p.seed == 42
    check p.colors().len == 2
    check colorAt(p, 0).get == a
    check colorAt(p, 1).get == b
    check colorAt(p, 2).error.kind == InvalidColor
  test "colorAt on Continuous is InvalidOp":
    let a = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    let p = palette(palContinuous, [a, b], intentSequential, 0).get
    check colorAt(p, 0).error.kind == InvalidOp
  test "sample on ordered ramp hits the first stop":
    let a = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    let p = palette(palOrdered, [a, b], intentSequential, 0).get
    let s = sample(p, 0.0).get
    check s.spaceTag == tagOklch # default GradientOpts space.
    let aOk = a.to(tagOklch).get
    for i in 0 ..< 3:
      check near(s.comp(i).float64, aOk.comp(i).float64)
  test "sample on unordered is InvalidOp":
    let a = color(tagSrgb, 0.8'f32, 0.2'f32, 0.2'f32).get
    let p = palette(palUnordered, [a], intentQualitative, 0).get
    check sample(p, 0.5).error.kind == InvalidOp
  test "sample out of [0,1] is InvalidColor":
    let a = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    let p = palette(palOrdered, [a, b], intentSequential, 0).get
    check sample(p, 1.5).error.kind == InvalidColor
  test "role access on Semantic":
    var roles = initTable[string, int]()
    roles["fg"] = 0
    roles["bg"] = 1
    let fg = color(tagSrgb, 0.1'f32, 0.1'f32, 0.1'f32).get
    let bg = color(tagSrgb, 0.9'f32, 0.9'f32, 0.9'f32).get
    let p = palette(palSemantic, [fg, bg], intentUI, 0, roles).get
    check role(p, "fg").get == fg
    check role(p, "bg").get == bg
    check role(p, "nope").error.kind == InvalidColor
  test "role on non-Semantic is InvalidOp":
    let a = color(tagSrgb, 0.1'f32, 0.1'f32, 0.1'f32).get
    let p = palette(palUnordered, [a], intentQualitative, 0).get
    check role(p, "fg").error.kind == InvalidOp
  test "Semantic role out of range is InvalidColor":
    var roles = initTable[string, int]()
    roles["x"] = 5
    let a = color(tagSrgb, 0.1'f32, 0.1'f32, 0.1'f32).get
    check palette(palSemantic, [a], intentUI, 0, roles).error.kind == InvalidColor

suite "direct generators":
  test "goldenAngle length and structure":
    let g = goldenAngle(baseOklch, 5, 0.65, 0.16).get
    check g.len == 5
    check g.tag == palUnordered
    check g.intent == intentQualitative
    check g.seed == 0
  test "goldenAngle n < 1 is InvalidColor":
    check goldenAngle(baseOklch, 0, 0.65, 0.16).error.kind == InvalidColor
  test "goldenAngle lightness out of range is InvalidColor":
    check goldenAngle(baseOklch, 3, 1.5, 0.16).error.kind == InvalidColor
  test "complementary harmony is base + opposite":
    let c = complement(baseOklch).get
    check c.len == 2
    check c.tag == palUnordered
    let b0 = baseOklch.to(tagOklch).get
    check near(c.colors()[0].comp(0).float64, b0.comp(0).float64)
  test "harmony counts":
    check triadic(baseOklch).get.len == 3
    check analogous(baseOklch).get.len == 3
    check splitComplement(baseOklch).get.len == 3
    check tetradic(baseOklch).get.len == 4
  test "HSL complementary harmony":
    let c = complementHsl(baseOklch).get
    check c.len == 2
    check c.colors()[0].spaceTag == tagHsl

suite "safe palettes":
  test "okabeIto is the 8-color reference":
    let p = okabeIto()
    check p.len == 8
    check p.tag == palUnordered
    check p.intent == intentQualitative
  test "viridis ramp length and structure":
    let p = viridis(10).get
    check p.len == 10
    check p.tag == palScientific
    check p.intent == intentScientific
  test "viridis n < 1 is InvalidOp":
    check viridis(0).error.kind == InvalidOp
  test "colorBrewer Set1":
    let p = colorBrewer("Set1", 5).get
    check p.len == 5
  test "colorBrewer Set1 over max is InvalidOp":
    check colorBrewer("Set1", 20).error.kind == InvalidOp
  test "colorBrewer unknown name is InvalidOp":
    check colorBrewer("Nope", 3).error.kind == InvalidOp

suite "k-means":
  test "three identical clusters resolve to k centroids":
    # Three tight groups (each color repeated) -> k=3 recovers them.
    let g1 = color(tagOklab, 0.5'f32, 0.0'f32, 0.0'f32).get
    let g2 = color(tagOklab, 0.7'f32, 0.2'f32, 0.0'f32).get
    let g3 = color(tagOklab, 0.6'f32, -0.2'f32, 0.0'f32).get
    var pts: seq[Color] = @[]
    for c in [g1, g2, g3]:
      for _ in 0 ..< 8:
        pts.add(c)
    let r = kmeans(pts, defaultKmeansOpts(3)).get
    check r.palette.len == 3
    check sum(r.sizes) == pts.len
    check r.energy >= 0.0
    check r.iterations >= 1
  test "empty points is InvalidColor":
    let pts: seq[Color] = @[]
    check kmeans(pts, defaultKmeansOpts(3)).error.kind == InvalidColor
  test "k < 1 is InvalidColor":
    let a = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    check kmeans([a], defaultKmeansOpts(0)).error.kind == InvalidColor
  test "k larger than points is InvalidColor":
    let a = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    check kmeans([a], defaultKmeansOpts(3)).error.kind == InvalidColor
  test "quantize dispatches by name":
    let a = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    let r = quantize([a, b], defaultKmeansOpts(2), "kmeans").get
    check r.palette.len == 2
  test "quantize unknown algorithm is UnknownAlgorithm":
    let a = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    check quantize([a], defaultKmeansOpts(1), "nope").error.kind == UnknownAlgorithm
  test "registry has the built-in kmeans":
    check kmeansAlgoCount() >= 1
    check lookupKmeansAlgo("kmeans").isSome

suite "optimizers":
  test "dispersionPenalty is zero for identical colors":
    let a = color(tagOklab, 0.5'f32, 0.1'f32, 0.0'f32).get
    check near(dispersionPenalty([a, a]), 0.0, 1.0e-9)
  test "annealing produces an n-color palette":
    let r = optimize(baseOklch, dispersionPenalty,
        defaultOpts(optimAnnealing, 3), "annealing").get
    check r.palette.len == 3
  test "genetic produces an n-color palette":
    let r = optimize(baseOklch, dispersionPenalty,
        defaultOpts(optimGenetic, 3), "genetic").get
    check r.palette.len == 3
  test "optimize unknown algorithm is UnknownAlgorithm":
    check optimize(baseOklch, dispersionPenalty, defaultOpts(optimAnnealing, 3),
        "nope").error.kind == UnknownAlgorithm
  test "registry has both optimizers":
    check optimAlgoCount() >= 2

suite "constraints":
  test "minDeltaEOK satisfied for far colors":
    let a = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    let cs = checkConstraints([a, b], [minDeltaEOK(0.5)])
    check cs.satisfied
    check totalViolation([minDeltaEOK(0.5)], [a, b]) == 0.0
  test "minDeltaEOK violated for identical colors":
    let a = color(tagOklab, 0.5'f32, 0.1'f32, 0.0'f32).get
    let cs = checkConstraints([a, a], [minDeltaEOK(0.5)])
    check not cs.satisfied
    check totalViolation([minDeltaEOK(0.5)], [a, a]) > 0.0

suite "satisfy / requireSatisfied":
  test "satisfy reports satisfied with no warnings":
    let a = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
    let b = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
    let pal = palette(palUnordered, [a, b], intentQualitative, 0).get
    let rep = satisfy(pal, [minDeltaEOK(0.5)])
    check rep.satisfied
    check rep.warnings.len == 0
  test "requireSatisfied errors when violated":
    let a = color(tagOklab, 0.5'f32, 0.1'f32, 0.0'f32).get
    let pal = palette(palUnordered, [a, a], intentQualitative, 0).get
    check requireSatisfied(pal, [minDeltaEOK(0.5)]).error.kind == Unsatisfiable

suite "tonal scales":
  test "tonalScale length and structure":
    let p = tonalScale(baseOklch, 5, tcTailwind).get
    check p.len == 5
    check p.tag == palOrdered
    check p.intent == intentUI
  test "tonalScale n < 2 is InvalidOp":
    check tonalScale(baseOklch, 1, tcTailwind).error.kind == InvalidOp
  test "neutralScale length":
    let p = neutralScale(baseOklch, 5, nmPure).get
    check p.len == 5
    check p.tag == palOrdered
  test "neutralScale n < 2 is InvalidOp":
    check neutralScale(baseOklch, 1, nmPure).error.kind == InvalidOp
