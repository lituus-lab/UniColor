# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# import — importers registry + sniff + schema + reconstruct + partial.
# Facade. `import` is a Nim keyword, so this module and its sub-modules are
# imported with the quoted form `import "UniColor/import/..."`.
#
# Format importers (CSS vars, JSON/TOML/YAML, Base16/24, terminals, IDE)
# self-register at import time as bootstrap side effects; they land in
# subsequent commits. This facade ships the registry + sniff + the schema
# migration gate + the shared reconstruct + the partial-failure helpers.
import "UniColor/import/registry"
import "UniColor/import/sniff"
import "UniColor/import/schema"
import "UniColor/import/reconstruct"
import "UniColor/import/partial"
export registry
export sniff
export schema
export reconstruct
export partial

const importModule* = "0.1.0"
