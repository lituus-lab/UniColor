# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import std/strutils
import UniColor

suite "SpaceTag — distinct int32, stable ABI":
  test "built-in tags are distinct":
    check tagSrgb != tagP3
    check tagOklch != tagLab
    check id(tagSrgb) != id(tagP3)

  test "tagUnknown sentinel is zero":
    check id(tagUnknown) == 0

  test "equality is by id":
    check tagSrgb == SpaceTag(id(tagSrgb))
    check tagSrgb != tagXyz

  test "isBuiltin / isUser partition (Open/Closed)":
    check isBuiltin(tagSrgb)
    check isBuiltin(tagHct)
    check not isBuiltin(tagUnknown)
    check not isBuiltin(TAG_USER_BASE)
    check isUser(TAG_USER_BASE)
    check isUser(SpaceTag(id(TAG_USER_BASE) + 5))
    check not isUser(tagSrgb)

  test "$ renders the id":
    check "SpaceTag" in $tagSrgb

  test "spaceName maps built-ins and sentinels":
    check spaceName(tagSrgb) == "srgb"
    check spaceName(tagOklch) == "oklch"
    check spaceName(tagLab) == "lab"
    check spaceName(tagUnknown) == "unknown"
    check spaceName(TAG_USER_BASE) == "user"
