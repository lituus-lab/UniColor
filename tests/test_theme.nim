# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import UniColor

let blue = color(tagOklch, 0.65'f32, 0.18'f32, 250.0'f32).get
let red = color(tagSrgb, 0.80'f32, 0.20'f32, 0.20'f32).get
let white = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get

test "theme module compiles and is reachable":
  check themeModule == "0.1.0"

suite "tree + exact resolve":
  test "component -> semantic -> primitive chain":
    let prims = [ThemeToken(name: "primary", color: blue),
                 ThemeToken(name: "red", color: red)]
    let sems = [ThemeToken(name: "text/primary", alias: "red")]
    let comps = [ThemeToken(name: "button/bg", alias: "primary")]
    let t = theme(prims, sems, comps).get
    check t.resolve("button/bg").get == blue
    check t.resolve("text/primary").get == red
    check t.resolve("primary").get == blue
    check t.count == 4
    check t.hasRole("red")
    check not t.hasRole("nope")
  test "duplicate role name is InvalidOp":
    let prims = [ThemeToken(name: "x", color: blue),
                 ThemeToken(name: "x", color: red)]
    check theme(prims, [], []).error.kind == InvalidOp
  test "dangling alias target is UnresolvedRole":
    let sems = [ThemeToken(name: "ghost", alias: "missing")]
    check theme([], sems, []).isOk
    let t = theme([], sems, []).get
    check t.resolve("ghost").error.kind == UnresolvedRole
  test "alias cycle is InvalidOp":
    let sems = [ThemeToken(name: "a", alias: "b"),
                ThemeToken(name: "b", alias: "a")]
    let t = theme([], sems, []).get
    check t.resolve("a").error.kind == InvalidOp

suite "roles vocabulary":
  test "34 canonical roles across 6 families":
    check allRoles().len == 34
    check isCanonical("text.primary")
    check not isCanonical("primary.hover")
  test "baseRole strips state, stateOf extracts it":
    check baseRole("primary.hover") == "primary"
    check stateOf("primary.hover") == "hover"
    # canonical text.disabled is NOT a state role.
    check baseRole("text.disabled") == "text.disabled"
    check stateOf("text.disabled").len == 0

suite "inherit fallback":
  test "text.muted falls back to text.primary":
    let prims = [ThemeToken(name: "text.primary", color: blue)]
    let t = theme(prims, [], []).get
    check t.resolveWithFallback("text.muted").get == blue
  test "unknown role is UnresolvedRole":
    let t = theme([ThemeToken(name: "primary", color: blue)], [], []).get
    check t.resolveWithFallback("nope").error.kind == UnresolvedRole

suite "state tone shift":
  test "hover shifts lightness, no-state returns base":
    let prims = [ThemeToken(name: "primary", color: blue),
                 ThemeToken(name: "background", color: white)]
    let t = theme(prims, [], []).get
    let base = t.resolveState("primary", tmLight).get
    let hover = t.resolveState("primary.hover", tmLight).get
    check base == blue
    check hover != blue
  test "disabled blends toward background":
    let prims = [ThemeToken(name: "primary", color: blue),
                 ThemeToken(name: "background", color: white)]
    let t = theme(prims, [], []).get
    let r = t.resolveState("primary.disabled", tmLight)
    check r.isOk

suite "invert + variant":
  test "invert flips a light background to dark":
    let prims = [ThemeToken(name: "background",
        color: color(tagSrgb, 0.95'f32, 0.95'f32, 0.95'f32).get)]
    let t = theme(prims, [], []).get
    let inv = invert(t).get
    let bgL = t.resolve("background").get.to(tagOklch).get.comp(0)
    let invL = inv.resolve("background").get.to(tagOklch).get.comp(0)
    check invL < bgL
  test "variant level 0 is identity on primitives":
    let prims = [ThemeToken(name: "primary", color: blue)]
    let t = theme(prims, [], []).get
    let v = variant(t, 0).get
    check v.resolve("primary").get == blue

suite "tonal share":
  test "cloneFrom re-tints a reference ramp keeping length":
    let refPal = neutralScale(blue, 5, nmTinted, tagSrgb).get
    let cloned = cloneFrom(refPal, red).get
    check cloned.tag == palOrdered
    check cloned.len == refPal.len
  test "rampTokens rejects name-count mismatch":
    let p = neutralScale(blue, 3, nmTinted, tagSrgb).get
    check rampTokens(p, ["a", "b"]).error.kind == InvalidOp
  test "rampTokens zips names to colors":
    let p = neutralScale(blue, 2, nmTinted, tagSrgb).get
    let toks = rampTokens(p, ["bg", "fg"]).get
    check toks.len == 2
    check toks[0].name == "bg"

suite "golden reference themes":
  test "tailwindTheme resolves primary to blue.500":
    let t = tailwindTheme().get
    let pr = t.resolve("primary").get
    let b5 = color(tagSrgb, 0x3b'i32 / 255, 0x82'i32 / 255,
        0xf6'i32 / 255).get
    check pr == b5
  test "radixTheme resolves text.primary to blue.12":
    let t = radixTheme().get
    let pr = t.resolve("text.primary").get
    let b12 = color(tagSrgb, 0x00'i32 / 255, 0x25'i32 / 255,
        0x4d'i32 / 255).get
    check pr == b12

suite "themeFromColor":
  test "builds a 26-role flat theme":
    let t = themeFromColor(blue).get
    check t.count == 26
    check t.hasRole("background")
    check t.hasRole("syntax.keyword")
    check t.hasRole("error")
  test "dark flag yields a dark background":
    let light = themeFromColor(blue, dark = false).get
    let dark = themeFromColor(blue, dark = true).get
    let lL = light.resolve("background").get.to(tagOklch).get.comp(0)
    let dL = dark.resolve("background").get.to(tagOklch).get.comp(0)
    check dL < lL
    check dL < 0.5'f32
