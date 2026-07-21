# cython: language_level=3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
cdef extern from "UniColor.h":
    const char *uc_version()


def version():
    """Raw C call. Use unicolor.version."""
    return uc_version()