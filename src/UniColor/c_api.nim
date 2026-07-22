# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## C ABI for UniColor. Built --app:staticlib/--app:lib --noMain --mm:arc -d:release.
## Keep in sync with include/UniColor.h; tests/c links the header against this lib.
## Never raises; every entry point is reentrant and single-threaded. No error codes:
## color-producing procs return a sentinel `uc_color` with `tag == UC_TAG_UNKNOWN`
## (0); numeric procs return NaN on failure; string procs use a measure+fill
## buffer that returns the required length (0 on failure).
import std/math
import ../UniColor

const
  AbiMajor = 0
  AbiMinor = 1
  AbiPatch = 0

# Layout twin of the C `uc_color` struct (include/UniColor.h): 4 float32
# components (3 chromatic + alpha) + the SpaceTag as a raw int32. 20 bytes, POD,
# no GC — passed and returned by value across the C ABI. The sentinel
# `tag == 0` (tagUnknown) is the failure marker for color-producing procs; the
# validating `color()` ctor never emits it, so a caller can trust a non-zero tag.
type
  UcColor = object
    comps: array[4, float32]
    tag: int32

const ucColorInvalid = UcColor(comps: [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32], tag: 0)

# Marshal a Nim Color to its C layout twin. Copies through the public accessors
# (Color fields are private to core/color) — never reinterprets memory.
proc toUc(c: Color): UcColor {.raises: [].} =
  UcColor(comps: [c.comp(0), c.comp(1), c.comp(2), c.alpha], tag: id(c.spaceTag))

# Marshal a C uc_color back to a Nim Color via the validating ctor. Returns the
# zero Color (tagUnknown) on any rejection — callers translate that to the C
# sentinel by checking `spaceTag == tagUnknown`.
proc fromUc(u: UcColor): Color {.raises: [].} =
  let r = color(SpaceTag(u.tag), u.comps[0], u.comps[1], u.comps[2], u.comps[3])
  if r.isOk: r.get else: Color()

# Nim's module initializers, emitted as the C `NimMain` under --noMain. The
# contrast / import / export / spaces / validation registries are populated by
# top-level `discard registerX(...)` side effects, so a host program MUST call
# `uc_init` once before any registry-based proc.
proc nimMainC() {.importc: "NimMain", cdecl, raises: [].}

# Unmangled C symbols, C calling convention, exported from the shared lib.
{.push exportc, cdecl, dynlib.}

proc uc_init() {.raises: [].} =
  ## Run Nim module initializers — populates the contrast / import / export /
  ## spaces / validation registries. Call once before any registry-based proc.
  nimMainC()

proc uc_version(): cstring =
  ## Static version string; do not free.
  UniColorVersion.cstring

proc uc_abi_major(): cint = AbiMajor.cint
proc uc_abi_minor(): cint = AbiMinor.cint
proc uc_abi_patch(): cint = AbiPatch.cint

# --- color core -------------------------------------------------------

