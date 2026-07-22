# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## C ABI for UniColor. Built --app:staticlib/--app:lib --noMain --mm:arc -d:release.
## Keep in sync with include/UniColor.h; tests/c links the header against this lib.
## Never raises; every entry point is reentrant and single-threaded. No error codes:
## color-producing procs return a sentinel `uc_color` with `tag == UC_TAG_UNKNOWN`
## (0); numeric procs return NaN on failure; string procs use a measure+fill
## buffer that returns the required length (0 on failure).
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
  UcColor* = object
    comps: array[4, float32]
    tag: int32

  # Layout twin of the C `uc_token` struct: a theme-tree node as the C host
  # passes it (parallel arrays of these become the primitive / semantic /
  # component layers). `name` is the role; a primitive carries its `color` and
  # leaves `alias` NULL, a semantic / component carries its `alias` target and
  # leaves `color` unused. Field order and types match the C struct so an array
  # of `uc_token` can be reinterpreted as `UncheckedArray[UcToken]`.
  UcToken = object
    name: cstring
    color: UcColor
    alias: cstring

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

# Measure+fill buffer writer shared by every string-producing proc. Writes up to
# `size-1` bytes + NUL into `buf` and returns the required length (excl. NUL).
# If `buf` is NULL or `size` is 0, returns the required length without writing.
proc writeBuf(s: string, buf: ptr char, size: csize_t): csize_t {.raises: [].} =
  let req = s.len
  if buf.isNil or size == 0:
    return csize_t(req)
  let arr = cast[ptr UncheckedArray[char]](buf)
  let cap = if csize_t(req) < size: req else: int(size) - 1
  for i in 0 ..< cap:
    arr[i] = s[i]
  arr[cap] = '\0'
  csize_t(req)

# Read a C token array into a Nim ThemeToken seq. Primitives carry their color
# and an empty alias; semantics / components carry their alias target. NULL
# strings become "" (a primitive's alias, or a NULL array -> empty seq).
proc readTokens(a: ptr UcToken, n: csize_t): seq[ThemeToken] {.raises: [].} =
  if a.isNil or n == 0:
    return @[]
  let arr = cast[ptr UncheckedArray[UcToken]](a)
  let last = if n > csize_t(high(int)): high(int) else: int(n) - 1
  result = newSeqOfCap[ThemeToken](last + 1)
  for i in 0 .. last:
    let t = arr[i]
    result.add(ThemeToken(name: if t.name.isNil: "" else: $t.name,
        color: fromUc(t.color), alias: if t.alias.isNil: "" else: $t.alias))

# Read a C uc_color array into a Nim Color seq (NULL / 0 -> empty).
proc readColors(a: ptr UcColor, n: csize_t): seq[Color] {.raises: [].} =
  if a.isNil or n == 0:
    return @[]
  let arr = cast[ptr UncheckedArray[UcColor]](a)
  let last = if n > csize_t(high(int)): high(int) else: int(n) - 1
  result = newSeqOfCap[Color](last + 1)
  for i in 0 .. last:
    result.add(fromUc(arr[i]))

# Box a Nim value on the heap as an opaque C handle (alloc0 + assign). The
# caller owns the pointer; release with `unbox`. Shared by every handle-
# returning proc (theme / palette / import report / validation).
proc box[T](v: T): ptr T {.raises: [].} =
  let p = cast[ptr T](alloc0(sizeof(T)))
  p[] = v
  p

# Release a boxed handle: run its destructor (frees seq / Table storage) then
# the allocation. NULL is a no-op.
proc unbox[T](p: ptr T) {.raises: [].} =
  if not p.isNil:
    `=destroy`(p[])
    dealloc(p)

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

