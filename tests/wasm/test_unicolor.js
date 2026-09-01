// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
//
// Node test suite for the UniColor WASM binding, mirroring tests/c/test_unicolor.c.
// The C ABI returns a sentinel color / NaN / NULL on failure; the JS binding
// surfaces those as throws (Error for sentinel/NaN/NULL, RangeError for an
// out-of-range index), so the failure cases assert a throw instead of a
// sentinel value. Exits 0 iff every check passes.

import { load } from "../../wasm/unicolor.js";

let failures = 0;
const ok = (name) => { console.log("ok   " + name); };
const fail = (name, msg) => { console.log("FAIL " + name + (msg ? ": " + msg : "")); failures++; };

function checkStr(name, got, want) {
  if (got !== want) fail(name, `got "${got}" want "${want}"`);
  else ok(name);
}
function checkInt(name, got, want) {
  if (got !== want) fail(name, `got ${got} want ${want}`);
  else ok(name);
}
function checkDbl(name, got, want) {
  const pass = (Number.isNaN(got) && Number.isNaN(want)) || got === want;
  if (!pass) fail(name, `got ${got} want ${want}`);
  else ok(name);
}
function checkDblTol(name, got, want, tol) {
  // Number.isNaN first: Math.abs(NaN - want) is NaN, and `NaN > tol` is false,
  // so without this a NaN got would pass a tolerance check.
  if (Number.isNaN(got) || Math.abs(got - want) > tol) fail(name, `got ${got} want ${want} (tol ${tol})`);
  else ok(name);
}
function checkColorOk(name, c) {
  if (!c || c.tag === 0) fail(name, "got sentinel/null");
  else ok(name + " tag=" + c.tag);
}
// Assert fn throws an Error; if kind is given, it must also be that constructor.
// Always require an Error so an omitted kind no longer accepts string throws.
function checkThrows(name, fn, kind) {
  try { fn(); fail(name, "expected throw"); }
  catch (e) {
    if (!(e instanceof Error)) fail(name, `got non-Error: ${String(e)}`);
    else if (kind && !(e instanceof kind)) fail(name, `got ${e.constructor.name}: ${e.message}`);
    else ok(name);
  }
}

const uc = await load();

// --- version / ABI ---------------------------------------------------------

checkStr("version", uc.version(), "1.1.0");
checkInt("abi_major", uc.abiMajor(), 1);
checkInt("abi_minor", uc.abiMinor(), 1);
checkInt("abi_patch", uc.abiPatch(), 0);

// --- color core ------------------------------------------------------------

const red = uc.srgb(1, 0, 0);
checkColorOk("srgb red", red);
checkInt("srgb red tag", red.tag, uc.TAG.SRGB);
checkDblTol("srgb red c0", red.comps[0], 1.0, 1e-6);
checkDblTol("srgb red c1", red.comps[1], 0.0, 1e-6);
checkDblTol("srgb red c2", red.comps[2], 0.0, 1e-6);
checkDbl("srgb red alpha", red.alpha, 1.0);

const oc = uc.oklch(0.65, 0.18, 250.0);
checkColorOk("oklch", oc);
checkInt("oklch tag", oc.tag, uc.TAG.OKLCH);

// Rejected constructors throw (the C sentinel becomes an Error).
checkThrows("make bad alpha", () => uc.make(uc.TAG.SRGB, 0.5, 0.5, 0.5, 2.0));
checkThrows("make unknown tag", () => uc.make(uc.TAG.UNKNOWN, 0.5, 0.5, 0.5, 1.0));
checkThrows("make NaN comp", () => uc.make(uc.TAG.SRGB, NaN, 0.0, 0.0, 1.0));

// Parse: hex -> sRGB, oklch -> OKLCH, malformed / NULL -> throw.
const ph = uc.parse("#ff0000");
checkColorOk("parse #ff0000", ph);
checkInt("parse #ff0000 tag", ph.tag, uc.TAG.SRGB);
checkDblTol("parse #ff0000 c0", ph.comps[0], 1.0, 1e-6);
checkDblTol("parse #ff0000 c1", ph.comps[1], 0.0, 1e-6);
checkDblTol("parse #ff0000 c2", ph.comps[2], 0.0, 1e-6);
checkColorOk("parse oklch", uc.parse("oklch(0.65 0.18 250)"));
checkThrows("parse bogus", () => uc.parse("notacolor"));
checkThrows("parse NULL", () => uc.parse(null));