proc uc_color_make(tag: cint, c0, c1, c2: cfloat, alpha: cfloat): UcColor {.
    raises: [].} =
  ## Validating constructor (wraps `color`). Returns a sentinel uc_color
  ## (`tag == UC_TAG_UNKNOWN`) on rejection: unknown space, alpha ∉ [0,1], or a
  ## NaN/Inf component at bounds. Out-of-gamut components are preserved.
  let r = color(SpaceTag(int32(tag)), float32(c0), float32(c1), float32(c2),
      float32(alpha))
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_color_srgb(r, g, b: cfloat): UcColor {.raises: [].} =
  ## Opaque sRGB color (alpha 1). Sentinel on NaN/Inf components.
  uc_color_make(cint(id(tagSrgb)), r, g, b, 1.0'f32)

proc uc_color_oklch(l, c, h: cfloat): UcColor {.raises: [].} =
  ## Opaque OKLCH color (alpha 1). Sentinel on NaN/Inf components.
  uc_color_make(cint(id(tagOklch)), l, c, h, 1.0'f32)

proc uc_parse(s: cstring): UcColor {.raises: [].} =
  ## Parse a CSS Color 4 string (hex / rgb() / oklch()). Returns the sentinel on
  ## a NULL input, a malformed string, or a deferred form (oklab/lab/lch/color/
  ## hsl/hwb). `s` is NUL-terminated; do not free.
  if s.isNil:
    return ucColorInvalid
  let r = parseColor($s)
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_format_css(c: UcColor, legacy: cint, buf: ptr char,
    size: csize_t): csize_t {.
    raises: [].} =
  ## Format a color as CSS: `#rrggbb[aa]` when `legacy` is non-zero, else
  ## `oklch(L C h[/a])`. Writes up to `size-1` bytes + NUL into `buf` and returns
  ## the required length (excl. NUL). If `buf` is NULL or `size` is 0, returns
  ## the required length without writing. A sentinel `c` formats as the empty
  ## string (length 0). Never raises.
  if c.tag == 0:
    return 0.csize_t
  let col = fromUc(c)
  if col.spaceTag == tagUnknown:
    return 0.csize_t
  let s = formatColorCss(col, legacy != 0)
  let req = s.len
  if buf.isNil or size == 0:
    return csize_t(req)
  let arr = cast[ptr UncheckedArray[char]](buf)
  let cap = if csize_t(req) < size: req else: int(size) - 1
  for i in 0 ..< cap:
    arr[i] = s[i]
  arr[cap] = '\0'
  csize_t(req)

proc uc_color_components(c: UcColor, c0, c1, c2: ptr cfloat) {.raises: [].} =
  ## Write the 3 chromatic components. A sentinel `c` writes zeros. Null `c0`/
  ## `c1`/`c2` is undefined.
  c0[] = c.comps[0]
  c1[] = c.comps[1]
  c2[] = c.comps[2]

proc uc_color_alpha(c: UcColor): cfloat {.raises: [].} =
  ## Alpha straight [0,1] (0 for the sentinel).
  c.comps[3]

proc uc_color_tag(c: UcColor): cint {.raises: [].} =
  ## The SpaceTag as a raw int32 (UC_TAG_UNKNOWN == 0 for the sentinel).
  cint(c.tag)

proc uc_gamut_map(c: UcColor, target: cint): UcColor {.raises: [].} =
  ## Gamut-map `c` into the `target` space. Returns the sentinel on a sentinel
  ## input or an unknown target.
  let col = fromUc(c)
  if col.spaceTag == tagUnknown:
    return ucColorInvalid
  let r = gamutMap(col, SpaceTag(int32(target)))
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_convert(c: UcColor, target: cint): UcColor {.raises: [].} =
  ## Convert `c` to the `target` space (wraps `to`). Returns the sentinel on a
  ## sentinel input or an unknown target.
  let col = fromUc(c)
  if col.spaceTag == tagUnknown:
    return ucColorInvalid
  let r = to(col, SpaceTag(int32(target)))
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_contrast(fg, bg: UcColor): cdouble {.raises: [].} =
  ## WCAG 2.2 contrast ratio (default metric). NaN on a sentinel operand or a
  ## metric failure.
  let f = fromUc(fg)
  let b = fromUc(bg)
  if f.spaceTag == tagUnknown or b.spaceTag == tagUnknown:
    return NaN
  let r = contrast(f, b)
  if r.isOk: cdouble(r.get) else: NaN

proc uc_contrast_metric(fg, bg: UcColor, metric: cstring): cdouble {.raises: [].} =
  ## Contrast ratio under a named metric ("wcag22" / "apca" / "bridgepca"). NaN
  ## on a sentinel operand, a NULL metric, an unknown metric, or a failure.
  let f = fromUc(fg)
  let b = fromUc(bg)
  if f.spaceTag == tagUnknown or b.spaceTag == tagUnknown or metric.isNil:
    return NaN
  let r = contrast(f, b, $metric)
  if r.isOk: cdouble(r.get) else: NaN

proc uc_distance(a, b: UcColor, metric: cstring): cdouble {.raises: [].} =
  ## Perceptual distance under a named metric (deltaE76/94/2000/cmc/ok/itp/jz/
  ## cam16Ucs). NaN on a sentinel operand, a NULL metric, an unknown metric, or
  ## a failure.
  let x = fromUc(a)
  let y = fromUc(b)
  if x.spaceTag == tagUnknown or y.spaceTag == tagUnknown or metric.isNil:
    return NaN
  let r = distance(x, y, $metric)
  if r.isOk: cdouble(r.get) else: NaN

{.pop.}
