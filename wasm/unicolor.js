// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
//
// Hand-written ESM binding over the UniColor C ABI, loaded through the
// Emscripten module built by `nimble wasm`. `load()` instantiates the wasm,
// runs `uc_init` once (populating the contrast / spaces / import / export /
// validation registries), and returns the API object.
//
// Color is a plain JS value (tag + comps + alpha) — no native memory to free.
// The handle types (Theme / Palette / ImportReport / ValidationReport) wrap a
// wasm pointer: call `free()` when done. A FinalizationRegistry is a best-effort
// backstop, not a guarantee — do not rely on it.
//
// The error model mirrors the Python binding: a C sentinel color (tag 0) or a
// NaN scalar raises Error; an out-of-range index raises RangeError; a NULL
// handle from a build / import / validate call raises Error.

const COLOR_SIZE = 20; // 4 * float32 (comps + alpha) + int32 (tag)
const TOKEN_SIZE = 28; // wasm32 uc_token: ptr(4) + color(20) + ptr(4)

// SpaceTag / PaletteTag / PaletteIntent / Severity ordinals, mirrored from
// include/UniColor.h so callers write `uc.TAG.OKLCH` without C #defines.
const TAG = Object.freeze({
  UNKNOWN: 0, SRGB: 1, SRGB_LIN: 2, P3: 3, P3_LIN: 4, REC2020: 5,
  REC2020_LIN: 6, A98: 7, A98_LIN: 8, PROPHOTO: 9, PROPHOTO_LIN: 10,
  XYZ: 11, XYY: 12, LAB: 13, LCH: 14, OKLAB: 15, OKLCH: 16, HSV: 17,
  HSL: 18, HWB: 19, CMYK: 20, YCBCR: 21, ICTCP: 22, JZAZBZ: 23,
  CAM16: 24, CAM16_UCS: 25, HCT: 26,
});
const PAL_TAG = Object.freeze({
  ORDERED: 0, UNORDERED: 1, SCIENTIFIC: 2, TERMINAL: 3, CATEGORICAL: 4,
  CONTINUOUS: 5, SEMANTIC: 6,
});
const PAL_INTENT = Object.freeze({
  QUALITATIVE: 0, SEQUENTIAL: 1, DIVERGING: 2, UI: 3, SCIENTIFIC: 4,
  CATEGORICAL: 5, TERMINAL: 6,
});
const SEVERITY = Object.freeze({ INFO: 0, WARNING: 1, ERROR: 2, FATAL: 3 });

// Locate the Emscripten MODULARIZE factory. Two layouts:
//   - repo dev:  ../build/wasm/unicolor.js  (beside this glue in wasm/)
//   - release:   ./unicolor.wasm.js          (factory renamed in the tarball)
async function loadFactory() {
  const here = import.meta.url;
  const candidates = [
    new URL("../build/wasm/unicolor.js", here).href,
    new URL("./unicolor.wasm.js", here).href,
  ];
  let lastErr;
  for (const url of candidates) {
    try {
      const mod = await import(url);
      return mod.default ?? mod;
    } catch (e) { lastErr = e; }
  }
  throw new Error("unicolor: emscripten module not found\n" + lastErr);
}

// Load and initialize the module. Resolves to the API object.
export async function load() {
  const factory = await loadFactory();
  const M = await factory();
  M._uc_init();
  return makeApi(M);
}

