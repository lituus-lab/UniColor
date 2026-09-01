# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The version, stated in seven places, checked to agree.
##
## Nimble refuses anything but a string literal for `version`, so the manifest
## cannot import a shared constant and no arrangement makes one file the source
## the others derive from. What is achievable is proof: this test reads every
## copy and fails when one drifts. The previous version of this file asserted
## the literal "1.1.0" instead, which is why the manifest could reach 1.1.0
## while the header, the wheel and the Python test stayed at 1.0.0 -- caught by
## the release guard, not here.
import std/[unittest, os, strutils]
import UniColor

const Root = currentSourcePath().parentDir.parentDir

proc valueOf(path, key, opener, closer: string): string =
  ## The first `key … opener VALUE closer` on one line of the file; an empty
  ## `closer` reads to the end of the line. Deliberately crude: a parser per
  ## format would be more code than the thing it checks.
  for line in readFile(Root / path).splitLines:
    let at = line.find(key)
    if at < 0: continue
    let opens = line.find(opener, at + key.len)
    if opens < 0: continue
    let value = line[opens + opener.len .. ^1]
    if closer.len == 0: return value.strip
    let closes = value.find(closer)
    if closes < 0: continue
    return value[0 ..< closes]
  ""

suite "one version, seven copies":
  let manifest = valueOf("UniColor.nimble", "version", "\"", "\"")

  test "the manifest states one":
    check manifest.len > 0
    check manifest.count('.') == 2

  test "the Nim constant agrees":
    check UniColorVersion == manifest

  test "the C header agrees, macros and string alike":
    let parts = manifest.split('.')
    check valueOf("include/UniColor.h", "UC_VERSION_MAJOR", " ", "") == parts[0]
    check valueOf("include/UniColor.h", "UC_VERSION_MINOR", " ", "") == parts[1]
    check valueOf("include/UniColor.h", "UC_VERSION_PATCH", " ", "") == parts[2]
    check valueOf("include/UniColor.h", "define UC_VERSION ", "\"",
        "\"") == manifest

  test "the C ABI numbers track it":
    # The C test asserts uc_abi_* == UC_VERSION_*, so a manifest bump that
    # misses these fails there instead of here -- and did.
    let parts = manifest.split('.')
    check valueOf("src/UniColor/c_api.nim", "AbiMajor", "= ", "") == parts[0]
    check valueOf("src/UniColor/c_api.nim", "AbiMinor", "= ", "") == parts[1]
    check valueOf("src/UniColor/c_api.nim", "AbiPatch", "= ", "") == parts[2]

  test "the WASM test expects it":
    check valueOf("tests/wasm/test_unicolor.js", "checkStr(\"version\"",
        "\"", "\"") == manifest

  test "the Python distribution agrees":
    check valueOf("py/pyproject.toml", "version", "\"", "\"") == manifest

  test "the Python test expects it":
    check valueOf("py/tests/test_version.py", "unicolor.version()", "\"",
        "\"") == manifest

  test "module markers include core":
    check coreModule in ucModuleMarkers
