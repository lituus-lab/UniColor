# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import std/math
import std/strutils
import UniColor

suite "Color constructor — validation at bounds":
  test "valid color constructs ok":
    let r = color(tagSrgb, 0.1'f32, 0.2'f32, 0.3'f32)
    check r.isOk
    let c = r.get
    check c.spaceTag == tagSrgb
    check c.comp(0) == 0.1'f32
    check c.comp(1) == 0.2'f32
    check c.comp(2) == 0.3'f32
    check c.alpha == 1.0'f32

  test "alpha default is 1.0 (opaque)":
    let c = color(tagOklch, 0.7'f32, 0.15'f32, 250.0'f32).get
    check c.alpha == 1.0'f32
    check c.isOpaque

  test "explicit alpha carried":
    let c = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32, 0.5'f32).get
    check c.alpha == 0.5'f32
    check not c.isOpaque
    check not c.isTransparent

  test "alpha 0 is transparent":
    let c = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32).get
    check c.isTransparent

  test "alpha < 0 -> InvalidColor":
    let r = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32, -0.1'f32)
    check r.isErr
    check r.error.kind == InvalidColor

  test "alpha > 1 -> InvalidColor":
    let r = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32, 1.5'f32)
    check r.isErr
    check r.error.kind == InvalidColor

  test "NaN component at bounds -> InvalidColor":
    let r = color(tagSrgb, float32(NaN), 0.0'f32, 0.0'f32)
    check r.isErr
    check r.error.kind == InvalidColor

  test "Inf component at bounds -> InvalidColor (Inf treated as NaN)":
    let r = color(tagSrgb, 0.0'f32, float32(Inf), 0.0'f32)
    check r.isErr
    check r.error.kind == InvalidColor

  test "NaN alpha -> InvalidColor":
    let r = color(tagSrgb, 0.0'f32, 0.0'f32, 0.0'f32, float32(NaN))
    check r.isErr
    check r.error.kind == InvalidColor

  test "tagUnknown -> InvalidColor (no color without space)":
    let r = color(tagUnknown, 0.0'f32, 0.0'f32, 0.0'f32)
    check r.isErr
    check r.error.kind == InvalidColor

  test "out-of-gamut components are preserved (no clamp)":
    let c = color(tagSrgb, -0.2'f32, 1.5'f32, 0.3'f32).get
    check c.comp(0) == -0.2'f32
    check c.comp(1) == 1.5'f32

suite "Color accessors":
  test "components tuple":
    let c = color(tagLab, 50.0'f32, 10.0'f32, -20.0'f32).get
    let (c0, c1, c2) = c.components
    check c0 == 50.0'f32
    check c1 == 10.0'f32
    check c2 == -20.0'f32

  test "comp by index 0..2":
    let c = color(tagXyz, 0.5'f32, 0.6'f32, 0.7'f32).get
    check c.comp(0) == 0.5'f32
    check c.comp(1) == 0.6'f32
    check c.comp(2) == 0.7'f32

suite "Color equality — structural bit-by-bit":
  test "identical colors are equal":
    let a = color(tagSrgb, 0.1'f32, 0.2'f32, 0.3'f32, 0.8'f32).get
    let b = color(tagSrgb, 0.1'f32, 0.2'f32, 0.3'f32, 0.8'f32).get
    check a == b

  test "different tag not equal":
    let a = color(tagSrgb, 0.1'f32, 0.2'f32, 0.3'f32).get
    let b = color(tagP3, 0.1'f32, 0.2'f32, 0.3'f32).get
    check a != b

  test "different component not equal":
    let a = color(tagSrgb, 0.1'f32, 0.2'f32, 0.3'f32).get
    let b = color(tagSrgb, 0.1'f32, 0.2'f32, 0.4'f32).get
    check a != b

  test "different alpha not equal":
    let a = color(tagSrgb, 0.1'f32, 0.2'f32, 0.3'f32, 0.5'f32).get
    let b = color(tagSrgb, 0.1'f32, 0.2'f32, 0.3'f32, 0.6'f32).get
    check a != b

  test "hash is consistent with equality":
    let a = color(tagSrgb, 0.1'f32, 0.2'f32, 0.3'f32, 0.8'f32).get
    let b = color(tagSrgb, 0.1'f32, 0.2'f32, 0.3'f32, 0.8'f32).get
    check hash(a) == hash(b)

suite "Color $ diagnostic (deterministic)":
  test "$ includes space name and alpha marker":
    let s = $color(tagSrgb, 0.1'f32, 0.2'f32, 0.3'f32, 0.8'f32).get
    check "srgb" in s
    check "α=" in s
