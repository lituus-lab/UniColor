# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# states — orthogonal state resolution by OKLCH tone shift. States
# (hover/active/focus/disabled) are NOT hardcoded colors in the tree: they
# shift the lightness of the resolved base role in OKLCH by a step count, with
# direction set by the theme mode (light/dark). This keeps an N×M grid of state
# colors out of the token tree.
#
# Step model: hover=+1 step, active=+2, focus=+1 (focus also reinforces contrast
# — that is the accessibility layer, not here), disabled ramps toward the
# background (reduces contrast). A "step" is a fixed ΔL in OKLCH
# (`StateShift.stepSize`, default 0.08). Primitives are single colors, not
# tonal ramps, so the "ramp index" model is a ΔL shift here — documented.
# Direction: lighter in light mode, darker in dark mode (relative to the
# background). Bounded to [0,1]; deterministic. The tone shift LAYERS on the
# base color resolved via `resolveWithFallback`: a state role first resolves its
# base color, then the shift is applied.
#
# `disabled` is special: it blends the base lightness toward the resolved
# `background` role by one step fraction (reducing contrast), so its direction
# follows the background regardless of mode. `stateSteps` returns -1 for
# `disabled` as a sentinel for this bg-aware path.
import std/math
import UniColor/core/core
import UniColor/conversion/conversion # `to`, `gamutMap`.
import UniColor/theme/tree
import UniColor/theme/roles
import UniColor/theme/inherit

type
  ThemeMode* {.pure.} = enum
    ## Light vs dark theme surface. Sets the direction of the tone shift:
    ## lighter in light mode, darker in dark mode.
    tmLight
    tmDark

  StateShift* = object
    ## Options for the OKLCH tone shift applied to state roles. `stepSize` is
    ## the ΔL per step.
    stepSize*: float64

proc defaultStateShift*(): StateShift {.raises: [].} =
  ## Default tone-shift options: `stepSize = 0.08` OKLCH lightness per step.
  StateShift(stepSize: 0.08)

proc stateSteps*(state: string, opts: StateShift): int {.raises: [].} =
  ## Step count for a state name: hover=+1, active=+2, focus=+1, disabled=-1
  ## (sentinel: `disabled` blends toward the background rather than a
  ## fixed-direction shift, handled in `resolveState`). Unknown state -> 0.
  ## `opts` reserved for future per-step tuning.
  discard opts
  case state
  of "hover": 1
  of "active": 2
  of "focus": 1
  of "disabled": -1
  else: 0

proc applyToneShift*(c: Color, steps: int, mode: ThemeMode,
    opts: StateShift): Result[Color, ColorError] {.raises: [].} =
  ## Shift `c` lightness in OKLCH by `steps * opts.stepSize`, clamped to [0,1]
  ## (bounded). Direction is +L in light mode, -L in dark mode. Chroma, hue, and
  ## alpha are preserved; the result is gamut-mapped back to `c`'s original
  ## space. Deterministic (pure arithmetic).
  let oklR = c.to(tagOklch)
  if oklR.isErr:
    return err[Color, ColorError](oklR.error)
  let o = oklR.get
  let dir = if mode == tmLight: 1.0 else: -1.0
  let l0 = o.comp(0).float64 + float64(steps) * opts.stepSize * dir
  let newL = clamp(l0, 0.0, 1.0)
  let shifted = color(tagOklch, newL.float32, o.comp(1), o.comp(2), c.alpha())
  if shifted.isErr:
    return err[Color, ColorError](shifted.error)
  shifted.get.gamutMap(c.spaceTag())

proc blendTowardBg(base, bg: Color, opts: StateShift): Result[Color,
    ColorError] {.raises: [].} =
  ## Blend `base` lightness toward `bg` lightness by one `opts.stepSize`
  ## fraction in OKLCH, keeping `base` chroma/hue/alpha. Used for `disabled`
  ## (reduces contrast toward the surface). Deterministic.
  let bR = base.to(tagOklch)
  if bR.isErr:
    return err[Color, ColorError](bR.error)
  let gR = bg.to(tagOklch)
  if gR.isErr:
    return err[Color, ColorError](gR.error)
  let lb = bR.get.comp(0).float64
  let lg = gR.get.comp(0).float64
  let newL = lb + opts.stepSize * (lg - lb)
  let shifted = color(tagOklch, newL.float32, bR.get.comp(1), bR.get.comp(2),
      base.alpha())
  if shifted.isErr:
    return err[Color, ColorError](shifted.error)
  shifted.get.gamutMap(base.spaceTag())

proc modeDefaultBg(mode: ThemeMode): Color {.raises: [].} =
  ## Neutral background fallback when the `background` role is unresolved: pure
  ## white in light mode, pure black in dark mode. Lets `disabled` degrade
  ## gracefully instead of failing.
  if mode == tmLight:
    color(tagOklch, 1.0'f32, 0.0'f32, 0.0'f32).get
  else:
    color(tagOklch, 0.0'f32, 0.0'f32, 0.0'f32).get

proc resolveState*(t: Theme, role: string, mode: ThemeMode,
    opts: StateShift = defaultStateShift()): Result[Color,
        ColorError] {.raises: [].} =
  ## Resolve `role` to a `Color` with the state tone shift applied. The base
  ## role (state stripped) is resolved via `resolveWithFallback`; then:
  ##  - no state: base color exact (no shift);
  ##  - `disabled`: base lightness blended toward the resolved `background`
  ##    (reduces contrast);
  ##  - `hover`/`active`/`focus`: base L shifted by the state's step count in
  ##    the mode direction.
  ## Unknown base role -> `UnresolvedRole` (propagated from the fallback chain).
  ## Deterministic.
  let baseRoleName = baseRole(role)
  let baseR = t.resolveWithFallback(baseRoleName)
  if baseR.isErr:
    return err[Color, ColorError](baseR.error)
  let base = baseR.get
  let st = stateOf(role)
  if st.len == 0:
    return ok[Color, ColorError](base)
  if st == "disabled":
    let bgR = t.resolveWithFallback("background")
    let bg = if bgR.isOk: bgR.get else: modeDefaultBg(mode)
    return blendTowardBg(base, bg, opts)
  let steps = stateSteps(st, opts)
  if steps == 0:
    return ok[Color, ColorError](base)
  applyToneShift(base, steps, mode, opts)
