# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## cli/color — color-core subcommands + shared parse/tag helpers. The helpers
## are shared with cli/theme and cli/palette (same vgraph layer), so this module
## is the base of the cli group.
import ../../UniColor
import std/options

proc parseColorArg*(s: string): Option[Color] =
  ## Parse a CSS Color 4 string into a Color, or none on a malformed input.
  let r = parseColor(s)
  if r.isOk: some(r.get) else: none(Color)

proc spaceTagByName*(name: string): Option[SpaceTag] =
  ## Resolve a canonical space name ("srgb", "oklch", ...) to its SpaceTag.
  let d = lookupSpace(name)
  if d.isSome: some(d.get.tag) else: none(SpaceTag)

proc formatLine*(c: Color, legacy: bool): string =
  ## A color as "css-form  [tag-name]" — the css form is OKLCH unless legacy.
  formatColorCss(c, legacy) & "  [" & spaceName(c.spaceTag) & "]"

proc runColor*(args: seq[string]): tuple[text: string, ok: bool] =
  ## Dispatch the color-core subcommands. `args[0]` is the subcommand.
  if args.len == 0:
    return ("color commands: parse, convert, gamut, contrast, distance", false)
  case args[0]
  of "parse":
    if args.len < 2: return ("parse needs <color>", false)
    let c = parseColorArg(args[1])
    if c.isNone: return ("could not parse \"" & args[1] & "\"", false)
    return (formatLine(c.get, false), true)
  of "convert", "gamut":
    if args.len < 3:
      return (args[0] & " needs <color> <space> [--legacy]", false)
    let legacy = args.len >= 4 and args[3] == "--legacy"
    let c = parseColorArg(args[1])
    if c.isNone: return ("could not parse \"" & args[1] & "\"", false)
    let tag = spaceTagByName(args[2])
    if tag.isNone: return ("unknown space \"" & args[2] & "\"", false)
    let r = if args[0] == "convert": c.get.to(tag.get)
            else: c.get.gamutMap(tag.get)
    if not r.isOk: return (args[0] & " failed", false)
    return (formatLine(r.get, legacy), true)
  of "contrast":
    if args.len < 3: return ("contrast needs <fg> <bg> [metric]", false)
    let fg = parseColorArg(args[1])
    if fg.isNone: return ("could not parse \"" & args[1] & "\"", false)
    let bg = parseColorArg(args[2])
    if bg.isNone: return ("could not parse \"" & args[2] & "\"", false)
    let r = if args.len >= 4: contrast(fg.get, bg.get, args[3])
            else: contrast(fg.get, bg.get)
    if not r.isOk: return ("contrast failed", false)
    return ($r.get, true)
  of "distance":
    if args.len < 3: return ("distance needs <a> <b> [metric]", false)
    let a = parseColorArg(args[1])
    if a.isNone: return ("could not parse \"" & args[1] & "\"", false)
    let b = parseColorArg(args[2])
    if b.isNone: return ("could not parse \"" & args[2] & "\"", false)
    let metric = if args.len >= 4: args[3] else: "deltaE_ok"
    let r = distance(a.get, b.get, metric)
    if not r.isOk:
      return ("distance failed (unknown metric \"" & metric & "\"?)", false)
    return ($r.get, true)
  else: return ("unknown color command: " & args[0], false)
