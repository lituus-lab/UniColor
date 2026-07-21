# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# validation — rules registry + report. A rule measures one property of a
# Theme or Palette and returns a `RuleResult` (severity, metric, threshold,
# message). `validateTheme`/`validatePalette` walk every registered rule in
# insertion-stable order (deterministic — no hash-table iteration leak) and
# fold into a `ValidationReport`: per-rule results, a 0..100 score
# (100 - 10*errors - 2*warns, clamped >= 0; empty rule set -> 100/Info), and
# the worst severity. Two built-in rules ship: theme contrast AA and palette
# min ΔE_ok.
#
# Layer: validation (consumer of theme + palette + contrast). Deterministic.
import std/math # `NaN`, `Inf`.
import std/strutils # `formatFloat`.
import std/tables # `Table` (registry).
import std/options # `Option`, `some`, `none`.
import UniColor/core/result
import UniColor/core/core # `Color`.
import UniColor/core/color_error # `Severity`, `ColorError`.
import UniColor/theme/tree # `Theme`, `resolve`.
import UniColor/palette/types # `Palette`, `colors`.
import UniColor/contrast/contrast # `contrast` (WCAG 2.2 default), `distance`.

type
  RuleResult* = object
    ## One rule's outcome. `metric` is the measured value (NaN when the rule has
    ## no numeric metric, e.g. an unresolved role); `threshold` the pass
    ## boundary; `message` a human-readable line. `severity` reuses
    ## `Severity`: `Info` = passed, `Warning` = soft violation, `Error` = hard
    ## violation; `Fatal` is unused.
    name*: string
    severity*: Severity
    metric*: float64
    threshold*: float64
    message*: string

  ValidationReport* = object
    ## The full validation outcome: per-rule results (order-stable), a 0..100
    ## score, and the worst severity. `score = max(0, 100 - 10*errors -
    ## 2*warns)`; an empty rule set -> 100/Info.
    results*: seq[RuleResult]
    score*: int
    worst*: Severity

  ThemeRule* = object
    name*: string
    check*: proc(t: Theme): RuleResult {.raises: [].}

  PaletteRule* = object
    name*: string
    check*: proc(p: Palette): RuleResult {.raises: [].}

const
  ContrastAA* = 4.5'f64  ## WCAG 2.2 AA threshold for body text.
  MinDeltaEOk* = 0.1'f64 ## recommended minimum ΔE_ok between distinct palette
                         ## colors (a JND in OKLab is ~0.02; 0.1 is clearly
                         ## distinct).

proc severityRank(s: Severity): int {.raises: [].} =
  int(s)

proc worstSeverity*(results: seq[RuleResult]): Severity {.raises: [].} =
  if results.len == 0:
    return Severity.Info
  var w = Severity.Info
  for r in results:
    if severityRank(r.severity) > severityRank(w):
      w = r.severity
  w

proc computeScore*(results: seq[RuleResult]): int {.raises: [].} =
  var errors = 0
  var warns = 0
  for r in results:
    if r.severity == Severity.Error:
      inc errors
    elif r.severity == Severity.Warning:
      inc warns
  result = 100 - 10 * errors - 2 * warns
  if result < 0:
    result = 0

# Registry — module-level table + ordered name seq for insertion-stable
# iteration (mirrors the quantize/loader/dither registries). Idempotent,
# sealable.
var
  themeRules: Table[string, ThemeRule]
  themeRuleNames: seq[string]
  paletteRules: Table[string, PaletteRule]
  paletteRuleNames: seq[string]
  themeRulesSealed = false
  paletteRulesSealed = false

proc registerThemeRule*(r: ThemeRule): bool {.raises: [].} =
  ## Register a theme rule. Idempotent (no overwrite); `false` if the name
  ## exists or the registry is sealed. Insertion order is recorded so
  ## `validateTheme` walks rules deterministically.
  if themeRulesSealed or r.name.len == 0 or themeRules.hasKey(r.name):
    return false
  themeRules[r.name] = r
  themeRuleNames.add(r.name)
  true

proc registerPaletteRule*(r: PaletteRule): bool {.raises: [].} =
  ## Register a palette rule. Idempotent (no overwrite); `false` if the name
  ## exists or the registry is sealed.
  if paletteRulesSealed or r.name.len == 0 or paletteRules.hasKey(r.name):
    return false
  paletteRules[r.name] = r
  paletteRuleNames.add(r.name)
  true

proc lookupThemeRule*(name: string): Option[ThemeRule] {.raises: [].} =
  if themeRules.hasKey(name):
    some(themeRules.getOrDefault(name))
  else:
    none(ThemeRule)

proc lookupPaletteRule*(name: string): Option[PaletteRule] {.raises: [].} =
  if paletteRules.hasKey(name):
    some(paletteRules.getOrDefault(name))
  else:
    none(PaletteRule)

proc themeRuleCount*(): int {.raises: [].} = themeRuleNames.len
proc paletteRuleCount*(): int {.raises: [].} = paletteRuleNames.len

proc themeRuleNamesList*(): seq[string] {.raises: [].} = themeRuleNames
proc paletteRuleNamesList*(): seq[string] {.raises: [].} = paletteRuleNames