// Format: legacy hex, OKLCH form.
checkInt("format srgb hex len", red.formatCss(true).length, 7);
checkStr("format srgb hex", red.formatCss(true), "#ff0000");
if (!oc.formatCss().startsWith("oklch(")) fail("format oklch", `got "${oc.formatCss()}"`);
else ok("format oklch = \"" + oc.formatCss() + "\"");
// A sentinel never reaches JS (constructor throws), so the sentinel-formats-
// empty case has no JS analogue; a valid color formats non-empty.
if (red.formatCss().length === 0) fail("format non-empty", "empty");
else ok("format non-empty");

// Convert / gamut-map.
const redOklch = red.convert(uc.TAG.OKLCH);
checkColorOk("convert red->oklch", redOklch);
checkInt("convert red->oklch tag", redOklch.tag, uc.TAG.OKLCH);
const okSrgb = oc.gamutMap(uc.TAG.SRGB);
checkColorOk("gamut_map oklch->srgb", okSrgb);
checkInt("gamut_map oklch->srgb tag", okSrgb.tag, uc.TAG.SRGB);
checkThrows("convert unknown target", () => red.convert(9999));

// Contrast: black/white = 21 (WCAG 2.2); sentinel / bad metric throw.
const black = uc.srgb(0, 0, 0);
const white = uc.srgb(1, 1, 1);
checkDblTol("contrast black/white", uc.contrast(black, white), 21.0, 0.01);
// A sentinel-shaped color (tag 0) the Color constructor would refuse, fed
// straight to contrast so its invalid-color path runs — not parse's rejection.
const sentinel = { tag: 0, comps: [0, 0, 0], alpha: 1, contrast: uc.Color.prototype.contrast };
checkThrows("contrast sentinel", () => uc.contrast(sentinel, white));
checkThrows("contrast bad metric", () => uc.contrast(black, white, "bogus"));
const apca = uc.contrast(black, white, "apca");
if (Number.isNaN(apca)) fail("contrast apca", "got NaN");
else ok("contrast apca = " + apca);

// Distance: positive between distinct colors, 0 identical, bad metric throws.
const d = uc.distance(red, white, "deltaE_ok");
if (Number.isNaN(d) || d < 0.0) fail("distance red/white", `got ${d}`);
else ok("distance red/white = " + d);
checkThrows("distance bad metric", () => uc.distance(red, white, "bogus"));
checkDbl("distance identical", uc.distance(red, red, "deltaE_ok"), 0.0);

// --- theme handle ----------------------------------------------------------

const blue = uc.oklch(0.65, 0.18, 250.0);

const th = uc.theme(
  [["background", red, null], ["text.primary", blue, null]],
  [["text.muted", null, "text.primary"]]);
if (!th) fail("theme_make", "null");
else ok("theme_make");

checkInt("theme count", th.count, 3);
checkInt("theme has text.muted", th.hasRole("text.muted") ? 1 : 0, 1);
checkInt("theme missing role", th.hasRole("nope") ? 1 : 0, 0);

const muted = th.resolve("text.muted");
checkColorOk("theme resolve text.muted", muted);
checkInt("theme resolve text.muted tag", muted.tag, uc.TAG.OKLCH);
checkThrows("theme resolve missing", () => th.resolve("nope"));

const css = th.export("css");
if (css.length === 0 || !css.includes("--background")) fail("theme_export css", `"${css}"`);
else ok("theme_export css (len " + css.length + ")");
checkInt("theme_export unknown format", th.export("nopefmt").length, 0);

th.free();
checkThrows("theme resolve after free", () => th.resolve("background"));

// --- palette handle --------------------------------------------------------

const pal = uc.palette(uc.PAL_TAG.ORDERED, [red, blue, white],
  uc.PAL_INTENT.SEQUENTIAL, 0);
