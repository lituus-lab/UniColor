# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import nimib

nbInit
nb.title = "UniColor"

nbText: """
# UniColor

Perceptual color engine for the `lituus-lab` `Uni*` family: color spaces,
conversions through the XYZ hub, contrast metrics, interpolation, palettes,
themes, and accessibility — exposed across the three surfaces every engine
ships: **Nim**, a **C ABI**, and a **Python** binding.

This page is a nimib book: every Nim block below is compiled and run when the
book is built, and the output shown is what the code actually produced. A change
that breaks the API breaks the docs build, so the two cannot drift apart.

This page walks the version contract every surface shares, then the color
core, conversions, contrast, palettes, and themes below.
"""

nbCode:
  import UniColor

  echo "version ", UniColorVersion

nbText: """
## The three surfaces

- **Nim** — the umbrella module re-exports every public submodule as the domain
  lands. Preconditions are written with NimContracts (`require:` / `ensure:` /
  `body:`), compiled away entirely under `-d:release`.
- **C ABI** — a hand-written header (`include/UniColor.h`) kept in sync with
  `src/UniColor/c_api.nim`. It never raises: out-of-range input is clamped, so an
  exception never unwinds across the ABI boundary. `tests/c` links the header
  against the lib on every CI run, so a drift is caught rather than shipped.
- **Python** — a Cython extension over the C ABI, shipped as a self-contained
  wheel: the native library travels inside the package, so installing it needs
  neither Nim nor a compiler. Where the C ABI clamps, the binding raises
  `ValueError`/`TypeError`, because Python has exceptions to carry the contract.

Each surface expresses one contract in the terms its own callers expect.

`py/notebooks/quickstart.ipynb` runs against an installed wheel and renders on
GitHub directly.
"""

nbSave