proc sealThemeRules*() {.raises: [].} = themeRulesSealed = true
proc sealPaletteRules*() {.raises: [].} = paletteRulesSealed = true

proc validateTheme*(t: Theme): ValidationReport {.raises: [].} =
  ## Run every registered theme rule in insertion order, fold into a report.
  var results: seq[RuleResult] = @[]
  for name in themeRuleNames:
    results.add(themeRules.getOrDefault(name).check(t))
  ValidationReport(results: results, score: computeScore(results),
      worst: worstSeverity(results))

proc validatePalette*(p: Palette): ValidationReport {.raises: [].} =
  ## Run every registered palette rule in insertion order, fold into a report.
  var results: seq[RuleResult] = @[]
  for name in paletteRuleNames:
    results.add(paletteRules.getOrDefault(name).check(p))
  ValidationReport(results: results, score: computeScore(results),
      worst: worstSeverity(results))

# Built-in rules (registered at import).

# Resolve a background-like role: `bg` if present, else `surface`.
proc resolveBg(t: Theme): Result[Color, ColorError] {.raises: [].} =
  let bgR = t.resolve("bg")
  if bgR.isOk:
    return bgR
  t.resolve("surface")

# text.primary on the background surface must meet WCAG 2.2 AA (contrast >=
# 4.5). An unresolved role is `Error` (the theme cannot be audited); below AA
# is `Error`; AA-or-better is `Info`. The message is built with `.add` per
# segment so nimpretty never collapses a `& <ident>` at a line wrap.
proc contrastTextPrimaryCheck(t: Theme): RuleResult {.raises: [].} =
  const name = "contrast-text-primary"
  let textR = t.resolve("text.primary")
  if textR.isErr:
    var msg = name & ": role 'text.primary' unresolved: "
    msg.add($textR.error.kind)
    return RuleResult(name: name, severity: Severity.Error, metric: NaN,
        threshold: ContrastAA, message: msg)
  let bgR = resolveBg(t)
  if bgR.isErr:
    var msg = name & ": no bg/surface role resolved: "
    msg.add($bgR.error.kind)
    return RuleResult(name: name, severity: Severity.Error, metric: NaN,
        threshold: ContrastAA, message: msg)
  let cR = contrast(textR.get, bgR.get) # default WCAG 2.2.
  if cR.isErr:
    var msg = name & ": contrast metric failed: "
    msg.add($cR.error.kind)
    return RuleResult(name: name, severity: Severity.Error, metric: NaN,
        threshold: ContrastAA, message: msg)
  let ratio = cR.get
  var msg = name & ": "
  if ratio < ContrastAA:
    msg.add("FAIL AA, text.primary on bg contrast ")
  else:
    msg.add("pass AA, text.primary on bg contrast ")
  msg.add(formatFloat(ratio, ffDecimal, 3))
  msg.add(if ratio < ContrastAA: " < " else: " >= ")
  msg.add($ContrastAA)
  let sev = if ratio < ContrastAA: Severity.Error else: Severity.Info
  RuleResult(name: name, severity: sev, metric: ratio, threshold: ContrastAA,
      message: msg)

# Every pair of distinct palette colors should be perceptually separable (min
# ΔE_ok >= 0.1). Below is a `Warning` (colors may be confusable), not a hard
# error — palettes may legitimately cluster.
proc minDeltaEOkCheck(p: Palette): RuleResult {.raises: [].} =
  const name = "min-delta-e"
  let cols = colors(p)
  if cols.len < 2:
    return RuleResult(name: name, severity: Severity.Info, metric: NaN,
        threshold: MinDeltaEOk,
        message: name & ": fewer than 2 colors, no pair distance")
  var minD = Inf
  for i in 0 ..< cols.len:
    for j in (i + 1) ..< cols.len:
      let dR = distance(cols[i], cols[j], "deltaE_ok")
      if dR.isErr:
        var msg = name & ": deltaE_ok failed: "
        msg.add($dR.error.kind)
        return RuleResult(name: name, severity: Severity.Error, metric: NaN,
            threshold: MinDeltaEOk, message: msg)
      if dR.get < minD:
        minD = dR.get
  var msg = name & ": "
  if minD < MinDeltaEOk:
    msg.add("WARN, min ΔE_ok ")
  else:
    msg.add("pass, min ΔE_ok ")
  msg.add(formatFloat(minD, ffDecimal, 3))
  msg.add(if minD < MinDeltaEOk: " < " else: " >= ")
  msg.add($MinDeltaEOk)
  let sev = if minD < MinDeltaEOk: Severity.Warning else: Severity.Info
  RuleResult(name: name, severity: sev, metric: minD, threshold: MinDeltaEOk,
      message: msg)

# Bootstrap — register the built-in rules at import (idempotent).
discard registerThemeRule(ThemeRule(name: "contrast-text-primary",
    check: contrastTextPrimaryCheck))
discard registerPaletteRule(PaletteRule(name: "min-delta-e",
    check: minDeltaEOkCheck))

const validationModule* = "0.1.0"
