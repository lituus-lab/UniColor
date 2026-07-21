# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# export/zsh_tmux — shell + multiplexer theme exporters, registered as "zsh"
# and "tmux". These are SHELL / MULTIPLEXER configs (not editors, not
# ANSI-bounded terminal palettes): like the IDE exporters, they project a
# DECLARED role subset into the tool's own vocabulary and OMIT roles with no
# mapping (no `warnInfoLost` — contrast base16/terminals which are slot-bounded
# and DO warn). Colors are 24-bit truecolor (zsh `%{\e[38;2;R;G;Bm%}`, tmux
# `#rrggbb` in *-style, tmux >= 2.9), so the output does NOT depend on the
# terminal's 16-color palette being loaded.
#
#   - zsh : a `source`-able script defining truecolor prompt vars + PROMPT +
#           LS_COLORS. The prompt uses `primary` (cwd) + `accent` (git).
#   - tmux: a `source`-able conf setting status bar, window list, pane borders,
#           message, clock, mode and popup styles from the theme roles.
#
# Determinism: roles resolved in a FIXED order (independent of theme insertion
# order); gamut-map is deterministic; the header is a literal. Same (theme,
# opts) -> byte-identical output. No RNG, no I/O.
#
# Self-registers via `discard registerExporter(...)`; the facade
# `export/export.nim` imports this module to fire it.
#
# Layer: export (consumer of serialize + registry + conversion + theme).
import std/options
import std/strutils # join (LS_COLORS parts).
import UniColor/core/core # Color, tagSrgb.
import UniColor/core/result
import UniColor/core/color_error
import UniColor/conversion/conversion # gamutMap.
import UniColor/theme/tree
import "UniColor/export/serialize" # genHeader / formatColorCss.
import "UniColor/export/registry" # Exporter / ExportOpts / ExportReport / registerExporter.

# A resolved theme role rendered as sRGB `#rrggbb` (tmux *-style). `none` if the
# role is absent or unresolvable (lossless omit — no warning). Mirrors
# ide.resolveHex.
proc hexHash(theme: Theme, role: string): Option[string] {.raises: [].} =
  let rR = theme.resolve(role)
  if rR.isErr:
    return none(string)
  let gR = gamutMap(rR.get, tagSrgb)
  if gR.isErr:
    return none(string)
  some(formatColorCss(gR.get, true)) # "#rrggbb" (c is sRGB after gamutMap).

# A resolved theme role rendered as `R;G;B` decimals (zsh truecolor
# `38;2;R;G;B`). `none` if absent/unresolvable. The color is gamut-mapped to
# sRGB first; components are 0..1 float32, so `int(c*255 + 0.5)` matches the
# rounding `hexByte` uses (consistency with the `#rrggbb` path).
proc rgbDec(theme: Theme, role: string): Option[string] {.raises: [].} =
  let rR = theme.resolve(role)
  if rR.isErr:
    return none(string)
  let gR = gamutMap(rR.get, tagSrgb)
  if gR.isErr:
    return none(string)
  let (c0, c1, c2) = gR.get.components
  some($(int(c0 * 255.0 + 0.5)) & ";" & $(int(c1 * 255.0 + 0.5)) & ";" &
      $(int(c2 * 255.0 + 0.5)))

# zsh truecolor escape: `%{<esc>%}` wraps raw bytes so the prompt knows their
# display width is 0.
proc zshFg(theme: Theme, role: string): Option[string] {.raises: [].} =
  let d = rgbDec(theme, role)
  if d.isSome:
    some("%{\\e[38;2;" & d.get & "m%}")
  else:
    none(string)

const zshReset = "%{\\e[0m%}"

