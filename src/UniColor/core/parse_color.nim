# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# parse_color — CSS Color 4 string → Color parser.
# `parseColor(s): Result[Color, ColorError]` reads a CSS Color 4 color string
# and returns a `Color` tagged by its NATIVE space (no conversion — the color is
# what the string says: oklch → tagOklch, hex/rgb → tagSrgb). The reconstructed
# theme/palette carries the colors as-is; a later conversion (if the caller wants
# a common space) is explicit, not hidden in parse.
#
# Scope (what UniColor emits + the common third-party CSS form):
#   - hex: `#rrggbb`, `#rrggbbaa`, `#rgb`, `#rgba` (case-insensitive digits);
#   - `rgb()` / `rgba()`: numbers 0-255 OR percentages. Whitespace syntax takes
#     alpha via CSS Color 4 `/ a`; comma syntax takes a legacy 4th comma arg.
#     The two do not mix (comma rejects `/`).
#   - `oklch(L C h / a)`: the modern perceptual form (UniColor's default emit).
#     L/C as number or % (100% L = 1.0, 100% C = 0.4); h a CSS angle.
# DEFERRED (documented spec hole — no UniColor exporter emits them, so YAGNI
# until a third-party importer needs them): `oklab()`, `lab()`, `lch()`,
# `color()`, `hsl()`/`hwb()`. `none` is honored as a missing component (0)
# inside the supported forms.
#
# Malformed input → `err InvalidColor`. Inverse of `formatColorCss` (serialize
# layer) for the supported forms.

import std/strutils
import std/parseutils
import std/math
import UniColor/core/result
import UniColor/core/color
import UniColor/core/color_error
import UniColor/core/space_tag

# Trim surrounding whitespace (CSS allows it).
proc trim(s: string): string {.raises: [].} = s.strip()

# A single hex digit value, or -1 if not a hex digit.
proc hexDigit(c: char): int {.raises: [].} =
  if c in {'0'..'9'}:
    int(c) - int('0')
  elif c in {'a'..'f'}:
    int(c) - int('a') + 10
  elif c in {'A'..'F'}:
    int(c) - int('A') + 10
  else:
    -1

# Parse a hex color `#rrggbb` / `#rrggbbaa` / `#rgb` / `#rgba` (digits after the `#`).
# Returns the sRGB Color or `InvalidColor`. Short forms expand each digit doubled
# (`#f00` = `#ff0000`).
proc parseHex(rest: string): Result[Color, ColorError] {.raises: [].} =
  if rest.len != 3 and rest.len != 4 and rest.len != 6 and rest.len != 8:
    return err[Color, ColorError](colorError(InvalidColor,
        "parseColor: hex must have 3, 4, 6 or 8 digits, got " & $rest.len, "parseColor"))
  var
    digits: string
  # Expand short forms by doubling each digit.
  if rest.len == 3 or rest.len == 4:
    for c in rest:
      digits.add(c)
      digits.add(c)
  else:
    digits = rest
  # Validate every digit is hex.
  for c in digits:
    if hexDigit(c) < 0:
      return err[Color, ColorError](colorError(InvalidColor,
          "parseColor: non-hex digit '" & c & "' in color", "parseColor"))
  let
    r = float32(hexDigit(digits[0]) * 16 + hexDigit(digits[1])) / 255.0'f32
    g = float32(hexDigit(digits[2]) * 16 + hexDigit(digits[3])) / 255.0'f32
    b = float32(hexDigit(digits[4]) * 16 + hexDigit(digits[5])) / 255.0'f32
  var a = 1.0'f32
  if digits.len == 8:
    a = float32(hexDigit(digits[6]) * 16 + hexDigit(digits[7])) / 255.0'f32
  color(tagSrgb, r, g, b, a)

# Parse a numeric component: a float, or `none` (0.0, outOk=true). On a parse
# error (bad `%`, non-numeric, partial consume) sets `outOk=false`, returns 0.0.
proc parseComp(tok: string, isPctOk: bool, pctScale: float32,
    outOk: var bool): float32 {.raises: [].} =
  let t = tok.strip()
  if t.len == 0:
    outOk = false
    return 0.0'f32
  if t.toLowerAscii() == "none":
    outOk = true
    return 0.0'f32
  if t[^1] == '%':
    if not isPctOk:
      outOk = false
      return 0.0'f32
    if t.len < 2: # bare "%" — no number before the suffix
      outOk = false
      return 0.0'f32
    let numTok = t[0 ..< ^1]
    var n = 0.0
    if parseFloat(numTok, n) != numTok.len:
      outOk = false
      return 0.0'f32
    outOk = true
    return float32(n) * pctScale / 100.0'f32
  var n = 0.0
  if parseFloat(t, n) != t.len:
    outOk = false
    return 0.0'f32
  outOk = true
  float32(n)

