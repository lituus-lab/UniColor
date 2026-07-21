# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# palette/optim — optimization-based palette generation (simulated annealing +
# genetic). A GENERIC optimization engine over a pluggable penalty `ObjectiveFn`
# (lower = better; 0 = perfect). Ships two registered optimizers — simulated
# annealing (Metropolis with geometric cooling) and a genetic algorithm
# (population, elite, uniform crossover, mutation) — plus the self-contained
# default objective `dispersionPenalty` (max-min ΔE_OK, uses only the existing
# `deltaE_ok` primitive). Concrete constraint-based objectives (minContrast,
# gamutTarget, ...) are `Constraint` values in `palette/constraints`; the
# optimizer does not duplicate them.
#
# Determinism: a pure function of (base, obj, opts.seed) — the only source of
# randomness is the seeded SplitMix64 RNG, seed=0 canonical. Single-threaded
# today; `threads` is the #threads contract surface (one path => order-stable
# trivially, same output for any `threads >= 1`); a deferred parallel dispatch
# must preserve the invariant. Candidates live in OKLCH (the search space) and
# the returned palette stores them as-is (seed = opts.seed).
import std/math # `mod` on floats, `exp` (Metropolis), `clamp`, `Inf`, `pow`.
import std/options
import std/tables
import std/algorithm # `sort`, `cmp` (GA ranking).
import UniColor/core/core
import UniColor/conversion/conversion # `to` (base -> OKLCH; candidates -> OKLab).
import UniColor/contrast/contrast # `deltaE_ok` (default objective).
import UniColor/math/rng # SplitMix64 (deterministic draws).
import UniColor/palette/types

type
  ObjectiveFn* = proc(colors: openArray[Color]): float64 {.raises: [].}
    ## Penalty of a candidate palette — LOWER is better, 0 = perfect. A pure
    ## function of the colors. Candidates are handed in OKLCH (the search
    ## space); an objective that needs another space converts internally (see
    ## `dispersionPenalty` -> OKLab).

  OptimKind* = enum
    optimAnnealing
    optimGenetic

  OptimBounds* = object
    ## Search window in OKLCH. Defaults via `defaultBounds`. Validated:
    ## lMin>=0, lMax<=1, lMin<=lMax, cMin>=0, cMin<=cMax, 0<=hMin<hMax<=360.
    lMin*: float64
    lMax*: float64
    cMin*: float64
    cMax*: float64
    hMin*: float64
    hMax*: float64

  OptimOpts* = object
    ## Optimization options. `seed` is the sole source of randomness
    ## (deterministic). `n` is the palette size. SA uses `iterations`/`t0`/
    ## `tMin`; GA uses `iterations` (generations)/`popSize`/`elite`/
    ## `mutationRate`. `threads` is the #threads contract surface: execution is
    ## single-threaded today (one path => order-stable trivially, same output
    ## for any `threads >= 1`); a deferred parallel dispatch must preserve the
    ## invariant. Defaults via `defaultOpts`.
    seed*: int64
    n*: int
    bounds*: OptimBounds
    iterations*: int
    t0*: float64 # SA initial temperature (> 0).
    tMin*: float64 # SA final temperature (> 0, < t0).
    popSize*: int # GA population (>= 2).
    elite*: int # GA elite kept (>= 1, < popSize).
    mutationRate*: float64 # GA per-child probability (in [0,1]).
    threads*: int # #threads contract surface (>= 1); single-threaded today.

  OptimResult* = object
    palette*: Palette
    energy*: float64 ## final penalty (lower = better).
    warning*: string

  OptimAlgo* = object
    name*: string
    optimize*: proc(base: Color, obj: ObjectiveFn, opts: OptimOpts): Result[
        OptimResult, ColorError] {.raises: [].}

var optimByName: Table[string, OptimAlgo]

