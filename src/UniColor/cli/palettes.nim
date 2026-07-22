# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## cli/palettes — palette subcommands. A palette is args-based (no importer
## yields one): build it inline from hex colors, then colorat / sample / validate.
import ../../UniColor
import std/options
import std/strutils
import UniColor/cli/color

proc parseTag(name: string): Option[PaletteTag] =
  case name.toLowerAscii()
  of "ordered": some(palOrdered)
  of "unordered": some(palUnordered)
  of "scientific": some(palScientific)
  of "terminal": some(palTerminal)
  of "categorical": some(palCategorical)
  of "continuous": some(palContinuous)
  of "semantic": some(palSemantic)
  else: none(PaletteTag)

proc parseIntent(name: string): Option[PaletteIntent] =
  case name.toLowerAscii()
  of "qualitative": some(intentQualitative)
  of "sequential": some(intentSequential)
  of "diverging": some(intentDiverging)
  of "ui": some(intentUI)
  of "scientific": some(intentScientific)
  of "categorical": some(intentCategorical)
  of "terminal": some(intentTerminal)
  else: none(PaletteIntent)

proc parsePaletteFlags(args: seq[string]): tuple[tag: PaletteTag,
    intent: PaletteIntent, seed: int64, colors: seq[string], err: string] =
  ## Pull `--tag T`, `--intent I`, `--seed N` out of `args`; `colors` holds the
  ## positional color strings. Defaults: ordered / sequential / seed 0.
  var tag = palOrdered
  var intent = intentSequential
  var seed: int64 = 0
  var colors: seq[string] = @[]
  var i = 0
  while i < args.len:
    if args[i] == "--tag" and i + 1 < args.len:
      let t = parseTag(args[i + 1])
      if t.isNone:
        return (tag, intent, seed, colors, "unknown tag \"" & args[i + 1] & "\"")
      tag = t.get; i += 2
    elif args[i] == "--intent" and i + 1 < args.len:
      let it = parseIntent(args[i + 1])
      if it.isNone:
        return (tag, intent, seed, colors,
          "unknown intent \"" & args[i + 1] & "\"")
      intent = it.get; i += 2
    elif args[i] == "--seed" and i + 1 < args.len:
      var s: int64
      try: s = parseInt(args[i + 1]).int64
      except ValueError:
        return (tag, intent, seed, colors, "bad seed \"" & args[i + 1] & "\"")
      seed = s; i += 2
    else:
      colors.add(args[i]); i += 1
  (tag, intent, seed, colors, "")

proc buildPalette(colors: seq[string], tag: PaletteTag, intent: PaletteIntent,
    seed: int64): tuple[p: Option[Palette], err: string] =
  if colors.len == 0: return (none(Palette), "palette needs <color> ...")
  var cols: seq[Color] = @[]
  for c in colors:
    let parsed = parseColorArg(c)
    if parsed.isNone: return (none(Palette), "could not parse \"" & c & "\"")
    cols.add(parsed.get)
  let r = palette(tag, cols, intent, seed)
  if not r.isOk:
    return (none(Palette), "palette build failed: " & r.error.message)
  (some(r.get), "")

proc runPalette*(args: seq[string]): tuple[text: string, ok: bool] =
  ## Dispatch the palette subcommands. `args[0]` is the subcommand.
  if args.len == 0:
    return ("palette commands: colorat, sample, validate", false)
  case args[0]
  of "colorat":
    if args.len < 3:
      return ("palette colorat needs <i> <color> ...", false)
    var idx: int
    try: idx = parseInt(args[1])
    except ValueError: return ("bad index \"" & args[1] & "\"", false)
    let f = parsePaletteFlags(args[2 ..< args.len])
    if f.err.len > 0: return (f.err, false)
    let b = buildPalette(f.colors, f.tag, f.intent, f.seed)
    if b.err.len > 0: return (b.err, false)
    let r = b.p.get.colorAt(idx)
    if not r.isOk: return ("colorAt failed: " & r.error.message, false)
    return (formatLine(r.get, false), true)
  of "sample":
    if args.len < 3:
      return ("palette sample needs <t> <color> ...", false)
    var t: float64
    try: t = parseFloat(args[1])
    except ValueError: return ("bad t \"" & args[1] & "\"", false)
    let f = parsePaletteFlags(args[2 ..< args.len])
    if f.err.len > 0: return (f.err, false)
    let b = buildPalette(f.colors, f.tag, f.intent, f.seed)
    if b.err.len > 0: return (b.err, false)
    let r = b.p.get.sample(t)
    if not r.isOk: return ("sample failed: " & r.error.message, false)
    return (formatLine(r.get, false), true)
  of "validate":
    if args.len < 2:
      return ("palette validate needs <color> ...", false)
    let f = parsePaletteFlags(args[1 ..< args.len])
    if f.err.len > 0: return (f.err, false)
    let b = buildPalette(f.colors, f.tag, f.intent, f.seed)
    if b.err.len > 0: return (b.err, false)
    return (formatReport(validatePalette(b.p.get)), true)
  else: return ("unknown palette command: " & args[0], false)
