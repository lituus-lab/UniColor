# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## WASM adapter for the C ABI. Emscripten cannot marshal the 20-byte `uc_color`
## struct by value, so these `uc_wasm_*` procs route colors through a pointer:
## color-producing procs write into a caller `out` buffer; `contrast`/`distance`
## read operands from pointers and return the scalar double. Wasm-internal —
## not declared in `include/UniColor.h`.
import ../../UniColor
import UniColor/c_api

# Unmangled C symbols, C calling convention, exported from the wasm module.
{.push exportc, cdecl, dynlib.}

# --- color-producing: write the result into `outc` (void) -----------------

proc uc_wasm_parse(outc: ptr UcColor, s: cstring) {.raises: [].} =
  ## Parse a CSS Color 4 string into `outc`.
  outc[] = uc_parse(s)

proc uc_wasm_make(outc: ptr UcColor, tag: cint, c0, c1, c2: cfloat,
    alpha: cfloat) {.raises: [].} =
  ## Validating constructor into `outc`.
  outc[] = uc_color_make(tag, c0, c1, c2, alpha)

proc uc_wasm_srgb(outc: ptr UcColor, r, g, b: cfloat) {.raises: [].} =
  outc[] = uc_color_srgb(r, g, b)

proc uc_wasm_oklch(outc: ptr UcColor, l, c, h: cfloat) {.raises: [].} =
  outc[] = uc_color_oklch(l, c, h)

proc uc_wasm_convert(outc: ptr UcColor, inc: ptr UcColor,
    target: cint) {.raises: [].} =
  ## Convert `inc` to `target` into `outc`.
  outc[] = uc_convert(inc[], target)

proc uc_wasm_gamut_map(outc: ptr UcColor, inc: ptr UcColor,
    target: cint) {.raises: [].} =
  ## Gamut-map `inc` into `target` into `outc`.
  outc[] = uc_gamut_map(inc[], target)

proc uc_wasm_theme_resolve(t: ptr Theme, outc: ptr UcColor,
    role: cstring) {.raises: [].} =
  ## Resolve `role` on `t` into `outc`.
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
  ## WCAG 2.2 contrast ratio.
  uc_contrast(fg[], bg[])

proc uc_wasm_contrast_metric(fg, bg: ptr UcColor,
    metric: cstring): cdouble {.raises: [].} =
  ## Contrast under a named metric.
  uc_contrast_metric(fg[], bg[], metric)

proc uc_wasm_distance(a, b: ptr UcColor, metric: cstring): cdouble {.
    raises: [].} =
  ## Perceptual distance under a named metric.
  uc_distance(a[], b[], metric)

# --- string measure+fill: color passed by pointer, buf/size as in the C ABI --

proc uc_wasm_format_css(c: ptr UcColor, legacy: cint, buf: ptr char,
    size: csize_t): csize_t {.raises: [].} =
  ## Format `c` as CSS into `buf` (measure+fill).
  uc_format_css(c[], legacy, buf, size)

{.pop.}