proc registerOptimAlgo*(a: OptimAlgo): bool {.raises: [].} =
  ## Register an optimizer by name. Returns `true` if added, `false` if the name
  ## is already present (no silent overwrite).
  if optimByName.hasKey(a.name):
    return false
  optimByName[a.name] = a
  true

proc lookupOptimAlgo*(name: string): Option[OptimAlgo] {.raises: [].} =
  if optimByName.hasKey(name):
    some(optimByName.getOrDefault(name))
  else:
    none(OptimAlgo)

proc optimAlgoCount*(): int {.raises: [].} = optimByName.len

# Default search window: a reasonable OKLCH box (L mid-range, C up to 0.4, full
# hue circle).
proc defaultBounds*(): OptimBounds {.raises: [].} =
  OptimBounds(lMin: 0.3, lMax: 0.8, cMin: 0.0, cMax: 0.4, hMin: 0.0, hMax: 360.0)

proc defaultOpts*(kind: OptimKind, n: int): OptimOpts {.raises: [].} =
  ## Sensible defaults. SA: 2000 cooling steps; GA: 100 generations, pop 30,
  ## elite 2.
  case kind
  of optimAnnealing:
    OptimOpts(seed: 0, n: n, bounds: defaultBounds(), iterations: 2000, t0: 1.0,
        tMin: 0.0001, popSize: 30, elite: 2, mutationRate: 0.1, threads: 1)
  of optimGenetic:
    OptimOpts(seed: 0, n: n, bounds: defaultBounds(), iterations: 100, t0: 1.0,
        tMin: 0.0001, popSize: 30, elite: 2, mutationRate: 0.1, threads: 1)

proc validBounds(b: OptimBounds): bool {.raises: [].} =
  b.lMin >= 0.0 and b.lMax <= 1.0 and b.lMin <= b.lMax and b.cMin >= 0.0 and
      b.cMin <= b.cMax and b.hMin >= 0.0 and b.hMax <= 360.0 and b.hMin < b.hMax

# Wrap a hue into [hMin, hMax).
proc wrapHue(h, hMin, hMax: float64): float64 {.raises: [].} =
  let span = hMax - hMin
  let r = hMin + ((h - hMin) mod span + span) mod span
  if r >= hMax: hMin else: r

# Build an OKLCH color from raw coords (validated by `color`); returns err on a
# bad value.
proc oklchColor(L, C, h, alpha: float64): Result[Color, ColorError] {.
    raises: [].} =
  color(tagOklch, L.float32, C.float32, h.float32, alpha.float32)

proc dispersionPenalty*(colors: openArray[Color]): float64 {.raises: [].} =
  ## Default objective: maximize the minimum pairwise ΔE_OK between the colors
  ## (qualitative dispersion — colors as distinguishable as possible). Returns
  ## the PENALTY = `-min pairwise ΔE_OK`, so LOWER is better (the optimizer
  ## pushes min ΔE up). For fewer than 2 colors there are no pairs -> 0 (nothing
  ## to disperse). Candidates arrive in OKLCH and are converted to OKLab for
  ## `deltaE_ok` (which reads OKLab comps directly).
  if colors.len < 2:
    return 0.0
  var minD = Inf
  for i in 0 ..< colors.len:
    let liR = colors[i].to(tagOklab)
    if liR.isErr:
      return Inf # invalid candidate -> infinitely bad (rejected by the optimizer).
    let li = liR.get
    for j in (i + 1) ..< colors.len:
      let ljR = colors[j].to(tagOklab)
      if ljR.isErr:
        return Inf
      let d = deltaE_ok(li, ljR.get)
      if d < minD:
        minD = d
  -minD

