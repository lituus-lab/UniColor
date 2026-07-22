# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import std/strutils
import std/os
import UniColor
import UniColor/cli/cli

suite "cli dispatch":
  test "no args prints help and exits 0":
    let r = run(@[])
    check r.ok
    check "unicolor" in r.text
    check "commands:" in r.text
  test "version prints the engine version":
    let r = run(@["version"])
    check r.ok
    check r.text == UniColorVersion
  test "unknown command exits 1":
    let r = run(@["bogus"])
    check not r.ok
    check "unknown command" in r.text

suite "cli color — parse":
  test "hex parses to srgb, shown as OKLCH":
    let r = run(@["parse", "#ff0000"])
    check r.ok
    check r.text.startsWith("oklch(")
    check "[srgb]" in r.text
  test "oklch parses to oklch":
    let r = run(@["parse", "oklch(0.65 0.18 250)"])
    check r.ok
    check "[oklch]" in r.text
  test "malformed input exits 1":
    let r = run(@["parse", "notacolor"])
    check not r.ok
    check "could not parse" in r.text

suite "cli color — convert / gamut":
  test "convert red to oklch changes the tag":
    let r = run(@["convert", "#ff0000", "oklch"])
    check r.ok
    check r.text.startsWith("oklch(")
    check "[oklch]" in r.text
  test "convert to srgb --legacy emits hex":
    let r = run(@["convert", "#ff0000", "srgb", "--legacy"])
    check r.ok
    check r.text.startsWith("#")
    check "[srgb]" in r.text
  test "convert unknown space exits 1":
    let r = run(@["convert", "#ff0000", "nosuchspace"])
    check not r.ok
    check "unknown space" in r.text
  test "gamut-map an out-of-sRGB oklch into srgb":
    let r = run(@["gamut", "oklch(0.7 0.3 200)", "srgb", "--legacy"])
    check r.ok
    check r.text.startsWith("#")
    check "[srgb]" in r.text

suite "cli color — contrast / distance":
  test "contrast black/white is ~21 (wcag22 default)":
    let r = run(@["contrast", "#000000", "#ffffff"])
    check r.ok
    check parseFloat(r.text) > 20.0
  test "contrast under a named metric (apca)":
    let r = run(@["contrast", "#000000", "#ffffff", "apca"])
    check r.ok
    check parseFloat(r.text) != 0.0
  test "contrast with a bad operand exits 1":
    let r = run(@["contrast", "notacolor", "#ffffff"])
    check not r.ok
  test "distance is positive between distinct colors":
    let r = run(@["distance", "#ff0000", "#00ff00"])
    check r.ok
    check parseFloat(r.text) > 0.0
  test "distance is zero for identical colors":
    let r = run(@["distance", "#ff0000", "#ff0000"])
    check r.ok
    check abs(parseFloat(r.text)) < 1e-6
  test "distance with a bad metric exits 1":
    let r = run(@["distance", "#ff0000", "#00ff00", "bogus"])
    check not r.ok

# A theme file the engine itself exported — guaranteed to round-trip back in.
# Unique per process so parallel CI runners don't collide; try/finally removes
# it even if a test raises after creation.
let themePath = getTempDir() / ("unicolor_cli_theme_" & $getCurrentProcessId() &
    ".json")
try:
  let t = theme([
    ThemeToken(name: "surface", color: color(tagSrgb, 1.0'f32, 1.0'f32,
        1.0'f32).get),
    ThemeToken(name: "text.primary",
      color: color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32).get)
  ], [], []).get
  writeFile(themePath, exportTheme(t, "json").get)

  suite "cli theme — resolve / export / validate":
    test "resolve a primitive role":
      let r = run(@["theme", "resolve", themePath, "surface"])
      check r.ok
      check "[oklch]" in r.text
    test "resolve with an explicit --format":
      let r = run(@["theme", "resolve", themePath, "surface", "--format", "json"])
      check r.ok
      check "[oklch]" in r.text
    test "resolve a missing role exits 1":
      let r = run(@["theme", "resolve", themePath, "nope"])
      check not r.ok
    test "export to css emits a --surface var":
      let r = run(@["theme", "export", themePath, "css"])
      check r.ok
      check "--surface" in r.text
    test "export --legacy emits hex":
      let r = run(@["theme", "export", themePath, "css", "--legacy"])
      check r.ok
      check "#" in r.text
    test "validate reports a passing score":
      let r = run(@["theme", "validate", themePath])
      check r.ok
      check "contrast-text-primary" in r.text
      check r.text.startsWith("score: ")
      check "worst: " in r.text
    test "missing file exits 1":
      let r = run(@["theme", "resolve", "/nonexistent/unicolor.json", "surface"])
      check not r.ok
      check "file not found" in r.text
    test "unknown theme subcommand exits 1":
      let r = run(@["theme", "bogus"])
      check not r.ok
finally:
  if fileExists(themePath):
    removeFile(themePath)

suite "cli palette — colorat / sample / validate":
  test "colorat picks the nth color":
    let r = run(@["palette", "colorat", "1", "#ff0000", "#00ff00"])
    check r.ok
    check "[srgb]" in r.text
  test "colorat out of range exits 1":
    let r = run(@["palette", "colorat", "5", "#ff0000", "#00ff00"])
    check not r.ok
  test "sample at t=0.5 between two colors":
    let r = run(@["palette", "sample", "0.5", "#ff0000", "#00ff00"])
    check r.ok
    check "[oklch]" in r.text
  test "sample out of range exits 1":
    let r = run(@["palette", "sample", "2.0", "#ff0000", "#00ff00"])
    check not r.ok
  test "validate reports a score":
    let r = run(@["palette", "validate", "#ff0000", "#00ff00", "#0055ff"])
    check r.ok
    check r.text.startsWith("score: ")
    check "worst: " in r.text
  test "bad color parse exits 1":
    let r = run(@["palette", "validate", "notacolor"])
    check not r.ok
    check "could not parse" in r.text
  test "unknown palette subcommand exits 1":
    let r = run(@["palette", "bogus"])
    check not r.ok
