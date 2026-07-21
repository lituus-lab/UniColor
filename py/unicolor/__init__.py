# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""unicolor — Python binding over the UniColor C library."""
from ._core import version as _version_c

__version__ = _version_c().decode("ascii")


def version():
    """C library version string."""
    return _version_c().decode("ascii")


__all__ = ["version", "__version__"]