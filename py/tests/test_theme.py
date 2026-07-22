# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import pytest

import unicolor as uc


def _theme():
    prims = [
        ("surface", uc.srgb(1.0, 1.0, 1.0), None),
        ("text", uc.srgb(0.0, 0.0, 0.0), None),
    ]
    sems = [("text.primary", None, "text")]
    return uc.theme(prims, sems)


def test_theme_count():
    t = _theme()
    assert t.count == 3


def test_theme_resolve_primitive():
    t = _theme()
    c = t.resolve("surface")
    assert c.tag == uc.TAG_SRGB


def test_theme_resolve_semantic_alias():
    t = _theme()
    c = t.resolve("text.primary")
    assert c.tag == uc.TAG_SRGB


def test_theme_has_role():
    t = _theme()
    assert t.has_role("surface")
    assert t.has_role("text.primary")
    assert not t.has_role("nope")


def test_theme_resolve_missing_raises():
    t = _theme()
    with pytest.raises(ValueError):
        t.resolve("nope")


def test_theme_export_css():
    t = _theme()
    s = t.export("css")
    assert "--surface" in s


def test_theme_export_legacy_hex():
    t = _theme()
    s = t.export("css", legacy=True)
    assert "#" in s


def test_theme_make_empty_name_raises():
    with pytest.raises(ValueError):
        uc.theme([("", uc.srgb(1, 0, 0), None)])


def test_theme_make_duplicate_role_raises():
    with pytest.raises(ValueError):
        uc.theme([("a", uc.srgb(1, 0, 0), None), ("a", uc.srgb(0, 1, 0), None)])


def test_theme_dangling_alias_resolves_to_raises():
    t = uc.theme([("a", uc.srgb(1, 0, 0), None)], [("b", None, "missing")])
    assert t.has_role("b")
    with pytest.raises(ValueError):
        t.resolve("b")