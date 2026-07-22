# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import pytest

import unicolor as uc


def _theme():
    return uc.theme([
        ("surface", uc.srgb(1.0, 1.0, 1.0), None),
        ("text", uc.srgb(0.0, 0.0, 0.0), None),
    ])


def _palette():
    return uc.palette(
        uc.PAL_TAG_ORDERED,
        [uc.parse("#ff0000"), uc.parse("#00ff00"), uc.parse("#0055ff")],
        uc.PAL_INTENT_SEQUENTIAL,
    )


def test_validate_theme_score_in_range():
    rep = uc.validate_theme(_theme())
    assert 0 <= rep.score <= 100
    assert rep.worst in (
        uc.SEVERITY_INFO, uc.SEVERITY_WARNING, uc.SEVERITY_ERROR,
        uc.SEVERITY_FATAL,
    )


def test_validate_theme_rule_namedtuple():
    rep = uc.validate_theme(_theme())
    assert rep.rule_count >= 0
    if rep.rule_count > 0:
        r = rep.rule(0)
        assert r.name
        assert r.severity in (
            uc.SEVERITY_INFO, uc.SEVERITY_WARNING, uc.SEVERITY_ERROR,
            uc.SEVERITY_FATAL,
        )
        assert isinstance(r.metric, float)
        assert isinstance(r.threshold, float)
        assert isinstance(r.message, str)


def test_validate_theme_rule_out_of_range_raises():
    rep = uc.validate_theme(_theme())
    with pytest.raises(IndexError):
        rep.rule(10_000)


def test_validate_palette_score_in_range():
    rep = uc.validate_palette(_palette())
    assert 0 <= rep.score <= 100
    assert rep.worst in (
        uc.SEVERITY_INFO, uc.SEVERITY_WARNING, uc.SEVERITY_ERROR,
        uc.SEVERITY_FATAL,
    )


def test_validate_palette_rule_namedtuple():
    rep = uc.validate_palette(_palette())
    if rep.rule_count > 0:
        r = rep.rule(0)
        assert r.name
        assert isinstance(r.message, str)