# Deterministic init: color[0] anchored at the base hue (in OKLCH), the rest
# uniform-random in the bounds. RNG-driven for GA population diversity;
# deterministic given the seed.
proc initCandidate(rng: var SplitMix64, base: Color, n: int,
    b: OptimBounds): Result[seq[Color], ColorError] {.raises: [].} =
  let baseR = base.to(tagOklch)
  if baseR.isErr:
    return err[seq[Color], ColorError](baseR.error)
  let o = baseR.get
  let L0 = o.comp(0).float64
  let C0 = o.comp(1).float64
  let h0 = wrapHue(o.comp(2).float64, b.hMin, b.hMax)
  var colors: seq[Color] = @[]
  block addFirst:
    let c0R = oklchColor(clamp(L0, b.lMin, b.lMax), clamp(C0, b.cMin, b.cMax),
        h0, base.alpha().float64)
    if c0R.isErr:
      return err[seq[Color], ColorError](c0R.error)
    colors.add(c0R.get)
  for i in 1 ..< n:
    let L = b.lMin + rng.nextFloat() * (b.lMax - b.lMin)
    let C = b.cMin + rng.nextFloat() * (b.cMax - b.cMin)
    let h = b.hMin + rng.nextFloat() * (b.hMax - b.hMin)
    let cR = oklchColor(L, C, h, base.alpha().float64)
    if cR.isErr:
      return err[seq[Color], ColorError](cR.error)
    colors.add(cR.get)
  ok[seq[Color], ColorError](colors)

proc buildPalette(colors: seq[Color], seed: int64): Result[Palette,
    ColorError] {.raises: [].} =
  palette(palUnordered, colors, intentQualitative, seed)

