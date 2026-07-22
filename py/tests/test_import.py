# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import pytest

import unicolor as uc


def _theme_json():
    t = uc.theme([
        ("surface", uc.srgb(1.0, 1.0, 1.0), None),
        ("text", uc.srgb(0.0, 0.0, 0.0), None),
    ])
    return t.export("json")


def test_import_theme_roundtrips():
    j = _theme_json()
    t = uc.import_theme(j, "json")
    assert t.count == 2
    # JSON stores OKLCH, so the re-imported primitive resolves as OKLCH.
    assert t.resolve("surface").tag == uc.TAG_OKLCH


def test_import_reported_format_name():
    j = _theme_json()
    rep = uc.import_reported(j, "json")
    assert rep.format_name == "json"
    assert rep.warning_count >= 0


def test_import_theme_bad_format_raises():
    with pytest.raises(ValueError):
        uc.import_theme(_theme_json(), "nosuchformat")


def test_import_palette_kind_mismatch_raises():
    # No importer yields a Palette (every importer targets a theme), so a theme
    # JSON fed to import_palette is a kind mismatch → NULL.
    with pytest.raises(ValueError):
        uc.import_palette(_theme_json(), "json")


def test_import_reported_bad_format_raises():
    with pytest.raises(ValueError):
        uc.import_reported("not a real source", "nosuchformat")