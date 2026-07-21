<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# unicolor — Python binding

```bash
nimble clib                                              # build libUniColor.so
cd py && python3 setup.py build_ext --inplace            # build extension
cd py && python3 -m pytest -q                            # test
```

```python
import unicolor
unicolor.version()       # "0.1.0"
```