# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# tree — `Theme` 3-layer token tree (primitive -> semantic -> component, as in
# Material/Radix/Tailwind/Spectrum). `resolve(role) -> Color` traverses the
# tree component -> semantic -> primitive -> color. No color is hardcoded in a
# semantic role. The theme is an immutable value; transformations (invert,
# variant, re-skin) build a new tree.
#
# Scope: tree + EXACT resolution. Hierarchical inheritance + family fallback
# live in `inherit`; orthogonal state modifiers / tone shift in `states`; the
# full role inventory in `roles`. Here `resolve` follows a defined alias chain
# to a primitive; an undefined role or a dangling alias target ->
# `UnresolvedRole`; an alias cycle -> `InvalidOp`. Primitives are single named
# colors here (the tonal-ramp aspect lands via tone shift on the resolved
# color). Deterministic: a pure traversal of an immutable tree — the same role
# resolves to a bit-identical color every call.
import std/tables
import std/options
import UniColor/core/core

type
  ThemeToken* = object
    ## A node of the token tree. Primitive tokens carry a `color` and leave
    ## `alias` empty; semantic and component tokens carry an `alias` (target
    ## role name) and leave `color` at its default (unused). The three
    ## `openArray`s passed to `theme` decide the layer, so the token itself does
    ## not store its layer.
    name*: string
    color*: Color ## primitive: the raw color; alias tokens: unused (default).
    alias*: string ## semantic/component: target role name; primitive: "".

  Theme* = object
    ## Immutable 3-layer token tree. Resolvable by `resolve(role)`. Lookup
    ## tables are built once at construction for O(depth) resolution.
    ##
    ## Encapsulation: the fields are PRIVATE. Reads happen through the
    ## same-named exported accessor procs below (`t.prims`, `t.sems`, `t.comps`,
    ## `t.count`) — Nim resolves `obj.field` to the field inside this module and
    ## to the proc outside (UFCS), so read sites are unchanged. Only `theme()`
    ## constructs a `Theme`, so the "unique role names, valid tokens,
    ## consistent count" invariant cannot be bypassed. `invert`/`variant`
    ## rebuild the primitive layer via `withPrims` rather than mutating fields.
    prims: Table[string, Color] ## primitive role name -> color.
    sems: Table[string, string] ## semantic role name -> target role name.
    comps: Table[string, string] ## component role name -> target role name.
    count: int ## total tokens across the three layers.

proc validateToken(tok: ThemeToken, isPrim: bool): Option[
    ColorError] {.raises: [].} =
  ## Returns `some(error)` if the token is malformed, else `none`. Primitive
  ## tokens need a non-empty name and an empty alias; alias tokens need a
  ## non-empty name and a non-empty alias target.
  if tok.name.len == 0:
    return some(colorError(InvalidOp, "theme: empty token name", "theme"))
  if isPrim:
    if tok.alias.len != 0:
      return some(colorError(InvalidOp,
          "theme: primitive token '" & tok.name & "' must not alias", "theme"))
  else:
    if tok.alias.len == 0:
      return some(colorError(InvalidOp,
          "theme: alias token '" & tok.name & "' has empty target", "theme"))

