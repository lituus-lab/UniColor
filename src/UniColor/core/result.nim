# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# result — minimal Result[T, E]: typed success or predictable failure.
# std/results is avoided so the error type stays domain-specific (ColorError)
# and the surface stays dependency-free.

type
  ResultKind* {.pure.} = enum
    rkOk
    rkErr

  Result*[T, E] = object
    ## Typed result: success (`value: T`) or failure (`error: E`), after Rust
    ## `Result`. The caller handles failure explicitly. `expect` is an
    ## internal-bug assertion (raises) — never crossed at the ABI.
    case kind*: ResultKind
    of rkOk:
      value*: T
    of rkErr:
      error*: E

func ok*[T, E](v: T): Result[T, E] {.raises: [].} =
  ## Success carrying `v`.
  Result[T, E](kind: rkOk, value: v)

func err*[T, E](e: E): Result[T, E] {.raises: [].} =
  ## Predictable failure carrying error `e`.
  Result[T, E](kind: rkErr, error: e)

func isOk*[T, E](r: Result[T, E]): bool {.inline, raises: [].} =
  r.kind == rkOk

func isErr*[T, E](r: Result[T, E]): bool {.inline, raises: [].} =
  r.kind == rkErr

func get*[T, E](r: Result[T, E]): T {.inline, raises: [].} =
  ## Value on success. Precondition: `r.isOk` (undefined behavior if `isErr`).
  r.value

func getOr*[T, E](r: Result[T, E], fallback: T): T {.inline, raises: [].} =
  ## Value on success, else `fallback` (explicit fallback by the caller).
  if r.isOk:
    r.value
  else:
    fallback

func expect*[T, E](r: Result[T, E], msg: string): T =
  ## Value on success, else raises `ValueError` (internal-bug assertion, not at
  ## the ABI). Reserve for core invariants, not user input.
  if r.isErr:
    raise newException(ValueError, msg)
  r.value