proc uc_color_make*(tag: cint, c0, c1, c2: cfloat, alpha: cfloat): UcColor {.
    raises: [].} =
  ## Validating constructor (wraps `color`). Returns a sentinel uc_color
  ## (`tag == UC_TAG_UNKNOWN`) on rejection: unknown space, alpha ∉ [0,1], or a
  ## NaN/Inf component at bounds. Out-of-gamut components are preserved.
  let r = color(SpaceTag(int32(tag)), float32(c0), float32(c1), float32(c2),
      float32(alpha))
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_color_srgb*(r, g, b: cfloat): UcColor {.raises: [].} =
  ## Opaque sRGB color (alpha 1). Sentinel on NaN/Inf components.
  uc_color_make(cint(id(tagSrgb)), r, g, b, 1.0'f32)

proc uc_color_oklch*(l, c, h: cfloat): UcColor {.raises: [].} =
  ## Opaque OKLCH color (alpha 1). Sentinel on NaN/Inf components.
  uc_color_make(cint(id(tagOklch)), l, c, h, 1.0'f32)

proc uc_parse*(s: cstring): UcColor {.raises: [].} =
  ## Parse a CSS Color 4 string (hex / rgb() / oklch()). Returns the sentinel on
  ## a NULL input, a malformed string, or a deferred form (oklab/lab/lch/color/
  ## hsl/hwb). `s` is NUL-terminated; do not free.
  if s.isNil:
    return ucColorInvalid
  let r = parseColor($s)
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_format_css*(c: UcColor, legacy: cint, buf: ptr char,
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
  writeBuf(formatColorCss(col, legacy != 0), buf, size)

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

proc uc_gamut_map*(c: UcColor, target: cint): UcColor {.raises: [].} =
  ## Gamut-map `c` into the `target` space. Returns the sentinel on a sentinel
  ## input or an unknown target.
  let col = fromUc(c)
  if col.spaceTag == tagUnknown:
    return ucColorInvalid
  let r = gamutMap(col, SpaceTag(int32(target)))
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_convert*(c: UcColor, target: cint): UcColor {.raises: [].} =
  ## Convert `c` to the `target` space (wraps `to`). Returns the sentinel on a
  ## sentinel input or an unknown target.
  let col = fromUc(c)
  if col.spaceTag == tagUnknown:
    return ucColorInvalid
  let r = to(col, SpaceTag(int32(target)))
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_contrast*(fg, bg: UcColor): cdouble {.raises: [].} =
  ## WCAG 2.2 contrast ratio (default metric). NaN on a sentinel operand or a
  ## metric failure.
  let f = fromUc(fg)
  let b = fromUc(bg)
  if f.spaceTag == tagUnknown or b.spaceTag == tagUnknown:
    return NaN
  let r = contrast(f, b)
  if r.isOk: cdouble(r.get) else: NaN

proc uc_contrast_metric*(fg, bg: UcColor, metric: cstring): cdouble {.raises: [].} =
  ## Contrast ratio under a named metric ("wcag22" / "apca" / "bridgepca"). NaN
  ## on a sentinel operand, a NULL metric, an unknown metric, or a failure.
  let f = fromUc(fg)
  let b = fromUc(bg)
  if f.spaceTag == tagUnknown or b.spaceTag == tagUnknown or metric.isNil:
    return NaN
  let r = contrast(f, b, $metric)
  if r.isOk: cdouble(r.get) else: NaN

proc uc_distance*(a, b: UcColor, metric: cstring): cdouble {.raises: [].} =
  ## Perceptual distance under a named metric (deltaE76/94/2000/cmc/ok/itp/jz/
  ## cam16Ucs). NaN on a sentinel operand, a NULL metric, an unknown metric, or
  ## a failure.
  let x = fromUc(a)
  let y = fromUc(b)
  if x.spaceTag == tagUnknown or y.spaceTag == tagUnknown or metric.isNil:
    return NaN
  let r = distance(x, y, $metric)
  if r.isOk: cdouble(r.get) else: NaN

# --- theme handle -----------------------------------------------------

proc uc_theme_make(prim: ptr UcToken, nprim: csize_t, sem: ptr UcToken,
    nsem: csize_t, comp: ptr UcToken, ncomp: csize_t): ptr Theme {.raises: [].} =
  ## Build an immutable 3-layer token tree from parallel C token arrays. Returns
  ## NULL on a validation error (empty name, duplicate role, bad alias). The
  ## caller owns the handle; free it with `uc_theme_free`.
  let r = theme(readTokens(prim, nprim), readTokens(sem, nsem),
      readTokens(comp, ncomp))
  if r.isErr: nil else: box(r.get)

proc uc_theme_free(t: ptr Theme) {.raises: [].} =
  ## Release a theme handle and its token-tree storage. NULL is a no-op.
  unbox(t)

proc uc_theme_resolve*(t: ptr Theme, role: cstring): UcColor {.raises: [].} =
  ## Resolve a role to a color (component -> semantic -> primitive). Returns the
  ## sentinel on a NULL handle / role, an undefined role, a dangling alias, or a
  ## cycle.
  if t.isNil or role.isNil:
    return ucColorInvalid
  let r = t[].resolve($role)
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_theme_count(t: ptr Theme): cint {.raises: [].} =
  ## Total tokens across the three layers (0 for NULL).
  if t.isNil: 0 else: cint(t[].count)

proc uc_theme_has_role(t: ptr Theme, role: cstring): cint {.raises: [].} =
  ## 1 if `role` is defined in any layer, else 0 (0 for NULL handle / role).
  if t.isNil or role.isNil: 0 elif t[].hasRole($role): 1 else: 0

proc uc_theme_export(t: ptr Theme, name: cstring, legacy: cint, buf: ptr char,
    size: csize_t): csize_t {.raises: [].} =
  ## Render the theme to a registered format string ("css", "json", "tailwind",
  ## ...). `legacy` non-zero emits sRGB legacy hex instead of OKLCH. Writes up to
  ## `size-1` bytes + NUL into `buf` and returns the required length (excl. NUL);
  ## measure-only when `buf` is NULL / `size` is 0; 0 on a NULL handle / name or
  ## an unknown format.
  if t.isNil or name.isNil:
    return 0.csize_t
  var opts = defaultExportOpts()
  opts.legacySrgb = legacy != 0
  let r = exportTheme(t[], $name, opts)
  if r.isErr: 0.csize_t else: writeBuf(r.get, buf, size)

# --- palette handle ---------------------------------------------------

proc uc_palette_make(tag: cint, colors: ptr UcColor, ncolors: csize_t,
    intent: cint, seed: int64): ptr Palette {.raises: [].} =
  ## Build an immutable palette from a C color array. `tag` is a UC_PAL_TAG_*
  ## ordinal, `intent` a UC_PAL_INTENT_* ordinal. Returns NULL on an out-of-
  ## range tag/intent or empty colors. The caller owns the handle; free with
  ## `uc_palette_free`. (Semantic role maps are not exposed over this ABI.)
  if tag < 0 or tag > cint(ord(palSemantic)) or intent < 0 or
      intent > cint(ord(intentTerminal)):
    return nil
  let r = palette(cast[PaletteTag](int(tag)), readColors(colors, ncolors),
      cast[PaletteIntent](int(intent)), seed)
  if r.isErr: nil else: box(r.get)

proc uc_palette_free(p: ptr Palette) {.raises: [].} =
  ## Release a palette handle and its color/role storage. NULL is a no-op.
  unbox(p)

proc uc_palette_color_at*(p: ptr Palette, i: cint): UcColor {.raises: [].} =
  ## Discrete index for the five discrete structures. Sentinel on a NULL handle,
  ## a `Continuous`/`Semantic` palette, or an out-of-range index.
  if p.isNil:
    return ucColorInvalid
  let r = p[].colorAt(int(i))
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_palette_sample*(p: ptr Palette, t: cdouble): UcColor {.raises: [].} =
  ## Ordered-ramp sample at `t` in [0,1]. Sentinel on a NULL handle, a non-ramp
  ## structure, or `t` outside [0,1].
  if p.isNil:
    return ucColorInvalid
  let r = p[].sample(t)
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_palette_role*(p: ptr Palette, role: cstring): UcColor {.raises: [].} =
  ## Role access for a `Semantic` palette. Sentinel on a NULL handle/role, a
  ## non-Semantic structure, or an unknown role.
  if p.isNil or role.isNil:
    return ucColorInvalid
  let r = p[].role($role)
  if r.isOk: toUc(r.get) else: ucColorInvalid

proc uc_palette_len(p: ptr Palette): cint {.raises: [].} =
  ## Number of colors (0 for NULL).
  if p.isNil: 0 else: cint(p[].len)

proc uc_palette_tag(p: ptr Palette): cint {.raises: [].} =
  ## The structure tag as a UC_PAL_TAG_* ordinal (0 for NULL).
  if p.isNil: 0 else: cint(ord(p[].tag))

proc uc_palette_intent(p: ptr Palette): cint {.raises: [].} =
  ## The intent as a UC_PAL_INTENT_* ordinal (0 for NULL).
  if p.isNil: 0 else: cint(ord(p[].intent))

# --- import ABI -------------------------------------------------------

proc uc_import_theme(input: cstring, name: cstring, strict: cint): ptr Theme {.
    raises: [].} =
  ## Import `input` as format `name` and return the reconstructed theme. `strict`
  ## non-zero fatal-fails on the first recoverable error. Returns NULL on a NULL
  ## input/name, an unknown importer, a kind mismatch (the format yields a
  ## palette), or a parse failure. The caller owns the handle; free with
  ## `uc_theme_free`.
  if input.isNil or name.isNil:
    return nil
  let r = importTheme($input, $name, ImportOpts(strict: strict != 0))
  if r.isErr: nil else: box(r.get)

proc uc_import_palette(input: cstring, name: cstring,
    strict: cint): ptr Palette {.
    raises: [].} =
  ## Import `input` as format `name` and return the reconstructed palette. Returns
  ## NULL on a NULL input/name, an unknown importer, a kind mismatch (the format
  ## yields a theme), or a parse failure. Free with `uc_palette_free`.
  if input.isNil or name.isNil:
    return nil
  let r = importPalette($input, $name, ImportOpts(strict: strict != 0))
  if r.isErr: nil else: box(r.get)

proc uc_import_reported(input: cstring, name: cstring,
    strict: cint): ptr ImportReport {.raises: [].} =
  ## Import `input` as format `name` and return the full report (target +
  ## warnings + metadata). The report handle owns its target; to obtain the theme
  ## or palette use `uc_import_theme` / `uc_import_palette` — this handle exposes
  ## only the diagnostics (format name, schema version, warnings). Returns NULL
  ## on a NULL input/name or an unknown importer. Free with
  ## `uc_import_report_free`.
  if input.isNil or name.isNil:
    return nil
  let r = importReported($input, $name, ImportOpts(strict: strict != 0))
  if r.isErr: nil else: box(r.get)

proc uc_import_report_free(r: ptr ImportReport) {.raises: [].} =
  ## Release an import-report handle and its target/warnings storage. NULL is a
  ## no-op.
  unbox(r)

proc uc_import_format_name(r: ptr ImportReport, buf: ptr char,
    size: csize_t): csize_t {.raises: [].} =
  ## The format name the importer reconstructed. Measure+fill buffer; 0 on NULL.
  if r.isNil: 0.csize_t else: writeBuf(r[].formatName, buf, size)

proc uc_import_schema_version(r: ptr ImportReport, buf: ptr char,
    size: csize_t): csize_t {.raises: [].} =
  ## The schema version read from the source ("" if the format carries none).
  ## Measure+fill buffer; 0 on NULL.
  if r.isNil: 0.csize_t else: writeBuf(r[].schemaVersion, buf, size)

proc uc_import_warning_count(r: ptr ImportReport): cint {.raises: [].} =
  ## Number of recoverable warnings in the report (0 for NULL).
  if r.isNil: 0 else: cint(r[].warnings.len)

proc uc_import_warning(r: ptr ImportReport, i: cint, buf: ptr char,
    size: csize_t): csize_t {.raises: [].} =
  ## The message of warning `i`. Measure+fill buffer; 0 on a NULL handle or an
  ## out-of-range index.
  if r.isNil:
    return 0.csize_t
  let idx = int(i)
  if idx < 0 or idx >= r[].warnings.len:
    return 0.csize_t
  writeBuf(r[].warnings[idx].message, buf, size)

# --- validation ABI --------------------------------------------------

proc uc_validate_theme(t: ptr Theme): ptr ValidationReport {.raises: [].} =
  ## Run every registered theme rule and return the report. NULL on a NULL
  ## handle. The caller owns the handle; free with `uc_validation_free`.
  if t.isNil: nil else: box(validateTheme(t[]))

proc uc_validate_palette(p: ptr Palette): ptr ValidationReport {.raises: [].} =
  ## Run every registered palette rule and return the report. NULL on a NULL
  ## handle. Free with `uc_validation_free`.
  if p.isNil: nil else: box(validatePalette(p[]))

proc uc_validation_free(r: ptr ValidationReport) {.raises: [].} =
  ## Release a validation-report handle and its rule-result storage. NULL is a
  ## no-op.
  unbox(r)

proc uc_validation_score(r: ptr ValidationReport): cint {.raises: [].} =
  ## 0..100 score (0 for NULL).
  if r.isNil: 0 else: cint(r[].score)

proc uc_validation_worst(r: ptr ValidationReport): cint {.raises: [].} =
  ## Worst severity as a UC_SEVERITY_* ordinal (0 for NULL).
  if r.isNil: 0 else: cint(ord(r[].worst))

proc uc_validation_rule_count(r: ptr ValidationReport): cint {.raises: [].} =
  ## Number of rule results (0 for NULL).
  if r.isNil: 0 else: cint(r[].results.len)

proc uc_validation_rule_name(r: ptr ValidationReport, i: cint, buf: ptr char,
    size: csize_t): csize_t {.raises: [].} =
  ## Rule `i`'s name. Measure+fill buffer; 0 on a NULL handle or out-of-range.
  if r.isNil:
    return 0.csize_t
  let idx = int(i)
  if idx < 0 or idx >= r[].results.len:
    return 0.csize_t
  writeBuf(r[].results[idx].name, buf, size)

proc uc_validation_rule_severity(r: ptr ValidationReport, i: cint): cint {.
    raises: [].} =
  ## Rule `i`'s severity as a UC_SEVERITY_* ordinal (0 on NULL / out-of-range).
  if r.isNil:
    return 0
  let idx = int(i)
  if idx < 0 or idx >= r[].results.len:
    return 0
  cint(ord(r[].results[idx].severity))

proc uc_validation_rule_metric(r: ptr ValidationReport, i: cint): cdouble {.
    raises: [].} =
  ## Rule `i`'s measured metric (NaN when the rule has none). NaN on NULL /
  ## out-of-range.
  if r.isNil:
    return NaN
  let idx = int(i)
  if idx < 0 or idx >= r[].results.len:
    return NaN
  cdouble(r[].results[idx].metric)

proc uc_validation_rule_threshold(r: ptr ValidationReport, i: cint): cdouble {.
    raises: [].} =
  ## Rule `i`'s pass boundary. NaN on NULL / out-of-range.
  if r.isNil:
    return NaN
  let idx = int(i)
  if idx < 0 or idx >= r[].results.len:
    return NaN
  cdouble(r[].results[idx].threshold)

proc uc_validation_rule_message(r: ptr ValidationReport, i: cint, buf: ptr char,
    size: csize_t): csize_t {.raises: [].} =
  ## Rule `i`'s human-readable message. Measure+fill buffer; 0 on a NULL handle
  ## or out-of-range.
  if r.isNil:
    return 0.csize_t
  let idx = int(i)
  if idx < 0 or idx >= r[].results.len:
    return 0.csize_t
  writeBuf(r[].results[idx].message, buf, size)

{.pop.}
