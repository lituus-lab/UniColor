# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# color — Color: immutable value type, tagged by space.
# Layout: comps[0..2] = chromatic components, comps[3] = alpha straight [0,1]
# (≤3 chromatic + alpha; CMYK 4-chrom -> ColorX). ~20 bytes, stack, POD, no
# heap. Private fields -> no external mutation.

import std/hashes
import UniColor/core/numerics
import UniColor/core/color_error
import UniColor/core/space_tag
import UniColor/core/result

# Re-export the public-signature types; `numerics` stays internal.
export color_error
export space_tag
export result

type
  Color* = object
    ## Immutable value type, tagged by space. `comps[0..2]` chromatic +
    ## `comps[3]` alpha straight. Stack, POD, no heap. Private fields: no
    ## external mutation. Construct via the validating `color()` ctor — the
    ## zero value carries `tagUnknown` and is never produced by the API.
    comps: array[4, float32]
    tag: SpaceTag

func colorChecked(tag: SpaceTag, c0, c1, c2: float32,
                  alpha: float32): Result[Color, ColorError] {.raises: [].} =
  ## The validation itself. `color` asserts the postcondition over what this
  ## returns; keeping the two apart is what lets both carry `raises: []`.
  block:
    if tag == tagUnknown:
      return err[Color, ColorError](colorError(InvalidColor,
          "color requires a known space"))
    let a = float64(alpha)
    if not isFinite(a) or a < 0.0 or a > 1.0:
      return err[Color, ColorError](colorError(InvalidColor,
          "alpha out of [0,1]"))
    for c in [c0, c1, c2]:
      if not isFinite(float64(c)):
        return err[Color, ColorError](
          colorError(InvalidColor, "component NaN/Inf at bounds"))
    ok[Color, ColorError](Color(comps: [c0, c1, c2, alpha], tag: tag))

func color*(tag: SpaceTag, c0, c1, c2: float32,
            alpha = 1.0'f32): Result[Color, ColorError] {.raises: [].} =
  ## Bounds-validating constructor. Returns `err(InvalidColor)` if:
  ##   - `tag == tagUnknown` (no color without space);
  ##   - `alpha` ∉ [0,1];
  ##   - a component or alpha is NaN/Inf at bounds.
  ## Out-of-gamut components (e.g. sRGB < 0 or > 1) are **preserved** (no clamp).
  ## The core assumes valid Colors (no re-validation).
  ##
  ## The postcondition is asserted here rather than written as a NimContracts
  ## `ensure`: that wraps the body in `try/except Exception` to know whether an
  ## exception is in flight, which the compiler reads as "this can raise
  ## Exception" and `raises: []` then rejects. The check is the same one, over
  ## the returned value, and compiles away under -d:release.
  result = colorChecked(tag, c0, c1, c2, alpha)
  when not defined(release):
    doAssert (result.isOk and result.get.tag != tagUnknown and
        isFinite(float64(result.get.comps[3])) and
        result.get.comps[3] >= 0.0'f32 and result.get.comps[3] <= 1.0'f32) or
      (result.isErr and result.error.kind == InvalidColor),
      "color: a result is either a tagged color with alpha in [0,1], or " &
      "an InvalidColor error"

func spaceTag*(c: Color): SpaceTag {.inline, raises: [].} =
  c.tag

func alpha*(c: Color): float32 {.inline, raises: [].} =
  ## Alpha straight [0,1] (always present).
  c.comps[3]

func comp*(c: Color, i: range[0 .. 2]): float32 {.inline, raises: [].} =
  ## Chromatic component i (0..2).
  c.comps[i]

func components*(c: Color): tuple[c0, c1, c2: float32] {.inline, raises: [].} =
  ## The 3 chromatic components.
  (c.comps[0], c.comps[1], c.comps[2])

func isOpaque*(c: Color): bool {.inline, raises: [].} =
  c.comps[3] >= 1.0'f32

func isTransparent*(c: Color): bool {.inline, raises: [].} =
  c.comps[3] <= 0.0'f32

func `==`*(a, b: Color): bool {.raises: [].} =
  ## Bit-wise structural equality (comps + tag).
  a.tag == b.tag and a.comps == b.comps

func hash*(c: Color): Hash {.raises: [].} =
  ## Hash consistent with `==` (for tables/keys).
  result = hash(c.tag)
  for v in c.comps:
    result = result !& hash(v)
  result = !$result

func `$`*(c: Color): string {.raises: [].} =
  ## Diagnostic: `<space>(c0, c1, c2, α=alpha)`.
  result = spaceName(c.tag) & "(" & $c.comps[0] & ", " & $c.comps[1] & ", " &
    $c.comps[2] & ", α=" & $c.comps[3] & ")"
