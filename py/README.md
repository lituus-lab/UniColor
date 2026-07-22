<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# unicolor — Python binding

A Cython extension over the UniColor C ABI. The native library travels inside
the wheel, so installing it needs neither Nim nor a compiler.

## Build & test (from the repo)

```bash
nimble pyLib                                    # native lib for this platform
(cd py && python3 setup.py build_ext --inplace) # build the Cython extension
(cd py && python3 -m pytest -q)                 # test
```

`nimble pyLib` builds the shared lib on Linux/macOS and the MSVC static lib on
Windows, so the same commands work everywhere. The subshells keep your shell's
cwd unchanged. `nimble pyTest` runs all three steps.

## API

`import unicolor as uc` exposes the full engine surface. A failed build (bad
space, bad alpha, NaN component, unknown metric, out-of-range index) raises
`ValueError` — the C sentinel (`tag == uc.TAG_UNKNOWN`) never leaks through.

### Color

```python
red = uc.parse('#ff0000')          # from a CSS Color 4 string
red = uc.srgb(1.0, 0.0, 0.0)       # sRGB factory
c   = uc.oklch(0.65, 0.18, 250.0)   # OKLCH factory
c   = uc.make(uc.TAG_OKLCH, 0.65, 0.18, 250.0, alpha=1.0)

red.tag            # SpaceTag ordinal (see uc.TAG_*)
red.components     # (c0, c1, c2)
red.alpha          # 0..1
red.format_css()   # "oklch(L C h)" (OKLCH form)
red.format_css(legacy=True)  # "#rrggbb" (sRGB hex)

red.convert(uc.TAG_OKLCH)            # change space
red.gamut_map(uc.TAG_SRGB)           # map into a realizable range
```

### Contrast & distance

```python
uc.contrast(uc.parse('#000000'), uc.parse('#ffffff'))             # WCAG 2.2
uc.contrast(uc.parse('#000000'), uc.parse('#ffffff'), metric='apca')
uc.distance(uc.parse('#ff0000'), uc.parse('#00ff00'), 'deltaE_ok')
```

Both are also methods on `Color`: `fg.contrast(bg)`, `a.distance(b, metric)`.

### Theme

A 3-layer token tree (primitives / semantics / components). Each layer is a
list of `(name, color|None, alias|None)` tuples — primitives carry a color,
semantics and components carry an alias.

```python
t = uc.theme(
    [('surface', uc.srgb(1.0, 1.0, 1.0), None),
     ('text',    uc.srgb(0.0, 0.0, 0.0), None)],
    [('text.primary', None, 'text')],
)
t.count                       # total tokens across the three layers
t.has_role('text.primary')    # bool
t.resolve('text.primary')    # -> Color (raises ValueError if undefined / dangling)
t.export('css')               # render to a registered format
t.export('css', legacy=True)  # sRGB hex instead of OKLCH
```

### Palette

An immutable color set. `color_at(i)` indexes the discrete structures;
`sample(t)` reads an ordered ramp at `t in [0,1]`.

```python
p = uc.palette(
    uc.PAL_TAG_ORDERED,
    [uc.parse('#ff0000'), uc.parse('#00ff00'), uc.parse('#0055ff')],
    uc.PAL_INTENT_SEQUENTIAL,
    seed=0,
)
len(p), p.tag, p.intent
p.color_at(1)    # -> Color (raises ValueError out of range / wrong structure)
p.sample(0.5)    # -> Color (raises ValueError out of [0,1] / non-ramp)
```

### Import & validation

```python
j = t.export('json')
t2 = uc.import_theme(j, 'json')          # reconstruct a theme

rep = uc.import_reported(j, 'json')      # diagnostics without the target
rep.format_name, rep.schema_version, rep.warning_count
rep.warning(0)                            # ImportWarningInfo(message) — IndexError if out of range

v = uc.validate_theme(t2)                # run every registered rule
v.score, v.worst, v.rule_count
v.rule(0)                                # Rule(name, severity, metric, threshold, message)
```

`uc.validate_palette(p)` mirrors it for palettes. `uc.import_palette` exists
on the ABI but no importer yields a palette today, so it raises on a kind
mismatch.

## Constants

`uc.TAG_*` (SpaceTag ordinals), `uc.PAL_TAG_*` / `uc.PAL_INTENT_*` (palette
structure and intent), and `uc.SEVERITY_*` (Info/Warning/Error/Fatal) mirror
`include/UniColor.h`.

## The C ABI

The same entry points are reachable from anything that speaks C; see
`include/UniColor.h` and the book. The host must call `uc_init()` once before
any registry-based proc — the Python binding does this on import.