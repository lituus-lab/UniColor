# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import UniColor

suite "Result[T, E]":
  test "ok holds value":
    let r = ok[int, string](42)
    check r.isOk
    check not r.isErr
    check r.get == 42

  test "err holds error":
    let r = err[int, string]("boom")
    check r.isErr
    check not r.isOk
    check r.error == "boom"

  test "getOr returns value when ok":
    check ok[int, string](5).getOr(0) == 5

  test "getOr returns fallback when err":
    check err[int, string]("x").getOr(7) == 7

  test "expect returns value when ok":
    check ok[int, string](9).expect("must be ok") == 9

  test "expect raises ValueError when err (internal assertion, not ABI)":
    expect ValueError:
      discard err[int, string]("x").expect("should raise")