proc annealing*(base: Color, obj: ObjectiveFn, opts: OptimOpts): Result[
    OptimResult, ColorError] {.raises: [].} =
  ## Simulated annealing: minimize the penalty `obj` via Metropolis acceptance
  ## at a geometrically cooled temperature. Deterministic given `opts.seed`.
  ## Returns the best candidate found as a `palUnordered` qualitative palette
  ## (seed = opts.seed).
  if opts.n < 1:
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "annealing: n must be >= 1, got " & $opts.n, "annealing"))
  if opts.iterations < 0:
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "annealing: iterations must be >= 0, got " & $opts.iterations,
        "annealing"))
  if opts.threads < 1:
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "annealing: threads must be >= 1, got " & $opts.threads, "annealing"))
  if opts.t0 <= 0.0 or opts.tMin <= 0.0 or opts.tMin >= opts.t0:
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "annealing: need 0 < tMin < t0, got t0=" & $opts.t0 & " tMin=" &
        $opts.tMin, "annealing"))
  if not validBounds(opts.bounds):
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "annealing: invalid bounds", "annealing"))
  var rng = initSplitMix64(uint64(opts.seed) xor 0x9E3779B97F4A7C15'u64)
  let initR = initCandidate(rng, base, opts.n, opts.bounds)
  if initR.isErr:
    return err[OptimResult, ColorError](initR.error)
  var current = initR.get
  var curEnergy = obj(current)
  var best = current
  var bestEnergy = curEnergy
  if opts.n == 1 or opts.iterations == 0:
    let pR = buildPalette(best, opts.seed)
    if pR.isErr:
      return err[OptimResult, ColorError](pR.error)
    return ok[OptimResult, ColorError](OptimResult(palette: pR.get,
        energy: bestEnergy, warning: ""))
  let lSpan = opts.bounds.lMax - opts.bounds.lMin
  let cSpan = opts.bounds.cMax - opts.bounds.cMin
  let hSpan = opts.bounds.hMax - opts.bounds.hMin
  for it in 0 ..< opts.iterations:
    let T = opts.t0 * pow(opts.tMin / opts.t0,
        it.float64 / opts.iterations.float64) # geometric cooling.
    var cand = current
    let idx = int(rng.next() mod uint64(opts.n))
    let coord = int(rng.next() mod 3'u64)
    let oklR = cand[idx].to(tagOklch)
    if oklR.isErr:
      continue
    let o = oklR.get
    var L = o.comp(0).float64
    var C = o.comp(1).float64
    var h = o.comp(2).float64
    let mag = (T / opts.t0) * 0.3
    case coord
    of 0:
      L = clamp(L + (rng.nextFloat() * 2.0 - 1.0) * mag * lSpan,
          opts.bounds.lMin, opts.bounds.lMax)
    of 1:
      C = clamp(C + (rng.nextFloat() * 2.0 - 1.0) * mag * cSpan,
          opts.bounds.cMin, opts.bounds.cMax)
    else:
      h = wrapHue(h + (rng.nextFloat() * 2.0 - 1.0) * mag * hSpan,
          opts.bounds.hMin, opts.bounds.hMax)
    let nR = oklchColor(L, C, h, base.alpha().float64)
    if nR.isErr:
      continue
    cand[idx] = nR.get
    let e = obj(cand)
    if e <= curEnergy or rng.nextFloat() < exp(-(e - curEnergy) / max(T, 1.0e-12)):
      current = cand
      curEnergy = e
      if e < bestEnergy:
        best = cand
        bestEnergy = e
  let pR = buildPalette(best, opts.seed)
  if pR.isErr:
    return err[OptimResult, ColorError](pR.error)
  ok[OptimResult, ColorError](OptimResult(palette: pR.get, energy: bestEnergy,
      warning: ""))

# Tournament selection: pick two random individuals, keep the better (lower
# penalty).
proc tournament(rng: var SplitMix64, pop: seq[seq[Color]], fit: seq[
    float64]): seq[Color] {.raises: [].} =
  let a = int(rng.next() mod uint64(pop.len))
  let b = int(rng.next() mod uint64(pop.len))
  if fit[a] <= fit[b]: pop[a] else: pop[b]

proc crossover(rng: var SplitMix64, a, b: seq[Color]): Result[seq[Color],
    ColorError] {.raises: [].} =
  var child: seq[Color] = @[]
  for i in 0 ..< a.len:
    if (rng.next() and 1'u64) == 0:
      child.add(a[i])
    else:
      child.add(b[i])
  ok[seq[Color], ColorError](child)

proc mutate(rng: var SplitMix64, child: var seq[Color],
    b: OptimBounds): bool {.raises: [].} =
  ## In-place mutation of one random color/coord. Returns false on a
  ## construction error (caller skips the child).
  let idx = int(rng.next() mod uint64(child.len))
  let coord = int(rng.next() mod 3'u64)
  let oklR = child[idx].to(tagOklch)
  if oklR.isErr:
    return false
  let o = oklR.get
  var L = o.comp(0).float64
  var C = o.comp(1).float64
  var h = o.comp(2).float64
  let lSpan = b.lMax - b.lMin
  let cSpan = b.cMax - b.cMin
  let hSpan = b.hMax - b.hMin
  case coord
  of 0:
    L = clamp(L + (rng.nextFloat() * 2.0 - 1.0) * 0.1 * lSpan, b.lMin, b.lMax)
  of 1:
    C = clamp(C + (rng.nextFloat() * 2.0 - 1.0) * 0.1 * cSpan, b.cMin, b.cMax)
  else:
    h = wrapHue(h + (rng.nextFloat() * 2.0 - 1.0) * 0.1 * hSpan, b.hMin, b.hMax)
  let alpha = child[idx].alpha().float64
  let nR = oklchColor(L, C, h, alpha)
  if nR.isErr:
    return false
  child[idx] = nR.get
  true

proc genetic*(base: Color, obj: ObjectiveFn, opts: OptimOpts): Result[
    OptimResult, ColorError] {.raises: [].} =
  ## Genetic algorithm: population of palettes, tournament selection, uniform
  ## crossover, mutation, elitism. Deterministic given `opts.seed`. Returns the
  ## best individual as a `palUnordered` qualitative palette (seed = opts.seed).
  if opts.n < 1:
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "genetic: n must be >= 1, got " & $opts.n, "genetic"))
  if opts.iterations < 0:
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "genetic: iterations must be >= 0, got " & $opts.iterations, "genetic"))
  if opts.threads < 1:
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "genetic: threads must be >= 1, got " & $opts.threads, "genetic"))
  if opts.popSize < 2:
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "genetic: popSize must be >= 2, got " & $opts.popSize, "genetic"))
  if opts.elite < 1 or opts.elite >= opts.popSize:
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "genetic: elite must be in [1, popSize), got " & $opts.elite, "genetic"))
  if opts.mutationRate < 0.0 or opts.mutationRate > 1.0:
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "genetic: mutationRate must be in [0,1], got " & $opts.mutationRate,
        "genetic"))
  if not validBounds(opts.bounds):
    return err[OptimResult, ColorError](colorError(InvalidColor,
        "genetic: invalid bounds", "genetic"))
  var rng = initSplitMix64(uint64(opts.seed) xor 0x9E3779B97F4A7C15'u64)
  var pop: seq[seq[Color]] = @[]
  var fit: seq[float64] = @[]
  for p in 0 ..< opts.popSize:
    let cR = initCandidate(rng, base, opts.n, opts.bounds)
    if cR.isErr:
      return err[OptimResult, ColorError](cR.error)
    pop.add(cR.get)
    fit.add(obj(cR.get))
  if opts.n == 1 or opts.iterations == 0:
    var bestIdx = 0
    for p in 1 ..< opts.popSize:
      if fit[p] < fit[bestIdx]:
        bestIdx = p
    let pR = buildPalette(pop[bestIdx], opts.seed)
    if pR.isErr:
      return err[OptimResult, ColorError](pR.error)
    return ok[OptimResult, ColorError](OptimResult(palette: pR.get,
        energy: fit[bestIdx], warning: ""))
  for gen in 0 ..< opts.iterations:
    # Rank by fitness (ascending penalty) and keep the elite.
    var order = newSeq[int](opts.popSize)
    for i in 0 ..< opts.popSize:
      order[i] = i
    order.sort(proc(x, y: int): int = cmp(fit[x], fit[y]))
    var newPop: seq[seq[Color]] = @[]
    var newFit: seq[float64] = @[]
    for e in 0 ..< opts.elite:
      newPop.add(pop[order[e]])
      newFit.add(fit[order[e]])
    while newPop.len < opts.popSize:
      let pa = tournament(rng, pop, fit)
      let pb = tournament(rng, pop, fit)
      let cR = crossover(rng, pa, pb)
      if cR.isErr:
        continue
      var child = cR.get
      if rng.nextFloat() < opts.mutationRate:
        if not mutate(rng, child, opts.bounds):
          continue
      let fe = obj(child)
      newPop.add(child)
      newFit.add(fe)
    pop = newPop
    fit = newFit
  var bestIdx = 0
  for p in 1 ..< opts.popSize:
    if fit[p] < fit[bestIdx]:
      bestIdx = p
  let pR = buildPalette(pop[bestIdx], opts.seed)
  if pR.isErr:
    return err[OptimResult, ColorError](pR.error)
  ok[OptimResult, ColorError](OptimResult(palette: pR.get,
      energy: fit[bestIdx], warning: ""))

proc optimize*(base: Color, obj: ObjectiveFn, opts: OptimOpts,
    algo: string): Result[OptimResult, ColorError] {.raises: [].} =
  ## Dispatch to a registered optimizer by name. Unknown name ->
  ## `UnknownAlgorithm`.
  let aOpt = lookupOptimAlgo(algo)
  if aOpt.isNone:
    return err[OptimResult, ColorError](colorError(UnknownAlgorithm,
        "optimize: unknown algorithm '" & algo & "'", "optimize"))
  aOpt.get.optimize(base, obj, opts)

# Bootstrap: register the two built-in optimizers (idempotent —
# re-registration returns false).
discard registerOptimAlgo(OptimAlgo(name: "annealing", optimize: annealing))
discard registerOptimAlgo(OptimAlgo(name: "genetic", optimize: genetic))