function makeApi(M) {
  // --- low-level marshalling -------------------------------------------

  // Allocate + UTF8-encode a JS string on the wasm heap. Caller frees.
  function cstr(s) {
    const n = M.lengthBytesUTF8(s) + 1;
    const p = M._malloc(n);
    M.stringToUTF8(s, p, n);
    return p;
  }

  function writeColor(c, p) {
    M.setValue(p, c.comps[0], "float");
    M.setValue(p + 4, c.comps[1], "float");
    M.setValue(p + 8, c.comps[2], "float");
    M.setValue(p + 12, c.alpha, "float");
    M.setValue(p + 16, c.tag, "i32");
  }

  function readColor(p) {
    const tag = M.getValue(p + 16, "i32");
    if (tag === 0) return null; // sentinel
    return new Color(
      tag,
      [M.getValue(p, "float"), M.getValue(p + 4, "float"),
       M.getValue(p + 8, "float")],
      M.getValue(p + 12, "float"));
  }

  // Run a color-producing adapter into a scratch buffer; return a Color or
  // throw on the sentinel.
  function colorOut(fn) {
    const p = M._malloc(COLOR_SIZE);
    fn(p);
    const c = readColor(p);
    M._free(p);
    if (c) return c;
    throw new Error("unicolor: color op returned the sentinel");
  }

  // measure-then-fill for the C string procs (buf == 0 / size == 0 measures).
  function measureFill(measure, fill) {
    const need = measure();
    if (need === 0) return "";
    const buf = M._malloc(need + 1);
    fill(buf, need + 1);
    const s = M.UTF8ToString(buf);
    M._free(buf);
    return s;
  }

  // --- Color (plain JS value; no native memory) ------------------------

  class Color {
    constructor(tag, comps, alpha = 1) {
      this.tag = tag;
      this.comps = comps;
      this.alpha = alpha;
      if (tag === 0) throw new Error("unicolor: invalid color (sentinel)");
    }

    static parse(s) {
      return colorOut((p) => {
        const sp = cstr(s);
        M._uc_wasm_parse(p, sp);
        M._free(sp);
      });
    }
    static srgb(r, g, b) {
      return colorOut((p) => M._uc_wasm_srgb(p, r, g, b));
    }
    static oklch(l, c, h) {
      return colorOut((p) => M._uc_wasm_oklch(p, l, c, h));
    }
    static make(tag, c0, c1, c2, alpha = 1) {
      return colorOut((p) => M._uc_wasm_make(p, tag, c0, c1, c2, alpha));
    }

    get components() { return this.comps; }

    convert(target) {
      return colorOut((out) => {
        const inp = M._malloc(COLOR_SIZE);
        writeColor(this, inp);
        M._uc_wasm_convert(out, inp, target);
        M._free(inp);
      });
    }
    gamutMap(target) {
      return colorOut((out) => {
        const inp = M._malloc(COLOR_SIZE);
        writeColor(this, inp);
        M._uc_wasm_gamut_map(out, inp, target);
        M._free(inp);
      });
    }

    formatCss(legacy = false) {
      const inp = M._malloc(COLOR_SIZE);
      writeColor(this, inp);
      const leg = legacy ? 1 : 0;
      const s = measureFill(
        () => M._uc_wasm_format_css(inp, leg, 0, 0),
        (buf, sz) => M._uc_wasm_format_css(inp, leg, buf, sz));
      M._free(inp);
      return s;
    }

    contrast(bg, metric = null) {
      const fgp = M._malloc(COLOR_SIZE), bgp = M._malloc(COLOR_SIZE);
      writeColor(this, fgp);
      writeColor(bg, bgp);
      let v;
      if (metric == null) {
        v = M._uc_wasm_contrast(fgp, bgp);
      } else {
        const mp = cstr(metric);
        v = M._uc_wasm_contrast_metric(fgp, bgp, mp);
        M._free(mp);
      }
      M._free(fgp);
      M._free(bgp);
      if (v !== v) throw new Error("unicolor: contrast failed (sentinel or bad metric)");
      return v;
    }

    distance(other, metric) {
      const ap = M._malloc(COLOR_SIZE), bp = M._malloc(COLOR_SIZE);
      writeColor(this, ap);
      writeColor(other, bp);
      const mp = cstr(metric);
      const v = M._uc_wasm_distance(ap, bp, mp);
      M._free(mp);
      M._free(ap);
      M._free(bp);
      if (v !== v) throw new Error("unicolor: distance failed (sentinel or bad metric)");
      return v;
    }

    toString() { return this.formatCss(); }
  }

  // --- handle base: wasm pointer + best-effort finalization -------------

  const freeFns = {
    theme: M._uc_theme_free, palette: M._uc_palette_free,
    import: M._uc_import_report_free, validation: M._uc_validation_free,
  };
  const finalizer = new FinalizationRegistry((tok) => {
    if (tok.ptr === 0) return;
    freeFns[tok.kind](tok.ptr);
    tok.ptr = 0;
  });

  // Build a C uc_token array from tokens. Each token is either a tuple
  // `[name, color|null, alias|null]` (mirrors the Python binding) or a record
  // `{ name, color, alias }`. `keep` holds the encoded name/alias bytes alive
  // until uc_theme_make copies them.
  function buildTokens(toks) {
    const n = toks.length;
    if (n === 0) return { ptr: 0, n, keep: [] };
    const ptr = M._malloc(n * TOKEN_SIZE);
    const keep = [];
    for (let i = 0; i < n; i++) {
      const raw = toks[i];
      const t = Array.isArray(raw)
        ? { name: raw[0], color: raw[1], alias: raw[2] }
        : raw;
      const base = ptr + i * TOKEN_SIZE;
      const np = cstr(t.name);
      keep.push(np);
      M.setValue(base, np, "i32"); // name
      const cp = base + 4; // color (20 bytes)
      if (t.color) {
        writeColor(t.color, cp);
      } else { // sentinel for a semantic / component token
        M.setValue(cp + 16, 0, "i32");
        for (let k = 0; k < 16; k += 4) M.setValue(cp + k, 0, "float");
      }
      if (t.alias != null) {
        const ap = cstr(t.alias);
        keep.push(ap);
        M.setValue(base + 24, ap, "i32");
      } else {
        M.setValue(base + 24, 0, "i32");
      }
    }
    return { ptr, n, keep };
  }

  // --- Theme ------------------------------------------------------------

  class Theme {
    constructor(ptr) {
      this._tok = { ptr, kind: "theme" };
      finalizer.register(this, this._tok, this);
    }
    free() {
      if (this._tok.ptr !== 0) {
        M._uc_theme_free(this._tok.ptr);
        this._tok.ptr = 0;
        finalizer.unregister(this);
      }
    }

    static make(prims, sems = [], comps = []) {
      const pa = buildTokens(prims);
      const sa = buildTokens(sems);
      const ca = buildTokens(comps);
      const h = M._uc_theme_make(pa.ptr, pa.n, sa.ptr, sa.n, ca.ptr, ca.n);
      for (const p of pa.keep.concat(sa.keep, ca.keep)) M._free(p);
      if (pa.ptr) M._free(pa.ptr);
      if (sa.ptr) M._free(sa.ptr);
      if (ca.ptr) M._free(ca.ptr);
      if (h === 0) {
        throw new Error("unicolor: theme build failed (empty name, duplicate role, or bad alias)");
      }
      return new Theme(h);
    }

    resolve(role) {
      const out = M._malloc(COLOR_SIZE);
      const rp = cstr(role);
      M._uc_wasm_theme_resolve(this._tok.ptr, out, rp);
      M._free(rp);
      const c = readColor(out);
      M._free(out);
      if (c) return c;
      throw new Error("unicolor: theme resolve failed (undefined role, dangling alias, or cycle)");
    }

    hasRole(role) {
      const rp = cstr(role);
      const v = M._uc_theme_has_role(this._tok.ptr, rp);
      M._free(rp);
      return v !== 0;
    }

    get count() { return M._uc_theme_count(this._tok.ptr); }

    export(name, legacy = false) {
      const np = cstr(name);
      const leg = legacy ? 1 : 0;
      const s = measureFill(
        () => M._uc_theme_export(this._tok.ptr, np, leg, 0, 0),
        (buf, sz) => M._uc_theme_export(this._tok.ptr, np, leg, buf, sz));
      M._free(np);
      return s;
    }
  }

  // --- Palette ----------------------------------------------------------

  class Palette {
    constructor(ptr) {
      this._tok = { ptr, kind: "palette" };
      finalizer.register(this, this._tok, this);
    }
    free() {
      if (this._tok.ptr !== 0) {
        M._uc_palette_free(this._tok.ptr);
        this._tok.ptr = 0;
        finalizer.unregister(this);
      }
    }

    static make(tag, colors, intent, seed = 0) {
      const n = colors.length;
      let ptr = 0;
      if (n > 0) {
        ptr = M._malloc(n * COLOR_SIZE);
        for (let i = 0; i < n; i++) writeColor(colors[i], ptr + i * COLOR_SIZE);
      }
      // seed is int64 on the C ABI; Emscripten requires a BigInt for i64 args.
      const h = M._uc_palette_make(tag, ptr, n, intent, BigInt(seed));
      if (ptr) M._free(ptr);
      if (h === 0) {
        throw new Error("unicolor: palette build failed (bad tag/intent or empty colors)");
      }
      return new Palette(h);
    }

    colorAt(i) {
      // The C sentinel cannot tell out-of-range from a wrong structure, so pre-
      // check the index against `length` for a clean RangeError; a sentinel on
      // a discrete palette is then a wrong-structure Error.
      if (!Number.isInteger(i) || i < 0 || i >= this.length) {
        throw new RangeError("unicolor: color_at index out of range");
      }
      const out = M._malloc(COLOR_SIZE);
      M._uc_wasm_palette_color_at(this._tok.ptr, out, i);
      const c = readColor(out);
      M._free(out);
      if (c) return c;
      throw new Error("unicolor: color_at wrong structure");
    }

    sample(t) {
      const out = M._malloc(COLOR_SIZE);
      M._uc_wasm_palette_sample(this._tok.ptr, out, t);
      const c = readColor(out);
      M._free(out);
      if (c) return c;
      throw new RangeError("unicolor: sample out of [0,1] or non-ramp structure");
    }

    role(name) {
      const out = M._malloc(COLOR_SIZE);
      const np = cstr(name);
      M._uc_wasm_palette_role(this._tok.ptr, out, np);
      M._free(np);
      const c = readColor(out);
      M._free(out);
      if (c) return c;
      throw new Error("unicolor: palette role failed (unknown role or non-semantic structure)");
    }

    get length() { return M._uc_palette_len(this._tok.ptr); }
    get tag() { return M._uc_palette_tag(this._tok.ptr); }
    get intent() { return M._uc_palette_intent(this._tok.ptr); }
  }

  // --- ImportReport -----------------------------------------------------

  class ImportReport {
    constructor(ptr) {
      this._tok = { ptr, kind: "import" };
      finalizer.register(this, this._tok, this);
    }
    free() {
      if (this._tok.ptr !== 0) {
        M._uc_import_report_free(this._tok.ptr);
        this._tok.ptr = 0;
        finalizer.unregister(this);
      }
    }

    static importReported(input, fmt, strict = false) {
      const ip = cstr(input), fp = cstr(fmt);
      const h = M._uc_import_reported(ip, fp, strict ? 1 : 0);
      M._free(ip);
      M._free(fp);
      if (h === 0) {
        throw new Error("unicolor: import failed (NULL input/name or unknown importer)");
      }
      return new ImportReport(h);
    }

    get formatName() {
      return measureFill(
        () => M._uc_import_format_name(this._tok.ptr, 0, 0),
        (b, s) => M._uc_import_format_name(this._tok.ptr, b, s));
    }
    get schemaVersion() {
      return measureFill(
        () => M._uc_import_schema_version(this._tok.ptr, 0, 0),
        (b, s) => M._uc_import_schema_version(this._tok.ptr, b, s));
    }
    get warningCount() { return M._uc_import_warning_count(this._tok.ptr); }

    warning(i) {
      const count = M._uc_import_warning_count(this._tok.ptr);
      if (!Number.isInteger(i) || i < 0 || i >= count) {
        throw new RangeError("unicolor: warning index out of range");
      }
      return measureFill(
        () => M._uc_import_warning(this._tok.ptr, i, 0, 0),
        (b, s) => M._uc_import_warning(this._tok.ptr, i, b, s));
    }
  }

  // --- ValidationReport -------------------------------------------------

  class ValidationReport {
    constructor(ptr) {
      this._tok = { ptr, kind: "validation" };
      finalizer.register(this, this._tok, this);
    }
    free() {
      if (this._tok.ptr !== 0) {
        M._uc_validation_free(this._tok.ptr);
        this._tok.ptr = 0;
        finalizer.unregister(this);
      }
    }

    static validateTheme(t) {
      const h = M._uc_validate_theme(t._tok.ptr);
      if (h === 0) throw new Error("unicolor: validate_theme failed (NULL handle)");
      return new ValidationReport(h);
    }
    static validatePalette(p) {
      const h = M._uc_validate_palette(p._tok.ptr);
      if (h === 0) throw new Error("unicolor: validate_palette failed (NULL handle)");
      return new ValidationReport(h);
    }

    get score() { return M._uc_validation_score(this._tok.ptr); }
    get worst() { return M._uc_validation_worst(this._tok.ptr); }
    get ruleCount() { return M._uc_validation_rule_count(this._tok.ptr); }

    rule(i) {
      const count = M._uc_validation_rule_count(this._tok.ptr);
      if (!Number.isInteger(i) || i < 0 || i >= count) {
        throw new RangeError("unicolor: rule index out of range");
      }
      const name = measureFill(
        () => M._uc_validation_rule_name(this._tok.ptr, i, 0, 0),
        (b, s) => M._uc_validation_rule_name(this._tok.ptr, i, b, s));
      const message = measureFill(
        () => M._uc_validation_rule_message(this._tok.ptr, i, 0, 0),
        (b, s) => M._uc_validation_rule_message(this._tok.ptr, i, b, s));
      return {
        name,
        severity: M._uc_validation_rule_severity(this._tok.ptr, i),
        metric: M._uc_validation_rule_metric(this._tok.ptr, i),
        threshold: M._uc_validation_rule_threshold(this._tok.ptr, i),
        message,
      };
    }
  }

  // --- module functions -------------------------------------------------

  function version() { return M.UTF8ToString(M._uc_version()); }
  function abiMajor() { return M._uc_abi_major(); }
  function abiMinor() { return M._uc_abi_minor(); }
  function abiPatch() { return M._uc_abi_patch(); }

  function parse(s) { return Color.parse(s); }
  function srgb(r, g, b) { return Color.srgb(r, g, b); }
  function oklch(l, c, h) { return Color.oklch(l, c, h); }
  function make(tag, c0, c1, c2, alpha = 1) { return Color.make(tag, c0, c1, c2, alpha); }
  function contrast(fg, bg, metric = null) { return fg.contrast(bg, metric); }
  function distance(a, b, metric) { return a.distance(b, metric); }

  function theme(prims, sems = [], comps = []) { return Theme.make(prims, sems, comps); }
  function palette(tag, colors, intent, seed = 0) {
    return Palette.make(tag, colors, intent, seed);
  }

  function importTheme(input, fmt, strict = false) {
    const ip = cstr(input), fp = cstr(fmt);
    const h = M._uc_import_theme(ip, fp, strict ? 1 : 0);
    M._free(ip);
    M._free(fp);
    if (h === 0) {
      throw new Error("unicolor: import_theme failed (NULL, unknown importer, kind mismatch, or parse failure)");
    }
    return new Theme(h);
  }
  function importPalette(input, fmt, strict = false) {
    const ip = cstr(input), fp = cstr(fmt);
    const h = M._uc_import_palette(ip, fp, strict ? 1 : 0);
    M._free(ip);
    M._free(fp);
    if (h === 0) {
      throw new Error("unicolor: import_palette failed (NULL, unknown importer, kind mismatch, or parse failure)");
    }
    return new Palette(h);
  }
  function importReported(input, fmt, strict = false) {
    return ImportReport.importReported(input, fmt, strict);
  }
  function validateTheme(t) { return ValidationReport.validateTheme(t); }
  function validatePalette(p) { return ValidationReport.validatePalette(p); }

  return {
    version, abiMajor, abiMinor, abiPatch,
    parse, srgb, oklch, make, contrast, distance,
    theme, palette, importTheme, importPalette, importReported,
    validateTheme, validatePalette,
    Color, Theme, Palette, ImportReport, ValidationReport,
    TAG, PAL_TAG, PAL_INTENT, SEVERITY,
  };
}