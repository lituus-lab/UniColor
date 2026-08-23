<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# unicolor — WebAssembly binding

An Emscripten build of the UniColor C ABI plus a hand-written ESM glue. The
same engine surface as the Nim / C / Python stacks, usable from Node and the
browser. `load()` instantiates the module and runs `uc_init()` once, so the
contrast / import / export / validation registries are ready before you call
anything.

## Build & test (from the repo)

```bash
nimble wasm        # emcc -> build/wasm/unicolor.{wasm,js} (factory + binary)
nimble wasmTest    # nimble wasm, then node tests/wasm/test_unicolor.js
```

`nimble wasm` needs `emcc` on PATH (emscripten 6.0.x). The dev glue loads the
factory from `../build/wasm/unicolor.js`; `nimble wasmTest` runs the node suite
that mirrors `tests/c`.

## Consuming the release tarball

The release workflow ships `UniColor-vX.Y.Z-wasm.tar.gz` containing
`unicolor.wasm` (the binary), `unicolor.wasm.js` (the Emscripten factory,
renamed from `unicolor.js`), `unicolor.js` (this glue), `unicolor.d.ts`, and a
`package.json` (`{"type":"module"}`). Unpack it anywhere and import the glue:

```js
import { load } from "./unicolor.js";
const uc = await load();
```

The tarball's own `package.json` makes the bundle self-contained ESM, so the
consumer's nearest `type` field — `module`, `commonjs`, or none — cannot force
the wrong parse on the factory.

## API

`uc` exposes the full engine surface. A failed build (bad space, bad alpha, NaN
component, unknown metric, NULL input, NULL handle) raises `Error`; an
out-of-range index raises `RangeError` — the C sentinel (`tag === 0`) and NaN
scalars never leak through.

`Color` is a plain JS value (`tag`, `comps`, `alpha`) — nothing to free. The
handle types (`Theme`, `Palette`, `ImportReport`, `ValidationReport`) wrap a
wasm pointer: call `free()` when done. A `FinalizationRegistry` is a best-effort
backstop, not a guarantee.

### Color

```js
const red = uc.parse('#ff0000');                      // from a CSS Color 4 string
// const red = uc.srgb(1, 0, 0);                       // sRGB factory
// const c   = uc.oklch(0.65, 0.18, 250);               // OKLCH factory
const c   = uc.make(uc.TAG.OKLCH, 0.65, 0.18, 250, 1); // explicit tag + alpha

red.tag            // SpaceTag ordinal (see uc.TAG.*)
red.comps          // [c0, c1, c2]
red.alpha          // 0..1
red.formatCss()    // "oklch(L C h)" (OKLCH form)
red.formatCss(true)  // "#rrggbb" (sRGB hex)

red.convert(uc.TAG.OKLCH)   // change space
red.gamutMap(uc.TAG.SRGB)   // map into a realizable range
```

### Contrast & distance

```js
uc.contrast(uc.parse('#000000'), uc.parse('#ffffff'));            // WCAG 2.2
uc.contrast(uc.parse('#000000'), uc.parse('#ffffff'), 'apca');
uc.distance(uc.parse('#ff0000'), uc.parse('#00ff00'), 'deltaE_ok');
```

Both are also methods on `Color`: `fg.contrast(bg)`, `a.distance(b, metric)`.

### Theme

A 3-layer token tree (primitives / semantics / components). Each layer is an
array of `[name, color|null, alias|null]` tuples (or `{name, color, alias}`
records) — primitives carry a color, semantics and components carry an alias.

```js
const t = uc.theme(
  [['surface', uc.srgb(1, 1, 1), null],
   ['text',    uc.srgb(0, 0, 0), null]],
  [['text.primary', null, 'text']],
);
t.count                       // total tokens across the three layers
t.hasRole('text.primary')     // boolean
t.resolve('text.primary')     // -> Color (throws if undefined / dangling / cycle)
t.export('css')               // render to a registered format
t.export('css', true)         // sRGB hex instead of OKLCH
t.free()
```

### Palette

An immutable color set. `colorAt(i)` indexes the discrete structures;
`sample(t)` reads an ordered ramp at `t in [0,1]`.

```js
const p = uc.palette(
  uc.PAL_TAG.ORDERED,
  [uc.parse('#ff0000'), uc.parse('#00ff00'), uc.parse('#0055ff')],
  uc.PAL_INTENT.SEQUENTIAL,
  0,                          // seed (int64 on the C ABI)
);
p.length, p.tag, p.intent
p.colorAt(1)   // -> Color (RangeError out of range; Error on a wrong structure)
p.sample(0.5)  // -> Color (RangeError out of [0,1] or a non-ramp)
p.free()
```

### Import & validation

```js
const src = uc.theme([['surface', uc.srgb(1, 1, 1), null],
                      ['text',    uc.srgb(0, 0, 0), null]]);
const j   = src.export('json');
const t2  = uc.importTheme(j, 'json');        // reconstruct a theme
src.free();

const rep = uc.importReported(j, 'json');    // diagnostics without the target
rep.formatName, rep.schemaVersion, rep.warningCount;
rep.warning(0);                              // message string (RangeError if out of range)
rep.free();

const v = uc.validateTheme(t2);               // run every registered rule
v.score, v.worst, v.ruleCount;
v.rule(0);   // { name, severity, metric, threshold, message } (RangeError if out of range)
v.free();
t2.free();
```

`uc.validatePalette(p)` mirrors it for palettes. `uc.importPalette` exists on
the ABI but no importer yields a palette today, so it throws on a kind mismatch.

## Constants

`uc.TAG.*` (SpaceTag ordinals), `uc.PAL_TAG.*` / `uc.PAL_INTENT.*` (palette
structure and intent), and `uc.SEVERITY.*` (Info/Warning/Error/Fatal) are frozen
objects mirroring `include/UniColor.h`.

## The C ABI

The same entry points are reachable from anything that speaks C; see
`include/UniColor.h` and the book. The host must call `uc_init()` once before
any registry-based proc — `load()` does this for you.
