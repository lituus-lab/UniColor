# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# roles — role inventory + namespace for the theme tree. The role VOCABULARY:
# 6 families and every canonical role, plus the 4 orthogonal state modifiers
# (focus / hover / active / disabled) applicable to any role via the
# `<family>.<role>[.<state>]` namespace.
#
# This ships ONLY the catalog + namespace parsing. The role -> primitive color
# MAPPING is not pinned by the spec (documented hole): golden reference themes
# (Tailwind/Radix) pin it with their conventions; hierarchical inheritance /
# family fallback live in `inherit`; state tone shift in `states`. Here we
# provide the role vocabulary and namespace helpers downstream modules consume.
# Pure data + string parsing — no Color, no core dependency.
import std/options
import std/sequtils
import std/strutils
import std/tables

type
  RoleFamily* {.pure.} = enum
    ## The 6 role families of a theme.
    rfCoreUI      ## background, surface, surface.variant, overlay, border, outline.
    rfBrand       ## primary, secondary, tertiary, accent.
    rfStatus      ## success, warning, error, info.
    rfText        ## text.primary, text.secondary, text.muted, text.disabled.
    rfInteractive ## link, focus, hover, active, visited, selection.
    rfSyntax ## syntax.keyword/string/function/variable/constant/type/operator/namespace/number/comment.

# The 4 orthogonal state modifiers. Applicable to any role as a trailing
# `.<state>` segment, resolved by tone shift in `states`.
const stateList = ["focus", "hover", "active", "disabled"]

# Canonical roles per family.
const coreUiRoles = ["background", "surface", "surface.variant", "overlay",
    "border", "outline"]
const brandRoles = ["primary", "secondary", "tertiary", "accent"]
const statusRoles = ["success", "warning", "error", "info"]
const textRoles = ["text.primary", "text.secondary", "text.muted",
    "text.disabled"]
const interactiveRoles = ["link", "focus", "hover", "active", "visited",
    "selection"]
const syntaxRoles = ["syntax.keyword", "syntax.string", "syntax.function",
    "syntax.variable", "syntax.constant", "syntax.type", "syntax.operator",
    "syntax.namespace", "syntax.number",
    "syntax.comment"]

# role name -> family, built once for O(1) canonical lookup + family resolution.
let familyOf: Table[string, RoleFamily] = block:
  var t: Table[string, RoleFamily]
  for r in coreUiRoles: t[r] = rfCoreUI
  for r in brandRoles: t[r] = rfBrand
  for r in statusRoles: t[r] = rfStatus
  for r in textRoles: t[r] = rfText
  for r in interactiveRoles: t[r] = rfInteractive
  for r in syntaxRoles: t[r] = rfSyntax
  t

proc isStateName(s: string): bool {.raises: [].} =
  ## True if `s` is one of the 4 state modifiers.
  s in stateList

proc isCanonical*(role: string): bool {.raises: [].} =
  ## True if `role` is one of the 34 canonical roles, with no state modifier.
  familyOf.hasKey(role)

proc allRoles*(): seq[string] {.raises: [].} =
  ## All 34 canonical roles across the 6 families, in family order.
  result = @[]
  for r in coreUiRoles: result.add(r)
  for r in brandRoles: result.add(r)
  for r in statusRoles: result.add(r)
  for r in textRoles: result.add(r)
  for r in interactiveRoles: result.add(r)
  for r in syntaxRoles: result.add(r)

proc rolesInFamily*(fam: RoleFamily): seq[string] {.raises: [].} =
  ## The canonical roles of one family.
  case fam
  of rfCoreUI: coreUiRoles.toSeq()
  of rfBrand: brandRoles.toSeq()
  of rfStatus: statusRoles.toSeq()
  of rfText: textRoles.toSeq()
  of rfInteractive: interactiveRoles.toSeq()
  of rfSyntax: syntaxRoles.toSeq()

proc stateNames*(): seq[string] {.raises: [].} =
  ## The 4 orthogonal state modifiers (focus / hover / active / disabled).
  stateList.toSeq()

proc baseRole*(role: string): string {.raises: [].} =
  ## Strip a trailing state modifier from a non-canonical role. A role that is
  ## itself canonical is returned unchanged even if it ends in a state name
  ## (e.g. `text.disabled` is a canonical Text role, not `text` + `disabled`).
  ## Unknown roles are returned unchanged.
  if isCanonical(role):
    return role
  let parts = role.split('.')
  if parts.len >= 2 and isStateName(parts[^1]):
    let prefix = parts[0 ..< parts.len - 1].join(".")
    if isCanonical(prefix):
      return prefix
  role

proc stateOf*(role: string): string {.raises: [].} =
  ## The trailing state modifier of `role`, or "" if it is canonical or has no
  ## state. Mirrors `baseRole`: `primary.hover` -> "hover"; `text.disabled` ->
  ## "" (canonical); `background` -> "".
  if isCanonical(role):
    return ""
  let parts = role.split('.')
  if parts.len >= 2 and isStateName(parts[^1]):
    let prefix = parts[0 ..< parts.len - 1].join(".")
    if isCanonical(prefix):
      return parts[^1]
  ""

proc isStateRole*(role: string): bool {.raises: [].} =
  ## True if `role` carries a state modifier on a non-canonical base (e.g.
  ## `primary.hover`). Canonical roles ending in a state name (e.g.
  ## `text.disabled`) are NOT state roles.
  stateOf(role).len != 0

proc roleFamily*(role: string): Option[RoleFamily] {.raises: [].} =
  ## The family of `role` (canonical or with a state modifier). `none` for
  ## unknown roles.
  let base = baseRole(role)
  if familyOf.hasKey(base):
    some(familyOf.getOrDefault(base))
  else:
    none(RoleFamily)
