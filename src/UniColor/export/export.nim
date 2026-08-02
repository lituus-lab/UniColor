# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# export — exporters registry + serialize. Facade. `export` is a Nim keyword,
# so this module and its sub-modules are imported with the quoted form
# `import "UniColor/export/..."`.
#
# Format exporters (CSS vars, Tailwind, Base16/24, IDE, terminals, Nix/Lua,
# JSON/TOML/YAML, zsh, tmux) self-register at import time as bootstrap side
# effects; they land in subsequent commits. This facade ships the registry +
# the shared serialize layer.
import "UniColor/export/registry"
import "UniColor/export/serialize"
import "UniColor/export/css"
import "UniColor/export/tailwind"
import "UniColor/export/base16"
import "UniColor/export/ide"
import "UniColor/export/terminals"
import "UniColor/export/nix_lua"
import "UniColor/export/json_toml_yaml"
import "UniColor/export/zsh_tmux"
export registry
export serialize
export base16 # base16Slots / base24ExtraSlots (reused by the Base16 importer).

const exportModule* = "1.0.0"