if (!pal) fail("palette_make", "null");
else ok("palette_make");
checkInt("palette len", pal.length, 3);
checkInt("palette tag", pal.tag, uc.PAL_TAG.ORDERED);
checkInt("palette intent", pal.intent, uc.PAL_INTENT.SEQUENTIAL);
checkColorOk("palette color_at 0", pal.colorAt(0));
checkInt("palette color_at 0 tag", pal.colorAt(0).tag, uc.TAG.SRGB);
checkThrows("palette color_at oob", () => pal.colorAt(9), RangeError);
checkColorOk("palette sample 0.5", pal.sample(0.5));
checkThrows("palette sample oob", () => pal.sample(2.0), RangeError);

// Rejected builds throw (empty colors, bad tag).
checkThrows("palette empty", () => uc.palette(uc.PAL_TAG.ORDERED, [], uc.PAL_INTENT.SEQUENTIAL, 0));
checkThrows("palette bad tag", () => uc.palette(999, [red], uc.PAL_INTENT.SEQUENTIAL, 0));

pal.free();

// --- import ABI ------------------------------------------------------------

const src = uc.theme([["background", red, null], ["text.primary", blue, null]]);
const json = src.export("json");
if (json.length === 0 || !json.includes("\"background\"")) {
  fail("export json", `"${json}"`);
} else {
  ok("export json (len " + json.length + ")");

  const imp = uc.importTheme(json, "json");
  if (!imp) fail("import_theme", "null");
  else { checkColorOk("import resolve background", imp.resolve("background")); imp.free(); }

  const rep = uc.importReported(json, "json");
  if (!rep) fail("import_reported", "null");
  else {
    checkStr("import format_name", rep.formatName, "json");
    checkInt("import warning_count", rep.warningCount, 0);
    checkThrows("import warning oob", () => rep.warning(0), RangeError);
    rep.free();
  }
}
src.free();

// Failures: NULL input / unknown importer throw.
checkThrows("import NULL input", () => uc.importTheme(null, "json"));
checkThrows("import unknown fmt", () => uc.importTheme(json, "nopefmt"));

// --- validation ABI ---------------------------------------------------------

// Passing theme: black text on white surface meets WCAG AA.
const vt = uc.theme([["surface", white, null], ["text.primary", black, null]]);
const vr = uc.validateTheme(vt);
if (!vr) fail("validate_theme", "null");
else {
  checkInt("validate score (pass)", vr.score, 100);
  checkInt("validate worst (pass)", vr.worst, uc.SEVERITY.INFO);
  checkInt("validate rule_count", vr.ruleCount, 1);
  const r0 = vr.rule(0);
  checkStr("validate rule name", r0.name, "contrast-text-primary");
  checkInt("validate rule severity (pass)", r0.severity, uc.SEVERITY.INFO);
  checkDblTol("validate rule threshold", r0.threshold, 4.5, 1e-6);
  if (Number.isNaN(r0.metric) || r0.metric < 4.5) fail("validate rule metric", `got ${r0.metric}`);
  else ok("validate rule metric = " + r0.metric);
  if (r0.message.length === 0) fail("validate rule message", "empty");
  else ok("validate rule message (len " + r0.message.length + ")");
  checkThrows("validate rule oob", () => vr.rule(9), RangeError);
  vr.free();
}
vt.free();

// Failing theme: white text on white surface fails AA (score 90, Error).
const vtf = uc.theme([["surface", white, null], ["text.primary", white, null]]);
const vrf = uc.validateTheme(vtf);
if (!vrf) fail("validate_theme (fail)", "null");
else {
  checkInt("validate score (fail)", vrf.score, 90);
  checkInt("validate worst (fail)", vrf.worst, uc.SEVERITY.ERROR);
  checkInt("validate rule severity (fail)", vrf.rule(0).severity, uc.SEVERITY.ERROR);
  vrf.free();
}
vtf.free();

// --- summary ---------------------------------------------------------------

if (failures === 0) { console.log("\nAll WASM tests passed."); }
else { console.log(`\n${failures} WASM test(s) FAILED.`); }
process.exit(failures === 0 ? 0 : 1);