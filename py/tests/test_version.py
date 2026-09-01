# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import unicolor


def test_version():
    assert unicolor.version() == "1.1.0"
    assert unicolor.__version__ == "1.1.0"
