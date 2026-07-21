# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# registry — data-driven registration of spaces. Init-once / read-only:
# descriptors are registered at load time of spaces/* modules (import side
# effect), then sealed. O(1) lookup by name AND by tag (two indexes).
# Idempotent (no overwrite): a registered space never changes.

import std/tables
import std/options
import std/math
import UniColor/core/space_tag
import UniColor/core/color
import UniColor/core/numerics
import UniColor/spaces/descriptor

var
  byName: Table[string, SpaceDescriptor]
  byTag: Table[SpaceTag, SpaceDescriptor]
  sealed: bool

proc registerSpace*(d: SpaceDescriptor): bool =
  ## Registers a descriptor (idempotent: returns false if already present or
  ## sealed). No overwrite: a registered space never changes. Rejects a
  ## duplicate name OR a duplicate tag before mutating either index, so a
  ## tag already in use under another name cannot be silently reassigned.
  if sealed or d.name.len == 0:
    return false
  if byName.hasKey(d.name) or byTag.hasKey(d.tag):
    return false
  byName[d.name] = d
  byTag[d.tag] = d
  true

proc lookupSpace*(name: string): Option[SpaceDescriptor] =
  ## Lookup by canonical name (O(1)).
  if byName.hasKey(name):
    some(byName[name])
  else:
    none(SpaceDescriptor)

proc spaceByTag*(tag: SpaceTag): Option[SpaceDescriptor] {.raises: [].} =
  ## O(1) tag lookup. `getOrDefault` returns a zero-initialized descriptor when
  ## the tag is absent (empty name), so this never raises KeyError and stays
  ## raises-free.
  let d = byTag.getOrDefault(tag)
  if d.name.len == 0:
    none(SpaceDescriptor)
  else:
    some(d)

proc sealSpaces*() =
  ## Seals the registry (read-only definitive after built-ins registration).
  sealed = true

proc spacesCount*(): int =
  byName.len

proc isAchromatic*(c: Color): bool {.raises: [].} =
  ## True when `c` carries no hue. Polar spaces (achPolarChroma) test chroma ~0;
  ## rectangular spaces (achRectAB) test a,b ~0, both against TOL_JND. Spaces
  ## with no predicate (achNone, e.g. RGB) return false — RGB achromaticity
  ## needs equal channels and is handled in the conversion layer. NaN
  ## comparisons are false, so NaN components read as chromatic.
  let d = spaceByTag(c.spaceTag)
  if d.isNone:
    return false
  let kind = d.get.achromaticKind
  case kind
  of achNone:
    false
  of achPolarChroma:
    abs(float64(c.comp(1))) < TOL_JND
  of achRectAB:
    hypot(float64(c.comp(1)), float64(c.comp(2))) < TOL_JND