# --- zsh ---------------------------------------------------------------
proc zshRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  var lines: seq[string]
  lines.add("# " & genHeader("zsh", SerializeOpts(target: tagSrgb,
      legacySrgb: true)))
  lines.add("# Source from ~/.zshrc:  source /path/to/this-file.zsh")
  lines.add("# Colors are 24-bit truecolor — independent of the terminal 16-color palette.")
  # Role -> shell var (only roles present in the theme are emitted; absent roles
  # are omitted). `UC_` prefix (UniColor) — the import side for zsh is out of
  # scope, so the var prefix is a free brand choice (no round-trip constraint).
  let vars: seq[(string, string)] = @[
    ("BACKGROUND", "background"), ("SURFACE", "surface"),
    ("FG", "text.primary"), ("MUTED", "text.muted"),
    ("PRIMARY", "primary"), ("SECONDARY", "secondary"),
    ("TERTIARY", "tertiary"), ("ACCENT", "accent"),
    ("ERROR", "error"), ("WARNING", "warning"),
    ("SUCCESS", "success"), ("INFO", "info")]
  for (varName, role) in vars:
    let h = hexHash(theme, role)
    if h.isSome:
      lines.add("UC_" & varName & "=\"" & h.get & "\"")
  lines.add("UC_RESET=\"%{" & "\\e[0m" & "%}\"")
  lines.add("")
  # Prompt: cwd in primary, git branch in accent, prompt char in muted.
  let cwd = zshFg(theme, "primary")
  let acc = zshFg(theme, "accent")
  let mut = zshFg(theme, "text.muted")
  lines.add("autoload -Uz vcs_info")
  lines.add("zstyle ':vcs_info:*' enable git")
  lines.add("zstyle ':vcs_info:*' formats '%b'")
  lines.add("setopt prompt_subst")
  var ps1 = "PS1=\""
  if cwd.isSome:
    ps1.add(cwd.get)
  ps1.add("%~")
  if cwd.isSome:
    ps1.add(zshReset)
  ps1.add(" ")
  if acc.isSome:
    ps1.add(acc.get)
  ps1.add("${vcs_info_msg_0_:+ ${vcs_info_msg_0_}}")
  if acc.isSome:
    ps1.add(zshReset)
  ps1.add(" ")
  if mut.isSome:
    ps1.add(mut.get)
  ps1.add("%#")
  if mut.isSome:
    ps1.add(zshReset)
  ps1.add(" \"")
  lines.add(ps1)
  # Right prompt: muted hostname.
  var rps1 = "RPS1=\""
  if mut.isSome:
    rps1.add(mut.get)
  rps1.add("%m")
  if mut.isSome:
    rps1.add(zshReset)
  rps1.add("\"")
  lines.add(rps1)
  lines.add("precmd() { vcs_info }")
  lines.add("")
  # LS_COLORS in truecolor (38;2;R;G;B) so it does not depend on the loaded
  # 16-color palette. File-type -> role mapping (dir=primary, link=accent,
  # exec=success, archive=warning, image=tertiary).
  let dir = rgbDec(theme, "primary")
  let lnk = rgbDec(theme, "accent")
  let exe = rgbDec(theme, "success")
  let arc = rgbDec(theme, "warning")
  let img = rgbDec(theme, "tertiary")
  let txt = rgbDec(theme, "text.secondary")
  if dir.isSome and lnk.isSome and exe.isSome:
    var parts: seq[string] = @[]
    parts.add("di=38;2;" & dir.get)
    parts.add("ln=38;2;" & lnk.get)
    parts.add("so=38;2;" & dir.get)
    parts.add("pi=38;2;" & dir.get)
    parts.add("ex=38;2;" & exe.get)
    parts.add("bd=38;2;" & dir.get)
    parts.add("cd=38;2;" & dir.get)
    if arc.isSome:
      parts.add("*.tar=38;2;" & arc.get)
      parts.add("*.zip=38;2;" & arc.get)
      parts.add("*.gz=38;2;" & arc.get)
    if img.isSome:
      parts.add("*.png=38;2;" & img.get)
      parts.add("*.jpg=38;2;" & img.get)
    if txt.isSome:
      parts.add("*.md=38;2;" & exe.get)
      parts.add("*.nim=38;2;" & img.get)
      parts.add("*.py=38;2;" & img.get)
      parts.add("*.go=38;2;" & img.get)
      parts.add("*.rs=38;2;" & img.get)
      parts.add("*.ts=38;2;" & img.get)
      parts.add("*.js=38;2;" & img.get)
      parts.add("*.json=38;2;" & txt.get)
      parts.add("*.toml=38;2;" & txt.get)
      parts.add("*.yaml=38;2;" & txt.get)
    lines.add("export LS_COLORS=\"" & parts.join(":") & "\"")
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: @[]))

