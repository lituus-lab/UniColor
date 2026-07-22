# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import math

import pytest

import unicolor as uc


def test_parse_hex_roundtrips_tag():
    c = uc.parse("#ff0000")
    assert c.tag == uc.TAG_SRGB
    assert c.alpha == 1.0


def test_parse_oklch_keeps_tag():
    c = uc.parse("oklch(0.65 0.18 250)")
    assert c.tag == uc.TAG_OKLCH


def test_parse_malformed_raises():
    with pytest.raises(ValueError):
        uc.parse("notacolor")


def test_srgb_factory():
    c = uc.srgb(1.0, 0.0, 0.0)
    assert c.tag == uc.TAG_SRGB
    assert c.components == (1.0, 0.0, 0.0)


def test_oklch_factory():
    c = uc.oklch(0.65, 0.18, 250.0)
    assert c.tag == uc.TAG_OKLCH


def test_make_bad_alpha_raises():
    with pytest.raises(ValueError):
        uc.make(uc.TAG_SRGB, 0.5, 0.5, 0.5, 2.0)


def test_make_nan_component_raises():
    with pytest.raises(ValueError):
        uc.make(uc.TAG_SRGB, float("nan"), 0.5, 0.5)


def test_format_css_default_oklch():
    s = uc.parse("#ff0000").format_css()
    assert s.startswith("oklch(")


def test_format_css_legacy_hex():
    s = uc.parse("#ff0000").format_css(legacy=True)
    assert s.startswith("#")


def test_convert_changes_tag():
    c = uc.parse("#ff0000").convert(uc.TAG_OKLCH)
    assert c.tag == uc.TAG_OKLCH


def test_convert_unknown_target_raises():
    with pytest.raises(ValueError):
        uc.parse("#ff0000").convert(9999)


def test_gamut_map_into_srgb():
    c = uc.oklch(0.7, 0.3, 200.0).gamut_map(uc.TAG_SRGB)
    assert c.tag == uc.TAG_SRGB


def test_contrast_black_white_wcag22():
    v = uc.contrast(uc.parse("#000000"), uc.parse("#ffffff"))
    assert v > 20.0


def test_contrast_method_on_color():
    v = uc.parse("#000000").contrast(uc.parse("#ffffff"))
    assert v > 20.0


def test_contrast_named_metric_apca():
    v = uc.contrast(uc.parse("#000000"), uc.parse("#ffffff"), metric="apca")
    assert not math.isnan(v)
    assert v != 0.0


def test_contrast_bad_metric_raises():
    with pytest.raises(ValueError):
        uc.contrast(uc.parse("#000000"), uc.parse("#ffffff"), metric="bogus")


def test_distance_positive_between_distinct():
    d = uc.distance(uc.parse("#ff0000"), uc.parse("#00ff00"), "deltaE_ok")
    assert d > 0.0


def test_distance_zero_identical():
    d = uc.distance(uc.parse("#ff0000"), uc.parse("#ff0000"), "deltaE_ok")
    assert abs(d) < 1e-6


def test_distance_bad_metric_raises():
    with pytest.raises(ValueError):
        uc.distance(uc.parse("#ff0000"), uc.parse("#00ff00"), "bogus")


def test_repr_and_str():
    c = uc.parse("#ff0000")
    assert str(c) == c.format_css()
    assert repr(c) == "Color(%s)" % c.format_css()