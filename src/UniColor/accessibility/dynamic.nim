# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# dynamic — runtime contrast adjustment by OKLCH tone shift.
# `adjustForContrast(fg, bg, threshold)` shifts the TONE (OKLCH lightness L) of
# `fg` away from `bg` along its OKLCH ramp until the contrast meets `threshold`,
# then returns the MINIMAL-shift color that passes — the Material "minimum text
# tone passing the threshold". This is the runtime/derived counterpart of
# `correction` (which applies a fixed delta): here the magnitude is not given
# but SEARCHED, deterministically, on the L ramp.
#
# Determinism: the scan is a fixed-step L sweep from `fg`'s own L toward the
# ramp extreme, independent of any RNG/threading. No `Color` is mutated: a fresh
# candidate is built at each step and the input is left untouched. When the
# threshold is unreachable within L ∈ [0,1], the result is NOT silently clamped:
# `met == false`, a non-empty `warning` is surfaced, and the best-effort extreme
# candidate (closest to passing) is returned — never a hidden correction.
#
# Consumer of the core (conversion `to`/`gamutMap`, contrast dispatcher) and of
# the OKLCH round-trip (OKLab is D65 so the round-trip is tight). All procs
# pure: no Color mutation, deterministic, no side effects.
import std/options
import std/math # `clamp`, `abs`.
import UniColor/core/core
import UniColor/conversion/conversion # `to` (OKLCH round-trip) + `gamutMap`.
import UniColor/contrast/contrast # `contrast(fg, bg, metric)` dispatcher.

type
  AdjustDirection* {.pure.} = enum
    ## Direction of the tone shift on the OKLCH L ramp.
    adAuto    ## move `fg` away from `bg` (darker if bg is lighter, else lighter).
    adLighter ## force the scan toward L = 1 regardless of bg.
    adDarker  ## force the scan toward L = 0 regardless of bg.

  AdjustOpts* = object
    ## Parameters for `adjustForContrast`. `stepSize` is the L increment (in
    ## OKLCH L units, [0,1]) between scan steps — smaller = finer-grained but
    ## more candidates evaluated. A non-positive `stepSize` is rejected as
    ## `InvalidColor` (a programming error, not a clampable value).
    direction*: AdjustDirection
    stepSize*: float64

  AdjustResult* = object
    ## Outcome of a runtime contrast adjustment. `met == true` when a candidate
    ## reached `threshold` (then `finalContrast >= threshold` and `steps` is the
    ## count of L steps taken from `fg`'s L; `steps == 0` means `fg` already
    ## passed). `met == false` means the threshold was unreachable within
    ## L ∈ [0,1] — `warning` is then non-empty (never silent) and `color` is the
    ## best-effort extreme candidate. `finalContrast` is always the contrast of
    ## the returned `color` against `bg` under `metric`.
    color*: Color
    met*: bool
    steps*: int
    finalContrast*: float64
    warning*: string

const
  DefaultAdjustStep* = 0.01       ## default L step (100 steps cover [0,1]).
  DefaultAdjustMetric* = "wcag22" ## WCAG 2.2 contrast ratio.

proc defaultAdjustOpts*(): AdjustOpts {.raises: [].} =
  ## The default options: auto direction (away from bg), 0.01 L step.
  AdjustOpts(direction: adAuto, stepSize: DefaultAdjustStep)

# Build a candidate color at OKLCH (L, C, h), gamut-map it into `fg`'s display
# space, and measure its contrast against `bg`. The OKLCH comps are built
# out-of-gamut-tolerant (`color` validates tag/alpha/NaN but preserves comps);
# `gamutMap` reduces chroma only as far as needed to fit (it PRESERVES L and h,
# so the ramp scan's L intent is honored). Returns the displayable candidate,
# its contrast, or an error.
proc evalCandidate(fg, bg: Color, L, C, h: float64, metric: string): tuple[
    cR: Result[Color, ColorError], contrastR: Result[float64, ColorError]] {.
    raises: [].} =
  let builtR = color(tagOklch, L.float32, C.float32, h.float32, fg.alpha())
  if builtR.isErr:
    return (builtR, err[float64, ColorError](builtR.error))
  let mappedR = builtR.get.gamutMap(fg.spaceTag)
  if mappedR.isErr:
    return (mappedR, err[float64, ColorError](mappedR.error))
  let cr = contrast(mappedR.get, bg, metric)
  if cr.isErr:
    return (err[Color, ColorError](cr.error), cr)
  (mappedR, cr)