proc theme*(primitives, semantics, components: openArray[ThemeToken]): Result[
    Theme, ColorError] {.raises: [].} =
  ## Build an immutable 3-layer token tree. Validates every token and rejects
  ## duplicate role names across all layers (a name must be unique in the tree).
  ## On the first error returns `InvalidOp`; the tree is not partially built.
  var t: Theme
  var seen: Table[string, int] # name -> layer (0 prim, 1 sem, 2 comp).
  for tok in primitives:
    let e = validateToken(tok, isPrim = true)
    if e.isSome:
      return err[Theme, ColorError](e.get)
    if seen.hasKey(tok.name):
      return err[Theme, ColorError](colorError(InvalidOp,
          "theme: duplicate role name '" & tok.name & "'", "theme"))
    seen[tok.name] = 0
    t.prims[tok.name] = tok.color
  for tok in semantics:
    let e = validateToken(tok, isPrim = false)
    if e.isSome:
      return err[Theme, ColorError](e.get)
    if seen.hasKey(tok.name):
      return err[Theme, ColorError](colorError(InvalidOp,
          "theme: duplicate role name '" & tok.name & "'", "theme"))
    seen[tok.name] = 1
    t.sems[tok.name] = tok.alias
  for tok in components:
    let e = validateToken(tok, isPrim = false)
    if e.isSome:
      return err[Theme, ColorError](e.get)
    if seen.hasKey(tok.name):
      return err[Theme, ColorError](colorError(InvalidOp,
          "theme: duplicate role name '" & tok.name & "'", "theme"))
    seen[tok.name] = 2
    t.comps[tok.name] = tok.alias
  t.count = seen.len
  ok[Theme, ColorError](t)

# Encapsulation accessors: same-named procs so external `t.prims` / `t.count`
# read the private field via UFCS — read sites stay unchanged. `lent Table` is
# a read-only borrow (no copy, no mutation outside the module).
proc prims*(t: Theme): lent Table[string, Color] {.inline, raises: [].} = t.prims
proc sems*(t: Theme): lent Table[string, string] {.inline, raises: [].} = t.sems
proc comps*(t: Theme): lent Table[string, string] {.inline, raises: [].} = t.comps
proc count*(t: Theme): int {.inline, raises: [].} = t.count

# `withPrims` is the internal constructor for transformations that rebuild only
# the primitive layer (invert/variant): it carries the alias layers + count over
# unchanged. In-module, so it can touch the private fields. Not exported as a
# general mutation hatch — it returns a NEW Theme.
proc withPrims*(t: Theme, newPrims: Table[string, Color]): Theme {.raises: [].} =
  Theme(prims: newPrims, sems: t.sems, comps: t.comps, count: t.count)

proc len*(t: Theme): int {.raises: [].} =
  ## Total number of tokens across the three layers.
  t.count

proc hasRole*(t: Theme, role: string): bool {.raises: [].} =
  ## True if `role` is defined in any layer (primitive, semantic or component).
  t.prims.hasKey(role) or t.sems.hasKey(role) or t.comps.hasKey(role)

# Resolve a role, threading a visited set to detect alias cycles. Component ->
# semantic -> primitive order. A cycle returns `InvalidOp`; a missing role /
# dangling target returns `UnresolvedRole`.
proc resolveAux(t: Theme, role: string, visited: var Table[string,
    int]): Result[Color, ColorError] {.raises: [].} =
  if visited.hasKey(role):
    return err[Color, ColorError](colorError(InvalidOp,
        "theme: alias cycle at '" & role & "'", "resolve"))
  if t.comps.hasKey(role):
    visited[role] = 0
    return t.resolveAux(t.comps.getOrDefault(role), visited)
  if t.sems.hasKey(role):
    visited[role] = 0
    return t.resolveAux(t.sems.getOrDefault(role), visited)
  if t.prims.hasKey(role):
    return ok[Color, ColorError](t.prims.getOrDefault(role))
  err[Color, ColorError](colorError(UnresolvedRole,
      "resolve: role '" & role & "' not found", "resolve"))

proc resolve*(t: Theme, role: string): Result[Color, ColorError] {.raises: [].} =
  ## Resolve a role to a `Color` by traversing the tree component -> semantic ->
  ## primitive. A defined alias chain follows to its primitive. An undefined
  ## role or a dangling alias target -> `UnresolvedRole`. An alias cycle ->
  ## `InvalidOp`. Pure / deterministic: the same role resolves to a
  ## bit-identical color on every call.
  var visited: Table[string, int] = initTable[string, int]()
  t.resolveAux(role, visited)
