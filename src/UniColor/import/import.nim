# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# import — importers registry + sniff + schema + reconstruct + partial.
# Facade. `import` is a Nim keyword, so this module and its sub-modules are
# imported with the quoted form `import "UniColor/import/..."`.
#
# Format importers (CSS vars, JSON/TOML/YAML, Base16/24, terminals, IDE)
# self-register at import time as bootstrap side effects. Each leaf is imported
# for side effect ONLY (no `export` — the leaves expose no public symbols; they
# push an `Importer` into the registry at load time). `import` is a Nim keyword
# -> the leaves use the quoted form `import "UniColor/import/formats_..."`.
# PARTIAL coverage: terminals ship 4 of 8 (wezterm/ghostty/warp/xresources
# deferred), IDE 2 of 4 (neovim/jetbrains deferred) — documented missing slots,
# mechanical follow-up (same inverse maps, only per-format parsing differs).
import "UniColor/import/registry"
import "UniColor/import/sniff"
import "UniColor/import/schema"
import "UniColor/import/reconstruct"
import "UniColor/import/partial"
import "UniColor/import/formats_css"
import "UniColor/import/formats_data"
import "UniColor/import/formats_base16"
import "UniColor/import/formats_terminals"
import "UniColor/import/formats_ide"
export registry
export sniff
export schema
export reconstruct
export partial

const importModule* = "0.1.0"
