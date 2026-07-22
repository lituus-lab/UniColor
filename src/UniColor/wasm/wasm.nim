# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## WASM adapter for the C ABI. Emscripten's generated JS wrappers cannot marshal
## the 20-byte `uc_color` struct by value — neither as a return (`uc_parse`,
## `uc_convert`, `uc_theme_resolve`, ...) nor as an argument (`uc_convert(c, ...)`,
## `uc_contrast(fg, bg)`, `uc_distance(a, b, ...)`). These `uc_wasm_*` procs route
## the color through a pointer instead:
##
## - color-producing procs write the result into a caller-allocated `out` buffer
##   and return nothing; the JS host reads tag / comps / alpha straight from the
##   buffer and treats `tag == 0` as the sentinel;
## - `contrast` / `distance` read their operands from pointers and return the
##   scalar double (NaN on failure, as in the C ABI).
##
## Built via the `nimble wasm` task (Nim -> C -> emcc). The JS glue calls these
## for color ops and the raw `uc_*` for handle / string ops (those take pointers,
## scalars, or measure+fill buffers, all of which emscripten handles). Not
## declared in include/UniColor.h — wasm-internal.
import ../../UniColor
import UniColor/c_api

# Unmangled C symbols, C calling convention, exported from the wasm module.
{.push exportc, cdecl, dynlib.}

# --- color-producing: write the result into `outc` (void) -----------------

proc uc_wasm_parse(outc: ptr UcColor, s: cstring) {.raises: [].} =
  ## Parse a CSS Color 4 string into `outc`. Sentinel (tag 0) on NULL / malformed.
  outc[] = uc_parse(s)

proc uc_wasm_make(outc: ptr UcColor, tag: cint, c0, c1, c2: cfloat,
    alpha: cfloat) {.raises: [].} =
  ## Validating constructor into `outc`. Sentinel on unknown space / bad alpha /
  ## NaN component.
  outc[] = uc_color_make(tag, c0, c1, c2, alpha)

proc uc_wasm_srgb(outc: ptr UcColor, r, g, b: cfloat) {.raises: [].} =
  outc[] = uc_color_srgb(r, g, b)

proc uc_wasm_oklch(outc: ptr UcColor, l, c, h: cfloat) {.raises: [].} =
  outc[] = uc_color_oklch(l, c, h)

proc uc_wasm_convert(outc: ptr UcColor, inc: ptr UcColor,
    target: cint) {.raises: [].} =
  ## Convert the color at `inc` to `target` and write it into `outc`.
  outc[] = uc_convert(inc[], target)

proc uc_wasm_gamut_map(outc: ptr UcColor, inc: ptr UcColor,
    target: cint) {.raises: [].} =
  ## Gamut-map the color at `inc` into `target` and write it into `outc`.
  outc[] = uc_gamut_map(inc[], target)

proc uc_wasm_theme_resolve(t: ptr Theme, outc: ptr UcColor,
    role: cstring) {.raises: [].} =
  ## Resolve `role` on theme `t` into `outc`. Sentinel on NULL / undefined /
  ## dangling / cycle.
  outc[] = uc_theme_resolve(t, role)

proc uc_wasm_palette_color_at(p: ptr Palette, outc: ptr UcColor,
    i: cint) {.raises: [].} =
  outc[] = uc_palette_color_at(p, i)

proc uc_wasm_palette_sample(p: ptr Palette, outc: ptr UcColor,
    t: cdouble) {.raises: [].} =
  outc[] = uc_palette_sample(p, t)

proc uc_wasm_palette_role(p: ptr Palette, outc: ptr UcColor,
    role: cstring) {.raises: [].} =
  outc[] = uc_palette_role(p, role)

# --- scalar-returning: read operands from pointers, return the double ----

proc uc_wasm_contrast(fg, bg: ptr UcColor): cdouble {.raises: [].} =
  ## WCAG 2.2 contrast ratio. NaN on a sentinel operand or a metric failure.
  uc_contrast(fg[], bg[])

proc uc_wasm_contrast_metric(fg, bg: ptr UcColor,
    metric: cstring): cdouble {.raises: [].} =
  ## Contrast under a named metric ("wcag22" / "apca" / "bridgepca"). NaN on
  ## sentinel / NULL metric / unknown / failure.
  uc_contrast_metric(fg[], bg[], metric)

proc uc_wasm_distance(a, b: ptr UcColor, metric: cstring): cdouble {.
    raises: [].} =
  ## Perceptual distance under a named metric. NaN on sentinel / NULL / unknown.
  uc_distance(a[], b[], metric)

# --- string measure+fill: color passed by pointer, buf/size as in the C ABI --

proc uc_wasm_format_css(c: ptr UcColor, legacy: cint, buf: ptr char,
    size: csize_t): csize_t {.raises: [].} =
  ## Format the color at `c` as CSS into `buf` (measure+fill). 0 on a sentinel.
  uc_format_css(c[], legacy, buf, size)

{.pop.}
