# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# palette/constraints — ordered palette constraints. Each constraint evaluates a
# palette and reports `satisfied` + a measurable `violation` (0 = satisfied).
# The objectives are ORDERED — accessibility (contrast) is non-negotiable, then
# perceptual uniformity, then aesthetic — `checkConstraints` aggregates them;
# `totalViolation` sums violations and serves as a penalty bridge to the
# optimizer's `ObjectiveFn` (lower = better palette). Constraints are
# constructed values (no registry): they capture their parameters in a closure.
#
# `cvdSafe` (CVD confusability) lands with the accessibility layer: it requires
# CVD simulation (`simulateCvd`/`CvdType`), not yet ported. It returns with
# accessibility rather than as a stub that lies or clashes with that layer's
# `CvdType`.
import UniColor/core/core
import UniColor/conversion/conversion # `to` (OKLab/OKLCH), `gamutMap`.
import UniColor/contrast/contrast # `deltaE_ok`, `contrastRatio`.

type
  ConstraintResult* = object
    name*: string
    satisfied*: bool
    violation*: float64 ## 0 = satisfied; > 0 = how far past the limit.
    message*: string

  Constraint* = object
    name*: string
    evaluate*: proc(colors: openArray[Color]): ConstraintResult {.raises: [].}

  ConstraintReport* = object
    satisfied*: bool
    results*: seq[ConstraintResult]

const EPS = 1.0e-9

# OKLab coords as float64 (deltaE_ok reads OKLab comps directly).
proc oklabOf(c: Color): Result[tuple[l, a, b: float64], ColorError] {.
    raises: [].} =
  let r = c.to(tagOklab)
  if r.isErr:
    return err[tuple[l, a, b: float64], ColorError](r.error)
  let o = r.get
  ok[tuple[l, a, b: float64], ColorError]((o.comp(0).float64, o.comp(1).float64,
      o.comp(2).float64))

# Pairwise minimum ΔE_OK over the palette (converts each to OKLab). Inf if a
# conversion fails or there are fewer than 2 colors (no pairs).
proc minPairwiseDeltaE(colors: openArray[Color]): float64 {.raises: [].} =
  if colors.len < 2:
    return Inf
  var labs: seq[tuple[l, a, b: float64]] = @[]
  for c in colors:
    let oklR = oklabOf(c)
    if oklR.isErr:
      return Inf
    labs.add(oklR.get)
  var mn = Inf
  for i in 0 ..< labs.len:
    let ci = color(tagOklab, labs[i].l.float32, labs[i].a.float32, labs[
        i].b.float32).get
    for j in (i + 1) ..< labs.len:
      let cj = color(tagOklab, labs[j].l.float32, labs[j].a.float32, labs[
          j].b.float32).get
      let d = deltaE_ok(ci, cj)
      if d < mn:
        mn = d
  mn

proc minDeltaEOK*(minDist: float64): Constraint {.raises: [].} =
  ## Inter-color minimum ΔE_OK: every pairwise ΔE_OK must be >= `minDist`.
  Constraint(name: "minDeltaEOK", evaluate: proc(colors: openArray[
      Color]): ConstraintResult {.raises: [].} =
    let mn = minPairwiseDeltaE(colors)
    let v = max(0.0, minDist - mn)
    ConstraintResult(name: "minDeltaEOK", satisfied: v <= EPS, violation: v,
        message: if v <= EPS: "" else: "min pairwise ΔE_OK " & $mn & " < " &
            $minDist))

proc minContrast*(pairs: openArray[(Color, Color)],
    minRatio: float64): Constraint {.raises: [].} =
  ## WCAG contrast over explicit fg/bg pairs (a11y non-negotiable): every pair's
  ## contrast ratio must be >= `minRatio`. `pairs` is captured (the palette
  ## argument is ignored — contrast is a pairwise relation, not a palette
  ## property).
  let capturedPairs: seq[(Color, Color)] = @pairs
  Constraint(name: "minContrast", evaluate: proc(colors: openArray[
      Color]): ConstraintResult {.raises: [].} =
    var v = 0.0
    var ok = true
    for p in capturedPairs:
      let rR = contrastRatio(p[0], p[1])
      if rR.isErr:
        return ConstraintResult(name: "minContrast", satisfied: false,
            violation: Inf, message: "contrast ratio error")
      let ratio = rR.get
      let d = max(0.0, minRatio - ratio)
      if d > 0.0:
        ok = false
        v += d
    ConstraintResult(name: "minContrast", satisfied: ok and v <= EPS,
        violation: v, message: if ok: "" else: "a pair below " & $minRatio &
            ":1"))

