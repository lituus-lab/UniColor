# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# core/schema — serialization schema version frontier + read gate. The single
# source of truth for the data-export schema version (JSON/TOML/YAML/DTCG).
# `currentSchemaVersion` is written into every data export; a reader supports
# the range [minSchemaVersion, currentSchemaVersion] — below `min` = obsolete,
# above `current` = future; both -> `err ImportFailed`. Upward compat: a newer
# reader accepts older versions in range; unknown fields are ignored on read.
#
# Comparison is NUMERIC, not lexicographic — schema versions are plain integers
# ("0", "1", ...), and "10" must outrank "9" (lexicographic would order
# "10" < "9"). A non-integer / malformed version -> `ImportFailed`.
#
# The import side (import/schema) adds the migration registry on top of this
# gate; the export side (export/serialize) writes `currentSchemaVersion` into
# the header. Both import this module so neither depends on the other (import
# is layer 12, export layer 13 — a direct import/schema -> export/schema edge
# would be illegal in the DAG; the shared gate lives here in core instead).
import std/options
import std/strutils
import UniColor/core/result
import UniColor/core/color_error

const
  currentSchemaVersion* = "0" ## The version written into data exports. Bump on
                              ## a breaking schema change; readers then migrate
                              ## older versions (import/schema).
  minSchemaVersion* = "0"     ## The floor a reader can import. Below ->
                              ## `err ImportFailed` (obsolete). Stays at the oldest
                              ## version still worth importing; bump only when
                              ## dropping support for ancient schemas.

# Parse a schema version as a plain non-negative integer. `none` if malformed
# (non-integer, empty, negative signs beyond a leading '-', or non-decimal).
# The leading '-' is parsed by `parseInt` (e.g. "-1" -> -1) and surfaces as
# `some(-1)`; the range check then rejects it as below the floor.
proc parseVersion(v: string): Option[int] {.raises: [].} =
  if v.len == 0:
    return none(int)
  try:
    some(parseInt(v))
  except ValueError:
    none(int)

proc isSupportedSchema*(v: string): bool {.raises: [].} =
  ## Whether `v` is in the readable range [minSchemaVersion, currentSchemaVersion]
  ## (numeric). `false` for obsolete (< min), future (> current), or malformed
  ## versions. A predicate (no error detail — use `checkSchema` for that).
  let vo = parseVersion(v)
  if vo.isNone:
    return false
  let lo = parseVersion(minSchemaVersion).get
  let hi = parseVersion(currentSchemaVersion).get
  let n = vo.get
  n >= lo and n <= hi

proc checkSchema*(v: string): Result[string, ColorError] {.raises: [].} =
  ## Validate `v` against the schema frontier. `ok` returns the validated
  ## version string (the round-trip value — what the reader accepts). `err
  ## ImportFailed` if `v` is obsolete (< min), future (> current, can't read
  ## unknown future schemas without migration), or malformed (non-integer).
  let vo = parseVersion(v)
  if vo.isNone:
    return err[string, ColorError](colorError(ImportFailed,
        "checkSchema: malformed schema version '" & v & "'", "checkSchema"))
  let lo = parseVersion(minSchemaVersion).get
  let hi = parseVersion(currentSchemaVersion).get
  let n = vo.get
  if n < lo:
    return err[string, ColorError](colorError(ImportFailed,
        "checkSchema: obsolete schema version '" & v & "' < min '" &
        minSchemaVersion & "'", "checkSchema"))
  if n > hi:
    return err[string, ColorError](colorError(ImportFailed,
        "checkSchema: future schema version '" & v & "' > current '" &
        currentSchemaVersion & "'", "checkSchema"))
  ok[string, ColorError](v)
