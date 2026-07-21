# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# inherit — hierarchical inheritance + family fallback for the theme tree.
# When a role is NOT defined in the tree, `resolveWithFallback` walks an
# inheritance chain before giving up:
#   1. exact role in the tree? -> `resolve` (exact resolution).
#   2. parent role (state stripped, or family-internal hierarchy) -> resolve
#      (state roles resolve to their base color with NO shift here).
#   3. generic family fallback (syntax.* -> text.primary, status.* -> accent)
#      -> resolve.
#   4. exhausted -> `UnresolvedRole` (warning, no exception).
#
# The full parent hierarchy is NOT pinned by the spec (only `text.secondary ->
# text.primary`, `surface.variant -> surface`, `syntax.comment -> text.muted`
# are given). This module implements the spec-pinned links plus a text
# prominence chain (primary -> secondary -> muted -> disabled), documented
# here. The two generic fallbacks are spec-pinned. New parent links can be
# added without breaking callers (additive). Deterministic: pure traversal.
import std/options
import std/tables
import UniColor/core/core
import UniColor/theme/tree
import UniColor/theme/roles

proc parentOf*(role: string): Option[string] {.raises: [].} =
  ## The inheritance parent of `role`, or `none`. A state role's parent is its
  ## base (state stripped). Otherwise the spec-pinned family-internal links +
  ## the text prominence chain. Family heads and unspecified roles have none.
  if isStateRole(role):
    return some(baseRole(role))
  case role
  of "text.secondary": some("text.primary")
  of "text.muted": some("text.secondary")
  of "text.disabled": some("text.muted")
  of "surface.variant": some("surface")
  of "syntax.comment": some("text.muted")
  else: none(string)

proc familyFallback*(fam: RoleFamily): Option[string] {.raises: [].} =
  ## The generic per-family fallback role. `rfSyntax -> text.primary`,
  ## `rfStatus -> accent`; the other families have no generic fallback (their
  ## roles must be defined or reached via `parentOf`).
  case fam
  of rfSyntax: some("text.primary")
  of rfStatus: some("accent")
  else: none(string)

# Recursive fallback resolution with a visited guard (the parent/fallback chain
# is acyclic by construction, but the guard keeps a malformed tree from
# looping). Tries exact -> parent -> family fallback -> UnresolvedRole.
proc resolveFallback(t: Theme, role: string, visited: var Table[string,
    int]): Result[Color, ColorError] {.raises: [].} =
  if visited.hasKey(role):
    return err[Color, ColorError](colorError(InvalidOp,
        "inherit: fallback cycle at '" & role & "'", "resolveWithFallback"))
  visited[role] = 0
  # Step 1: exact resolution in the tree (handles alias chains + cycles).
  let exact = t.resolve(role)
  if exact.isOk:
    return exact
  if exact.error.kind != UnresolvedRole:
    # Non-recoverable (e.g. alias cycle) — propagate, do not paper over it by
    # falling back to parent/family. Only a genuinely missing role falls back.
    return exact
  # Step 2: family-internal parent (state stripped or hierarchy).
  let p = parentOf(role)
  if p.isSome:
    let pr = t.resolveFallback(p.get, visited)
    if pr.isOk:
      return pr
  # Step 3: generic family fallback.
  let fam = roleFamily(role)
  if fam.isSome:
    let f = familyFallback(fam.get)
    if f.isSome:
      let fr = t.resolveFallback(f.get, visited)
      if fr.isOk:
        return fr
  # Step 4: exhausted.
  err[Color, ColorError](colorError(UnresolvedRole,
      "resolveWithFallback: role '" & role &
      "' not found and fallback exhausted",
      "resolveWithFallback"))

proc resolveWithFallback*(t: Theme, role: string): Result[Color,
    ColorError] {.raises: [].} =
  ## Resolve `role` to a `Color`, walking the inheritance + fallback chain:
  ## exact -> parent (state stripped / family hierarchy) -> generic family
  ## fallback -> `UnresolvedRole`. Deterministic (pure traversal). State roles
  ## resolve to their base color with NO tone shift here; the shift lives in
  ## `states`.
  var visited: Table[string, int] = initTable[string, int]()
  t.resolveFallback(role, visited)