# Parse `rgb(r g b / a)` / `rgb(r, g, b, a)` / `rgba(...)` body (without the
# `rgb(`/`rgba(` wrapper and the closing `)`). Components: numbers 0-255 or %;
# alpha 0-1 or 0-100%.
proc parseRgbBody(body: string): Result[Color, ColorError] {.raises: [].} =
  # Split alpha on `/` (CSS Color 4). If no `/`, alpha is the legacy 4th comma
  # arg or defaults 1.
  var
    compPart = body
    alphaStr = ""
    hasAlpha = false
  if '/' in body:
    let parts = body.split('/')
    if parts.len != 2:
      return err[Color, ColorError](colorError(InvalidColor,
          "parseColor: rgb() with multiple '/'", "parseColor"))
    compPart = parts[0]
    alphaStr = parts[1]
    hasAlpha = true
  # Split components: commas (legacy) or whitespace (CSS Color 4). The two
  # syntaxes do not mix — comma syntax takes a 4th comma arg as alpha and
  # rejects `/`; whitespace syntax takes exactly 3 (alpha via `/` only).
  let isComma = ',' in compPart
  if isComma and hasAlpha:
    return err[Color, ColorError](colorError(InvalidColor,
        "parseColor: rgb() comma syntax cannot use '/' alpha", "parseColor"))
  var toks: seq[string]
  if isComma:
    toks = compPart.split(',')
    if toks.len < 3 or toks.len > 4:
      return err[Color, ColorError](colorError(InvalidColor,
          "parseColor: rgb() comma syntax needs 3 components, got " & $toks.len, "parseColor"))
    if toks.len == 4:
      alphaStr = toks[3]
      hasAlpha = true
  else:
    toks = compPart.splitWhitespace()
    if toks.len != 3:
      return err[Color, ColorError](colorError(InvalidColor,
          "parseColor: rgb() whitespace syntax needs 3 components, got " &
          $toks.len, "parseColor"))
  var ok = true
  let r = parseComp(toks[0], isPctOk = true, pctScale = 255.0'f32, outOk = ok)
  if not ok:
    return err[Color, ColorError](colorError(InvalidColor,
        "parseColor: bad rgb red component '" & toks[0] & "'", "parseColor"))
  let g = parseComp(toks[1], isPctOk = true, pctScale = 255.0'f32, outOk = ok)
  if not ok:
    return err[Color, ColorError](colorError(InvalidColor,
        "parseColor: bad rgb green component '" & toks[1] & "'", "parseColor"))
  let b = parseComp(toks[2], isPctOk = true, pctScale = 255.0'f32, outOk = ok)
  if not ok:
    return err[Color, ColorError](colorError(InvalidColor,
        "parseColor: bad rgb blue component '" & toks[2] & "'", "parseColor"))
  var a = 1.0'f32
  if hasAlpha:
    a = parseComp(alphaStr.strip(), isPctOk = true, pctScale = 1.0'f32, outOk = ok)
    if not ok:
      return err[Color, ColorError](colorError(InvalidColor,
          "parseColor: bad rgb alpha '" & alphaStr & "'", "parseColor"))
  color(tagSrgb, r / 255.0'f32, g / 255.0'f32, b / 255.0'f32, a)

# Parse a CSS `<angle>` (hue) to degrees. Units: turn (*360), grad (*0.9),
# rad (*180/pi), deg or a bare number (already degrees). `none` -> 0.0. The full
# numeric token must be consumed. `grad` is checked before `rad` so `100grad` is
# not read as `100` + `rad`. Defined before `parseOklchBody` (Nim resolves a proc
# only after its definition point within a module).
proc parseHue(tok: string, outOk: var bool): float32 {.raises: [].} =
  let t = tok.strip()
  if t.len == 0:
    outOk = false
    return 0.0'f32
  if t.toLowerAscii() == "none":
    outOk = true
    return 0.0'f32
  const units: array[4, (string, float64)] = [("turn", 360.0), ("grad", 0.9),
      ("rad", 180.0 / PI), ("deg", 1.0)]
  let low = t.toLowerAscii()
  for (suffix, scale) in units:
    if low.endsWith(suffix) and t.len > suffix.len:
      let numTok = t[0 ..< ^suffix.len]
      var n = 0.0
      if parseFloat(numTok, n) != numTok.len:
        outOk = false
        return 0.0'f32
      outOk = true
      return float32(n * scale)
  var n = 0.0
  if parseFloat(t, n) != t.len:
    outOk = false
    return 0.0'f32
  outOk = true
  float32(n)

# Parse `oklch(L C h / a)` body (without the wrapper and closing `)`). L and C
# are numbers or percentages (100% L = 1.0, 100% C = 0.4); h is a CSS angle (deg,
# turn, rad, grad; a bare number is degrees). `none` becomes 0.0. Alpha via
# `/ a`.
proc parseOklchBody(body: string): Result[Color, ColorError] {.raises: [].} =
  var
    compPart = body
    alphaStr = ""
    hasAlpha = false
  if '/' in body:
    let parts = body.split('/')
    if parts.len != 2:
      return err[Color, ColorError](colorError(InvalidColor,
          "parseColor: oklch() with multiple '/'", "parseColor"))
    compPart = parts[0]
    alphaStr = parts[1]
    hasAlpha = true
  let toks = compPart.splitWhitespace()
  if toks.len != 3:
    return err[Color, ColorError](colorError(InvalidColor,
        "parseColor: oklch() needs L C h, got " & $toks.len & " components", "parseColor"))
  var ok = true
  let l = parseComp(toks[0], isPctOk = true, pctScale = 1.0'f32, outOk = ok)
  if not ok:
    return err[Color, ColorError](colorError(InvalidColor,
        "parseColor: bad oklch L '" & toks[0] & "'", "parseColor"))
  let c = parseComp(toks[1], isPctOk = true, pctScale = 0.4'f32, outOk = ok)
  if not ok:
    return err[Color, ColorError](colorError(InvalidColor,
        "parseColor: bad oklch C '" & toks[1] & "'", "parseColor"))
  let h = parseHue(toks[2], ok)
  if not ok:
    return err[Color, ColorError](colorError(InvalidColor,
        "parseColor: bad oklch h '" & toks[2] & "'", "parseColor"))
  var a = 1.0'f32
  if hasAlpha:
    a = parseComp(alphaStr.strip(), isPctOk = true, pctScale = 1.0'f32, outOk = ok)
    if not ok:
      return err[Color, ColorError](colorError(InvalidColor,
          "parseColor: bad oklch alpha '" & alphaStr & "'", "parseColor"))
  color(tagOklch, l, c, h, a)

proc parseChecked(s: string): Result[Color, ColorError] {.raises: [].} =
  ## The parse itself. `parseColor` asserts the postcondition over what this
  ## returns; keeping the two apart is what lets both carry `raises: []`.
  block:
    let t = trim(s)
    if t.len == 0:
      return err[Color, ColorError](colorError(InvalidColor,
          "parseColor: empty color string", "parseColor"))
    if t[0] == '#':
      return parseHex(t[1 ..< t.len])
    let low = t.toLowerAscii()
    if low.startsWith("oklch(") and t[^1] == ')':
      return parseOklchBody(t[6 ..< ^1])
    if (low.startsWith("rgb(") or low.startsWith("rgba(")) and t[^1] == ')':
      # Strip the function name + `(`; the body is everything up to the closing `)`.
      let openParen = t.find('(')
      return parseRgbBody(t[openParen + 1 ..< ^1])
    # Deferred forms (oklab/lab/lch/color/hsl/hwb) fall through to InvalidColor.
    err[Color, ColorError](colorError(InvalidColor,
        "parseColor: unsupported color form '" & t & "'", "parseColor"))

proc parseColor*(s: string): Result[Color, ColorError] {.raises: [].} =
  ## Parse a CSS Color 4 color string into a `Color` tagged by its native space.
  ## Supports hex, `rgb()`/`rgba()`, `oklch()`. DEFERRED (documented hole):
  ## oklab/lab/lch/color/hsl/hwb. Malformed input -> `err InvalidColor`. The
  ## inverse of `formatColorCss` for the supported forms.
  ##
  ## The postcondition is asserted here rather than written as a NimContracts
  ## `ensure`: that wraps the body in `try/except Exception` to know whether an
  ## exception is in flight, which the compiler reads as "this can raise
  ## Exception" and `raises: []` then rejects. The check is the same one, over
  ## the returned value, and compiles away under -d:release.
  result = parseChecked(s)
  when not defined(release):
    doAssert (result.isOk and spaceTag(result.get) != tagUnknown) or
      (result.isErr and result.error.kind == InvalidColor),
      "parseColor: a result is either a color in a known space, or an " &
      "InvalidColor error"


