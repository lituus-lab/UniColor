# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Build unicolor._core, a Cython extension over the UniColor C ABI.
Run `nimble pyLib` first so the library is at the repo root."""
import os
import shutil
import sys

from setuptools import Extension, setup
from Cython.Build import cythonize

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
INCLUDE = os.path.join(ROOT, "include")
PKG_DIR = os.path.join(HERE, "unicolor")

# Windows: link a vcc static lib, since MSVC CPython cannot link MinGW output.
# Elsewhere: bundle the shared lib in the package, found through an rpath
# relative to the extension.
if sys.platform == "win32":
    LIB_NAME, BUNDLED = "UniColor.lib", False
    LINK_ARGS, NIMBLE_TASK = [], "clibMsvc"
elif sys.platform == "darwin":
    LIB_NAME, BUNDLED = "libUniColor.dylib", True
    LINK_ARGS, NIMBLE_TASK = ["-Wl,-rpath,@loader_path"], "clib"
else:
    LIB_NAME, BUNDLED = "libUniColor.so", True
    LINK_ARGS, NIMBLE_TASK = ["-Wl,-rpath,$ORIGIN"], "clib"

# Copy the shared library into the package dir at import time, before setup()
# runs any command. A copy done from a custom build_ext.run() instead landed
# too late on some setuptools versions: build_py had already scanned
# package_data by the time build_ext ran, so the wheel shipped without the
# library and delocate/auditwheel failed to find it downstream.
src = os.path.join(ROOT, LIB_NAME)
if not os.path.exists(src):
    raise SystemExit(f"setup.py: {src} not found — run `nimble {NIMBLE_TASK}` first.")
if BUNDLED:
    os.makedirs(PKG_DIR, exist_ok=True)
    shutil.copy2(src, os.path.join(PKG_DIR, LIB_NAME))

ext = Extension(
    "unicolor._core",
    sources=[os.path.join("unicolor", "_core.pyx")],
    include_dirs=[INCLUDE],
    library_dirs=[ROOT],
    extra_link_args=LINK_ARGS,
    libraries=["UniColor"],
)

setup(
    ext_modules=cythonize([ext], language_level=3),
    include_package_data=True,
    package_data={"unicolor": [LIB_NAME] if BUNDLED else []},
    exclude_package_data={"unicolor": ["_core.c"]},
    zip_safe=False,
)
