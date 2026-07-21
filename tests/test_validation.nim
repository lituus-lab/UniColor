# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import std/options # `isSome` / `isNone` on `Option`.
import UniColor

# Built-ins bootstrap at import: one theme rule ("contrast-text-primary") and
# one palette rule ("min-delta-e").
const baseThemeRules = 1
const basePaletteRules = 1

let black = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get
let white = color(tagSrgb, 1.0'f32, 1.0'f32, 1.0'f32).get
let lightGray = color(tagSrgb, 0.9'f32, 0.9'f32, 0.9'f32).get

test "validation module compiles and is reachable":
  check validationModule == "0.1.0"

suite "report score + worst severity":
  test "empty rule set -> 100 / Info":
    var results: seq[RuleResult] = @[]
    check computeScore(results) == 100
    check worstSeverity(results) == Severity.Info

  test "one error -> score 90 / Error":
    var results = @[RuleResult(name: "a", severity: Severity.Error, metric: NaN,
        threshold: 0.0, message: "")]
    check computeScore(results) == 90
    check worstSeverity(results) == Severity.Error

  test "one warning -> score 98 / Warning":
    var results = @[RuleResult(name: "a", severity: Severity.Warning,
        metric: NaN, threshold: 0.0, message: "")]
    check computeScore(results) == 98
    check worstSeverity(results) == Severity.Warning

  test "mixed clamps to >= 0":
    var results: seq[RuleResult] = @[]
    for i in 0 ..< 12:
      results.add(RuleResult(name: "e" & $i, severity: Severity.Error,
          metric: NaN, threshold: 0.0, message: ""))
    check computeScore(results) == 0
    check worstSeverity(results) == Severity.Error

suite "contrast-text-primary rule":
  test "black on white passes AA":
    let prims = [ThemeToken(name: "text.primary", color: black),
                 ThemeToken(name: "bg", color: white)]
    let t = theme(prims, [], []).get
    let r = validateTheme(t)
    check r.results.len == baseThemeRules
    check r.worst == Severity.Info
    check r.score == 100
    let c = r.results[0]
    check c.name == "contrast-text-primary"
    check c.severity == Severity.Info
    check c.metric >= ContrastAA

  test "light gray on white fails AA":
    let prims = [ThemeToken(name: "text.primary", color: lightGray),
                 ThemeToken(name: "bg", color: white)]
    let t = theme(prims, [], []).get
    let r = validateTheme(t)
    check r.worst == Severity.Error
    check r.score == 90
    check r.results[0].severity == Severity.Error
    check r.results[0].metric < ContrastAA

  test "missing text.primary role -> Error":
    let prims = [ThemeToken(name: "bg", color: white)]
    let t = theme(prims, [], []).get
    let r = validateTheme(t)
    check r.worst == Severity.Error
    check r.results[0].severity == Severity.Error
    check isNaN(r.results[0].metric)

  test "falls back to surface when bg absent":
    let prims = [ThemeToken(name: "text.primary", color: white),
                 ThemeToken(name: "surface", color: black)]
    let t = theme(prims, [], []).get
    let r = validateTheme(t)
    check r.worst == Severity.Info
    check r.results[0].severity == Severity.Info

suite "min-delta-e rule":
  test "okabeIto (8 distinct) passes":
    let p = okabeIto()
    let r = validatePalette(p)
    check r.results.len == basePaletteRules
    check r.worst == Severity.Info
    check r.score == 100
    check r.results[0].name == "min-delta-e"
    check r.results[0].severity == Severity.Info
    check r.results[0].metric >= MinDeltaEOk

  test "two identical colors -> Warning":
    let cols = [white, white]
    let p = palette(palUnordered, cols, intentQualitative, 0).get
    let r = validatePalette(p)
    check r.worst == Severity.Warning
    check r.score == 98
    check r.results[0].severity == Severity.Warning
    check r.results[0].metric < MinDeltaEOk

  test "fewer than 2 colors -> Info (no pair distance)":
    let p = palette(palUnordered, [white], intentQualitative, 0).get
    let r = validatePalette(p)
    check r.worst == Severity.Info
    check r.results[0].severity == Severity.Info
    check isNaN(r.results[0].metric)

suite "registry (idempotent, insertion-stable, sealable)":
  # Mutates the global registry (registers a custom rule, then seals both) so
  # it runs LAST; the validate suites above see only the bootstrap built-ins.
  test "bootstrap counts":
    check themeRuleCount() == baseThemeRules
    check paletteRuleCount() == basePaletteRules
    check themeRuleNamesList() == @["contrast-text-primary"]
    check paletteRuleNamesList() == @["min-delta-e"]

  test "lookup hits and misses":
    check lookupThemeRule("contrast-text-primary").isSome
    check lookupThemeRule("nope").isNone
    check lookupPaletteRule("min-delta-e").isSome
    check lookupPaletteRule("nope").isNone

  test "duplicate name is rejected (idempotent)":
    let dup = ThemeRule(name: "contrast-text-primary",
        check: proc(t: Theme): RuleResult =
      RuleResult(name: "contrast-text-primary", severity: Severity.Info,
          metric: NaN, threshold: 0.0, message: ""))
    check not registerThemeRule(dup)
    check themeRuleCount() == baseThemeRules

  test "empty name is rejected":
    let bad = ThemeRule(name: "",
        check: proc(t: Theme): RuleResult =
      RuleResult(name: "", severity: Severity.Info, metric: NaN,
          threshold: 0.0, message: ""))
    check not registerThemeRule(bad)

  test "new rule registered, insertion order preserved":
    let custom = ThemeRule(name: "custom-theme",
        check: proc(t: Theme): RuleResult =
      RuleResult(name: "custom-theme", severity: Severity.Warning,
          metric: NaN, threshold: 0.0, message: "custom"))
    check registerThemeRule(custom)
    check themeRuleCount() == baseThemeRules + 1
    check themeRuleNamesList() == @["contrast-text-primary", "custom-theme"]
    let prims = [ThemeToken(name: "text.primary", color: black),
                 ThemeToken(name: "bg", color: white)]
    let t = theme(prims, [], []).get
    let r = validateTheme(t)
    check r.results.len == baseThemeRules + 1
    check r.worst == Severity.Warning
    check r.score == 98

  test "seal blocks further registration":
    sealThemeRules()
    sealPaletteRules()
    let after = ThemeRule(name: "after-seal",
        check: proc(t: Theme): RuleResult =
      RuleResult(name: "after-seal", severity: Severity.Info, metric: NaN,
          threshold: 0.0, message: ""))
    check not registerThemeRule(after)
    check not registerPaletteRule(PaletteRule(name: "after-seal",
        check: proc(p: Palette): RuleResult =
      RuleResult(name: "after-seal", severity: Severity.Info, metric: NaN,
          threshold: 0.0, message: "")))