# --- tmux --------------------------------------------------------------
proc tmuxRender(theme: Theme, opts: ExportOpts): Result[ExportReport,
    ColorError] {.raises: [].} =
  var lines: seq[string]
  lines.add("# " & genHeader("tmux", SerializeOpts(target: tagSrgb,
      legacySrgb: true)))
  lines.add("# Usage:  tmux source-file /path/to/this-file.conf")
  lines.add("# Colors are 24-bit truecolor (tmux >= 2.9).")
  lines.add("set -g default-terminal \"tmux-256color\"")
  lines.add("set -ga terminal-overrides \",*256col*:Tc\"")
  lines.add("set -g status on")
  lines.add("set -g status-position top")
  # status-style bg=background fg=text.primary (both present required for a
  # usable bar).
  let bg = hexHash(theme, "background")
  let fg = hexHash(theme, "text.primary")
  if bg.isSome and fg.isSome:
    lines.add("set -g status-style \"bg=" & bg.get & ",fg=" & fg.get & "\"")
  # status-left: session name on a primary chip.
  let prim = hexHash(theme, "primary")
  if prim.isSome and bg.isSome:
    lines.add("set -g status-left \"#[bg=" & prim.get & ",fg=" & bg.get &
        ",bold] #S #[bg=" & bg.get & ",fg=" & prim.get & "] \"")
  # status-right: muted host + accent time.
  let mut = hexHash(theme, "text.muted")
  let acc = hexHash(theme, "accent")
  var rightParts: seq[string] = @[]
  if mut.isSome:
    rightParts.add("#[fg=" & mut.get & "]#h")
  if acc.isSome:
    rightParts.add("#[fg=" & acc.get & "]%H:%M")
  if rightParts.len > 0:
    lines.add("set -g status-right \"" & rightParts.join(" ") & " #[default]\"")
  lines.add("set -g status-left-length 40")
  lines.add("set -g status-right-length 80")
  # Window list: muted inactive, primary current on surface.
  if mut.isSome:
    lines.add("set -g window-status-format \"#[fg=" & mut.get & "] #I:#W \"")
  let surf = hexHash(theme, "surface")
  if prim.isSome and surf.isSome:
    lines.add("set -g window-status-current-format \"#[bg=" & surf.get &
        ",fg=" & prim.get & ",bold] #I:#W #[default]\"")
  lines.add("set -g window-status-separator \"\"")
  # Pane borders: surface.variant inactive, primary active.
  let sv = hexHash(theme, "surface.variant")
  if sv.isSome:
    lines.add("set -g pane-border-style \"fg=" & sv.get & "\"")
  if prim.isSome:
    lines.add("set -g pane-active-border-style \"fg=" & prim.get & "\"")
  lines.add("set -g pane-border-status off")
  # Message + mode + clock + popup.
  if prim.isSome and bg.isSome:
    lines.add("set -g message-style \"bg=" & prim.get & ",fg=" & bg.get & "\"")
  if sv.isSome and fg.isSome:
    lines.add("set -g message-command-style \"bg=" & sv.get & ",fg=" & fg.get &
        "\"")
  if prim.isSome:
    lines.add("set -g clock-mode-colour \"" & prim.get & "\"")
  if sv.isSome and fg.isSome:
    lines.add("set -g mode-style \"bg=" & sv.get & ",fg=" & fg.get & "\"")
  if bg.isSome and fg.isSome and prim.isSome:
    lines.add("set -g popup-style \"bg=" & bg.get & ",fg=" & fg.get & "\"")
    lines.add("set -g popup-border-style \"fg=" & prim.get & "\"")
  ok[ExportReport, ColorError](ExportReport(output: lines.join("\n"),
      warnings: @[]))

# Bootstrap — register "zsh" and "tmux". Fired by
# `import "UniColor/export/zsh_tmux"`.
discard registerExporter(Exporter(name: "zsh", render: zshRender))
discard registerExporter(Exporter(name: "tmux", render: tmuxRender))
