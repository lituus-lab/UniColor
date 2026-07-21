# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# import/schema — schema-version read gate + migration pipeline. The
# import-side companion to core/schema: core/schema WRITES the version into
# data exports and defines the readable range [min, current] + the gate
# (`checkSchema` / `isSupportedSchema`); import/schema READS the version from
# a parsed source, gates it (obsolete < min, future > current, or malformed
# -> fatal ImportFailed), and walks the migration chain `v ->
# currentSchemaVersion` to bring an older in-range version up to current.
# Upward compat: a newer reader accepts older versions in range; unknown
# FIELDS are ignored on read (field policy, owned by each importer).
#
# The frontier constants + the gate live in core/schema — the SINGLE SOURCE
# OF TRUTH. import/schema imports them (no duplication, no import -> export
# cross-layer edge: both reach the gate in core).
#
# `migrateData(v, data)` composes the gate (`checkSchema`) with the engine
# (`applyMigrations`); `applyMigrations(from, target, data)` is the engine
# WITHOUT the gate, unit-testable with a synthetic chain "0"->"1"->"2"
# independent of the real frontier.
#
# With the current frontier (min == current == "0") the engine is INERT: the
# only in-range version is "0" itself, so migration is identity. The framework
# activates the moment a schema bump registers real migrations (bump current,
# register Migration steps from the old version toward the new).
#
# Migration registry: module-level Table keyed by `fromVersion`, idempotent
# (no overwrite), sealable — mirrors the export/importer registries. `import`/
# `export` are Nim keywords -> quoted imports.
#
# Layer: import (consumer of core/schema + core).
import std/tables
import UniColor/core/result
import UniColor/core/color_error
import UniColor/core/schema # currentSchemaVersion, checkSchema (single source).

type
  Migration* = object
    ## One schema-version transformation step: data written under `fromVersion`
    ## is rewritten to `toVersion`. A chain `v0 -> v1 -> ... -> current` is
    ## walked by `applyMigrations`. The `apply` proc is a pure string transform
    ## (the importer hands it the document text or a serialized node; a
    ## migration renames a field, lifts a nested key, etc.); it returns
    ## `Result[string, ColorError]` so a malformed document surfaces as
    ## `ImportFailed`.
    fromVersion*: string
    toVersion*: string
    apply*: proc(data: string): Result[string, ColorError] {.raises: [].}

var
  migrationsByFrom: Table[string, Migration]
  migrationsSealed: bool

proc registerMigration*(m: Migration): bool {.raises: [].} =
  ## Register a migration step during bootstrap. `false` if the registry is
  ## sealed, `fromVersion`/`toVersion` are empty, `apply` is nil, or a
  ## migration from `fromVersion` is already registered (no overwrite). The
  ## caller must check the bool. Early returns avoid a long `or` chain
  ## (nimpretty collapses `or <ident>` into `or<ident>` at a wrap).
  if migrationsSealed:
    return false
  if m.fromVersion.len == 0 or m.toVersion.len == 0 or m.apply.isNil:
    return false
  if migrationsByFrom.hasKey(m.fromVersion):
    return false
  migrationsByFrom[m.fromVersion] = m
  true

proc migrationCount*(): int {.raises: [].} =
  migrationsByFrom.len

proc sealMigrations*() {.raises: [].} =
  ## Freeze the registry: no further registration (read-only after bootstrap).
  migrationsSealed = true

proc applyMigrations*(fromVersion, targetVersion, data: string): Result[
    string, ColorError] {.raises: [].} =
  ## Walk the migration chain from `fromVersion` to `targetVersion`, applying
  ## each registered step in sequence. `ok` returns the fully migrated data;
  ## the chain is identity when `fromVersion == targetVersion` (the common
  ## case at the current frontier). `err ImportFailed` if a step is MISSING (a
  ## gap in the chain — the reader cannot migrate an in-range version it has
  ## no migration for) or if a step's `apply` fails (the step's error
  ## propagates). This is the engine WITHOUT the gate — `migrateData` gates
  ## first. Unit-testable independent of the frontier constants (a synthetic
  ## chain "0"->"1"->"2").
  var cur = fromVersion
  var outData = data
  while cur != targetVersion:
    let m = migrationsByFrom.getOrDefault(cur)
    if m.fromVersion.len == 0: # absent — getOrDefault zero-inits Migration.
      return err[string, ColorError](colorError(ImportFailed,
          "applyMigrations: no migration registered from '" & cur &
          "' toward '" & targetVersion & "'", "applyMigrations"))
    let r = m.apply(outData)
    if r.isErr:
      return err[string, ColorError](r.error)
    outData = r.get
    cur = m.toVersion
  ok[string, ColorError](outData)

proc migrateData*(v, data: string): Result[string, ColorError] {.raises: [].} =
  ## The import-side read gate + migration. Gates `v` against the schema
  ## frontier (obsolete < min, future > current, malformed -> fatal
  ## ImportFailed — `checkSchema` from core/schema), then walks `v` ->
  ## `currentSchemaVersion` through the migration registry. `ok` returns the
  ## data unchanged when `v == current` (the common case at version "0"); `ok`
  ## returns the migrated data when a registered chain bridges an older
  ## in-range version to current. The importer calls this once after
  ## extracting `schemaVersion` from the document.
  let gated = checkSchema(v)
  if gated.isErr:
    return gated # already Result[string, ColorError] — forward the ImportFailed.
  applyMigrations(v, currentSchemaVersion, data)
