# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## cli/cli — the `unicolor` command-line entry. `run` is the testable core (no
## stdout/stderr side effects); `when isMainModule` wires it to the OS.
import ../../UniColor
import std/os
import UniColor/cli/color
import UniColor/cli/themes

const Help = "unicolor " & UniColorVersion & " — perceptual color engine\n" &
  "usage: unicolor <command> [args]\n" &
  "commands:\n" &
  "  version                 print the engine version\n" &
  "  parse <color>           show a color (OKLCH form + space tag)\n" &
  "  convert <color> <space> [--legacy]  convert to a space\n" &
  "  gamut <color> <space> [--legacy]    gamut-map into a space\n" &
  "  contrast <fg> <bg> [metric]         contrast ratio (default wcag22)\n" &
  "  distance <a> <b> [metric]           perceptual distance (default deltaE_ok)\n" &
  "  theme <resolve|export|validate> ...   theme from a file\n" &
  "  palette <colorat|sample|validate> ... palette from colors"

proc run*(args: seq[string]): tuple[text: string, ok: bool] =
  ## Dispatch a command. Returns the output text and an ok flag (exit code).
  if args.len == 0: return (Help, true)
  case args[0]
  of "version": return (UniColorVersion, true)
  of "parse", "convert", "gamut", "contrast", "distance":
    return runColor(args)
  of "theme": return runTheme(args[1 ..< args.len])
  of "palette": return ("palette commands: colorat, sample, validate", false)
  else: return ("unknown command: " & args[0] & "\n\n" & Help, false)

when isMainModule:
  let r = run(commandLineParams())
  if r.ok: echo r.text
  else: stderr.writeLine(r.text)
  quit(if r.ok: 0 else: 1)