proc gamutTarget*(target: SpaceTag): Constraint {.raises: [].} =
  ## All colors must be inside the `target` gamut: a color is in-gamut when
  ## `gamutMap` leaves it within a JND (TOL_JND) of the original.
  Constraint(name: "gamutTarget", evaluate: proc(colors: openArray[
      Color]): ConstraintResult {.raises: [].} =
    var v = 0.0
    var ok = true
    for c in colors:
      let mR = gamutMap(c, target)
      if mR.isErr:
        return ConstraintResult(name: "gamutTarget", satisfied: false,
            violation: Inf, message: "gamutMap error")
      let oklR = oklabOf(c)
      let mO = oklabOf(mR.get)
      if oklR.isErr or mO.isErr:
        return ConstraintResult(name: "gamutTarget", satisfied: false,
            violation: Inf, message: "conversion error")
      let (l1, a1, b1) = oklR.get
      let (l2, a2, b2) = mO.get
      let co = color(tagOklab, l1.float32, a1.float32, b1.float32).get
      let cm = color(tagOklab, l2.float32, a2.float32, b2.float32).get
      let d = deltaE_ok(co, cm)
      if d > TOL_JND:
        ok = false
        v += d - TOL_JND # excess beyond the JND.
    ConstraintResult(name: "gamutTarget", satisfied: ok, violation: v,
        message: if ok: "" else: "color(s) outside " & $target & " gamut"))

proc lightnessMonotonic*(strict: bool): Constraint {.raises: [].} =
  ## Consecutive OKLCH lightness must increase: strictly (`L[i+1] > L[i]`) or
  ## non-strictly (`L[i+1] >= L[i]`). `violation` accumulates the deficit of
  ## each non-increasing step.
  Constraint(name: "lightnessMonotonic",
      evaluate: proc(colors: openArray[Color]): ConstraintResult {.raises: [].} =
    if colors.len < 2:
      return ConstraintResult(name: "lightnessMonotonic", satisfied: true,
          violation: 0.0, message: "")
    var ls: seq[float64] = @[]
    for c in colors:
      let oklR = c.to(tagOklch)
      if oklR.isErr:
        return ConstraintResult(name: "lightnessMonotonic", satisfied: false,
            violation: Inf, message: "OKLCH conversion error")
      ls.add(oklR.get.comp(0).float64)
    var v = 0.0
    var ok = true
    let slack = 1.0e-4 # strict steps must exceed this to count as increasing.
    for i in 0 ..< ls.len - 1:
      let inc = ls[i + 1] - ls[i]
      let d = if strict: max(0.0, slack - inc) else: max(0.0, -inc)
      if d > 0.0:
        ok = false
        v += d
    let msg = if ok: "" else: "lightness not " &
        (if strict: "strictly " else: "") & "monotonic"
    ConstraintResult(name: "lightnessMonotonic", satisfied: ok, violation: v,
        message: msg))

proc perceptualUniform*(maxDev: float64): Constraint {.raises: [].} =
  ## Perceptual uniformity: the neighbor ΔE_OK between consecutive colors should
  ## be roughly constant — the max deviation of neighbor ΔE from their mean must
  ## be <= `maxDev`.
  Constraint(name: "perceptualUniform",
      evaluate: proc(colors: openArray[Color]): ConstraintResult {.raises: [].} =
    if colors.len < 2:
      return ConstraintResult(name: "perceptualUniform", satisfied: true,
          violation: 0.0, message: "")
    var steps: seq[float64] = @[]
    for i in 0 ..< colors.len - 1:
      let aR = oklabOf(colors[i])
      let bR = oklabOf(colors[i + 1])
      if aR.isErr or bR.isErr:
        return ConstraintResult(name: "perceptualUniform", satisfied: false,
            violation: Inf, message: "conversion error")
      let (l1, a1, b1) = aR.get
      let (l2, a2, b2) = bR.get
      let ca = color(tagOklab, l1.float32, a1.float32, b1.float32).get
      let cb = color(tagOklab, l2.float32, a2.float32, b2.float32).get
      steps.add(deltaE_ok(ca, cb))
    var mean = 0.0
    for s in steps:
      mean += s
    mean /= float64(steps.len)
    var dev = 0.0
    for s in steps:
      let dd = abs(s - mean)
      if dd > dev:
        dev = dd
    let v = max(0.0, dev - maxDev)
    let msg = if v <= EPS: "" else: "neighbor ΔE_OK deviation " & $dev &
        " > " & $maxDev
    ConstraintResult(name: "perceptualUniform", satisfied: v <= EPS,
        violation: v, message: msg))

proc checkConstraints*(colors: openArray[Color],
    constraints: openArray[Constraint]): ConstraintReport {.raises: [].} =
  ## Evaluate every constraint in order and aggregate. `satisfied` iff all are.
  var report = ConstraintReport(satisfied: true, results: @[])
  for c in constraints:
    let r = c.evaluate(colors)
    if not r.satisfied:
      report.satisfied = false
    report.results.add(r)
  report

proc totalViolation*(constraints: openArray[Constraint], colors: openArray[
    Color]): float64 {.raises: [].} =
  ## Sum of all constraint violations — a penalty suitable as the optimizer's
  ## `ObjectiveFn` (lower = better palette). `Inf` from any constraint
  ## (conversion failure) dominates.
  var v = 0.0
  for c in constraints:
    v += c.evaluate(colors).violation
  v
