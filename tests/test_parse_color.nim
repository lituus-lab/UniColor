# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# CSS Color 4 string → Color parser. `parseColor(s): Result[Color, ColorError]`
# returns a Color tagged by its native space (no conversion). Scope: hex
# (`#rrggbb`/`#rrggbbaa`/`#rgb`/`#rgba`), `rgb()`/`rgba()` (numbers 0-255 or %,
# alpha via `/` or legacy 4th comma arg), `oklch(L C h / a)`. DEFERRED (documented
# spec hole, not emitted by any UniColor exporter): `oklab()`, `lab()`, `lch()`,
# `color()`, `hsl()`/`hwb()` — add when a third-party importer needs them (YAGNI:
# UniColor emits only oklch + hex).
#
# Malformed → `InvalidColor`. The golden round-trip (parser inverts
# `formatColorCss`) is deferred to the serialize-layer PR.
import std/unittest
import std/strutils
import UniColor

proc near(a, b: float32, tol = 1e-3'f32): bool {.raises: [].} =
  abs(a - b) < tol

proc comps(c: Color): (float32, float32, float32) {.raises: [].} =
  let (c0, c1, c2) = c.components
  (c0, c1, c2)

suite "parseColor — hex (#rrggbb / #rrggbbaa / #rgb / #rgba)":
  test "#rrggbb -> sRGB":
    let r = parseColor("#ff0000")
    check r.isOk
    check r.get.spaceTag == tagSrgb
    let (c0, c1, c2) = r.get.comps
    check near(c0, 1.0) and near(c1, 0.0) and near(c2, 0.0)

  test "#rrggbb lowercase + uppercase both parse":
    check parseColor("#aabbcc").isOk
    check parseColor("#AABBCC").isOk

  test "#rrggbbaa -> sRGB with alpha":
    let r = parseColor("#ff000080")
    check r.isOk
    check near(r.get.alpha, 0.502'f32, 1e-2) # 0x80/255 ≈ 0.50196.

  test "#rgb (short) -> expanded":
    let r = parseColor("#f00")
    check r.isOk
    let (c0, c1, c2) = r.get.comps
    check near(c0, 1.0) and near(c1, 0.0) and near(c2, 0.0)

  test "#rgba (short) -> expanded with alpha":
    let r = parseColor("#f008")
    check r.isOk
    check near(r.get.alpha, 0.5333'f32, 1e-2) # 0x88/255.

  test "malformed hex -> InvalidColor":
    check parseColor("#").isErr and parseColor("#").error.kind == InvalidColor
    check parseColor("#gg").isErr # not hex digits.
    check parseColor("#12345").isErr # 5 digits invalid.
    check parseColor("#1234567").isErr # 7 digits invalid.

suite "parseColor — rgb() / rgba()":
  test "rgb() space-separated numbers -> sRGB":
    let r = parseColor("rgb(255 0 0)")
    check r.isOk
    check r.get.spaceTag == tagSrgb
    let (c0, c1, c2) = r.get.comps
    check near(c0, 1.0) and near(c1, 0.0) and near(c2, 0.0)

  test "rgb() comma-separated (legacy) -> sRGB":
    let r = parseColor("rgb(255, 0, 0)")
    check r.isOk
    let (c0, _, _) = r.get.comps
    check near(c0, 1.0)

  test "rgb() percentages -> sRGB":
    let r = parseColor("rgb(100% 0% 0%)")
    check r.isOk
    let (c0, _, _) = r.get.comps
    check near(c0, 1.0)

  test "rgb() / alpha (CSS Color 4) -> sRGB with alpha":
    let r = parseColor("rgb(255 0 0 / 0.5)")
    check r.isOk
    check near(r.get.alpha, 0.5'f32)

  test "rgba() legacy 4th comma arg -> sRGB with alpha":
    let r = parseColor("rgba(255, 0, 0, 0.5)")
    check r.isOk
    check near(r.get.alpha, 0.5'f32)

  test "malformed rgb -> InvalidColor":
    check parseColor("rgb(255 0)").isErr # too few components.
    check parseColor("rgb(255 0 0 0 0)").isErr # too many.
    check parseColor("rgb()").isErr

suite "parseColor — oklch()":
  test "oklch(L C h) -> OKLCH":
    let r = parseColor("oklch(0.6 0.2 25)")
    check r.isOk
    check r.get.spaceTag == tagOklch
    let (c0, c1, c2) = r.get.comps
    check near(c0, 0.6) and near(c1, 0.2) and near(c2, 25.0)

  test "oklch with / alpha -> OKLCH with alpha":
    let r = parseColor("oklch(0.6 0.2 25 / 0.5)")
    check r.isOk
    check near(r.get.alpha, 0.5'f32)

  test "oklch with deg unit on hue -> parses (h is a number, deg implied)":
    let r = parseColor("oklch(0.6 0.2 25deg)")
    check r.isOk
    let (_, _, c2) = r.get.comps
    check near(c2, 25.0)

  test "oklch none for chroma -> 0 chroma (CSS Color 4 'none' as missing)":
    let r = parseColor("oklch(0.6 none 25)")
    check r.isOk
    let (_, c1, _) = r.get.comps
    check near(c1, 0.0)

  test "malformed oklch -> InvalidColor":
    check parseColor("oklch(0.6 0.2)").isErr # too few.
    check parseColor("oklch(0.6 0.2 25 0.5)").isErr # missing / before alpha.
    check parseColor("oklch()").isErr

suite "parseColor — fuzz (malformed / empty / garbage)":
  test "empty / whitespace -> InvalidColor":
    check parseColor("").isErr
    check parseColor("   ").isErr

  test "garbage -> InvalidColor":
    check parseColor("hello world").isErr
    check parseColor("not a color").isErr

  test "unknown function -> InvalidColor":
    check parseColor("hsl(0 0 0)").isErr # deferred — documented hole.
    check parseColor("foo(1 2 3)").isErr

  test "leading/trailing whitespace tolerated (CSS allows it)":
    check parseColor("  #ff0000  ").isOk
    check parseColor("\toklch(0.6 0.2 25)\n").isOk

  test "NaN / Inf components -> InvalidColor (color() validates)":
    check parseColor("oklch(nan 0.2 25)").isErr
    check parseColor("oklch(0.6 inf 25)").isErr

suite "parseColor — oklch percentages + CSS angle units":
  test "oklch L percentage maps 100% to 1.0":
    let r = parseColor("oklch(60% 0.2 25)")
    check r.isOk
    let (c0, _, _) = r.get.comps
    check near(c0, 0.6)
    let full = parseColor("oklch(100% 0% 25)").get
    let (f0, _, _) = full.comps
    check near(f0, 1.0)
  test "oklch C percentage maps 100% to 0.4":
    let r = parseColor("oklch(0% 100% 25)")
    check r.isOk
    let (_, c1, _) = r.get.comps
    check near(c1, 0.4)
  test "oklch hue turn -> degrees":
    let (_, _, c2) = parseColor("oklch(0.6 0.2 0.25turn)").get.comps
    check near(c2, 90.0)
  test "oklch hue grad -> degrees":
    let (_, _, c2) = parseColor("oklch(0.6 0.2 100grad)").get.comps
    check near(c2, 90.0)
  test "oklch hue rad -> degrees":
    let (_, _, c2) = parseColor("oklch(0.6 0.2 1.5707963rad)").get.comps
    check near(c2, 90.0, 1e-2)
  test "oklch hue bare number is degrees":
    let (_, _, c2) = parseColor("oklch(0.6 0.2 90)").get.comps
    check near(c2, 90.0)

suite "parseColor — rgb syntax (whitespace vs comma, no mixing)":
  test "4th whitespace component (no slash) is rejected":
    check parseColor("rgb(255 0 0 0.5)").isErr
  test "comma + slash alpha is rejected":
    check parseColor("rgb(255, 0, 0 / 0.5)").isErr
  test "extra component before slash is rejected":
    check parseColor("rgb(255 0 0 0 / 0.5)").isErr
  test "whitespace 3 + slash alpha still ok":
    check parseColor("rgb(255 0 0 / 0.5)").isOk

suite "parseColor — malformed numeric tokens (full-token consume)":
  test "trailing garbage on a component is rejected":
    check parseColor("rgb(12abc 0 0)").isErr
    check parseColor("oklch(0.6abc 0.2 25)").isErr
  test "empty component is rejected":
    check parseColor("rgb(255,,0)").isErr
  test "bare percent token is rejected":
    check parseColor("rgb(255 0 %)").isErr
    check parseColor("oklch(0.6 % 25)").isErr
