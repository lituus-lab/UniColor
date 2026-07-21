<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# unicolor — Python binding

```bash
nimble pyLib                                    # native lib for this platform
(cd py && python3 setup.py build_ext --inplace) # build the Cython extension
(cd py && python3 -m pytest -q)                 # test
```

`nimble pyLib` builds the shared lib on Linux/macOS and the MSVC static lib on
Windows, so the same commands work everywhere. The subshells keep your shell's
cwd unchanged.

```python
import unicolor
unicolor.version()       # "0.1.0"
```