proc adjustForContrast*(fg, bg: Color, threshold: float64,
    metric = DefaultAdjustMetric, opts = defaultAdjustOpts()): Result[
        AdjustResult, ColorError] {.raises: [].} =
  ## Adjust `fg`'s OKLCH lightness until `contrast(fg, bg, metric) >= threshold`,
  ## returning the minimal-shift passing color (Material "minimum text tone
  ## passing the threshold"). `direction` selects auto/forced; `stepSize` is the
  ## L increment. Deterministic, no `Color` mutation. If the threshold is
  ## unreachable within L ∈ [0,1], returns `met == false` + a best-effort
  ## extreme candidate + a non-empty `warning` (never silent). On a
  ## conversion/gamut/metric error the `Result` is `err`.
  if opts.stepSize <= 0.0:
    return err[AdjustResult, ColorError](colorError(InvalidColor,
        "adjustForContrast stepSize must be > 0, got " & $opts.stepSize,
        "adjustForContrast"))
  let fgOkR = fg.to(tagOklch)
  if fgOkR.isErr:
    return err[AdjustResult, ColorError](fgOkR.error)
  let bgOkR = bg.to(tagOklch)
  if bgOkR.isErr:
    return err[AdjustResult, ColorError](bgOkR.error)
  let fo = fgOkR.get
  let bo = bgOkR.get
  let fL = fo.comp(0).float64
  let fC = fo.comp(1).float64
  let fH = fo.comp(2).float64
  let bL = bo.comp(0).float64
  # adAuto moves fg AWAY from bg in L (bg lighter -> fg darker, and vice-versa),
  # the side that can only increase the lightness contrast. Ties (bL == fL)
  # default to darker (arbitrary but deterministic).
  let dir = if opts.direction == adAuto:
      (if bL >= fL: adDarker else: adLighter)
    else:
      opts.direction
  let sign = if dir == adDarker: -1.0 else: 1.0
  # Fixed-step L sweep from fL toward the ramp extreme. Step 0 is fL itself (so
  # an already-passing fg returns at steps == 0 with no shift). Bounded by the
  # extreme: once a step clamps to 0/1 we evaluate that extreme and stop.
  var k = 0
  var bestColor: Option[Color] = none(Color)
  var bestContrast = -1.0
  while true:
    var L = fL + sign * (opts.stepSize * k.float)
    var reachedExtreme = false
    if L <= 0.0:
      L = 0.0
      reachedExtreme = true
    elif L >= 1.0:
      L = 1.0
      reachedExtreme = true
    let (cR, crR) = evalCandidate(fg, bg, L, fC, fH, metric)
    if cR.isErr:
      return err[AdjustResult, ColorError](cR.error)
    let cand = cR.get
    let cv = crR.get
    if cv >= threshold:
      # Minimal-shift passing candidate (the first one, scanning outward).
      return ok[AdjustResult, ColorError](AdjustResult(color: cand, met: true,
          steps: k, finalContrast: cv, warning: ""))
    if cv > bestContrast:
      bestContrast = cv
      bestColor = some(cand)
    if reachedExtreme:
      break
    inc k
  # Threshold unreachable within L ∈ [0,1] — surface the best-effort (closest
  # candidate) with a non-empty warning. Never silent: the caller must know.
  let be = if bestColor.isSome: bestColor.get else: fg
  ok[AdjustResult, ColorError](AdjustResult(color: be, met: false, steps: k,
      finalContrast: bestContrast,
      warning: "contrast threshold " & $threshold &
      " unreachable within L ramp; best-effort " &
        $dir & " extreme"))
