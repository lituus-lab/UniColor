# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## cli/themes — theme subcommands. A theme is file-based: read the file, sniff
## its format (or take --format), import it, then resolve / export / validate.
import ../../UniColor
import std/os
import std/options
import UniColor/cli/color

proc loadTheme(file, fmt: string): tuple[t: Option[Theme], err: string] =
  ## Read `file` and import it as `fmt` (sniffed when fmt is empty).
  if not fileExists(file): return (none(Theme), "file not found: " & file)
  let input = try: readFile(file)
              except IOError as e:
                return (none(Theme), "could not read " & file & ": " & e.msg)
  let name = if fmt.len > 0: fmt else:
    let s = sniffFormat(input)
    if s.isSome: s.get
    else: return (none(Theme), "could not detect format; pass --format")
  let r = importTheme(input, name)
  if not r.isOk: return (none(Theme), "import failed: " & r.error.message)
  (some(r.get), "")

proc runTheme*(args: seq[string]): tuple[text: string, ok: bool] =
  ## Dispatch the theme subcommands. `args[0]` is the subcommand.
  if args.len == 0:
    return ("theme commands: resolve, export, validate", false)
  let f = parseFlags(args[1 ..< args.len])
  case args[0]
  of "resolve":
    if f.pos.len < 2:
      return ("theme resolve needs <file> <role> [--format F]", false)
    let load = loadTheme(f.pos[0], f.fmt)
    if load.err.len > 0: return (load.err, false)
    let r = load.t.get.resolve(f.pos[1])
    if not r.isOk:
      return ("could not resolve role \"" & f.pos[1] & "\"", false)
    return (formatLine(r.get, false), true)
  of "export":
    if f.pos.len < 2:
      return ("theme export needs <file> <fmt> [--legacy] [--format F]", false)
    let load = loadTheme(f.pos[0], f.fmt)
    if load.err.len > 0: return (load.err, false)
    let opts = ExportOpts(legacySrgb: f.legacy, prefix: "--", dark: none(Theme))
    let r = exportTheme(load.t.get, f.pos[1], opts)
    if not r.isOk: return ("export failed: " & r.error.message, false)
    return (r.get, true)
  of "validate":
    if f.pos.len < 1:
      return ("theme validate needs <file> [--format F]", false)
    let load = loadTheme(f.pos[0], f.fmt)
    if load.err.len > 0: return (load.err, false)
    return (formatReport(validateTheme(load.t.get)), true)
  else: return ("unknown theme command: " & args[0], false)
