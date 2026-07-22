# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import pytest

import unicolor as uc


def _colors():
    return [uc.parse("#ff0000"), uc.parse("#00ff00"), uc.parse("#0055ff")]


def test_palette_make_ordered():
    p = uc.palette(uc.PAL_TAG_ORDERED, _colors(), uc.PAL_INTENT_SEQUENTIAL)
    assert len(p) == 3
    assert p.tag == uc.PAL_TAG_ORDERED
    assert p.intent == uc.PAL_INTENT_SEQUENTIAL


def test_palette_color_at_in_range():
    p = uc.palette(uc.PAL_TAG_ORDERED, _colors(), uc.PAL_INTENT_SEQUENTIAL)
    c = p.color_at(1)
    assert c.tag != uc.TAG_UNKNOWN


def test_palette_color_at_out_of_range_raises():
    p = uc.palette(uc.PAL_TAG_ORDERED, _colors(), uc.PAL_INTENT_SEQUENTIAL)
    with pytest.raises(ValueError):
        p.color_at(99)


def test_palette_sample_midpoint():
    p = uc.palette(uc.PAL_TAG_ORDERED, _colors(), uc.PAL_INTENT_SEQUENTIAL)
    c = p.sample(0.5)
    assert c.tag != uc.TAG_UNKNOWN


def test_palette_sample_out_of_range_raises():
    p = uc.palette(uc.PAL_TAG_ORDERED, _colors(), uc.PAL_INTENT_SEQUENTIAL)
    with pytest.raises(ValueError):
        p.sample(2.0)


def test_palette_make_empty_raises():
    with pytest.raises(ValueError):
        uc.palette(uc.PAL_TAG_ORDERED, [], uc.PAL_INTENT_SEQUENTIAL)


def test_palette_make_bad_tag_raises():
    with pytest.raises(ValueError):
        uc.palette(9999, _colors(), uc.PAL_INTENT_SEQUENTIAL)