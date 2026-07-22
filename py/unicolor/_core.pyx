# cython: language_level=3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Cython binding over the UniColor C ABI. Importing this module runs uc_init
once, populating the contrast / spaces / import / export / validation
registries before any registry-based call."""
from libc.stdlib cimport malloc, free

cdef extern from "UniColor.h":
    const char *uc_version()
    void uc_init()
    int uc_abi_major()
    int uc_abi_minor()
    int uc_abi_patch()
    # SpaceTag ordinals (frozen in UniColor.h).
    int UC_TAG_UNKNOWN
    int UC_TAG_SRGB
    int UC_TAG_SRGB_LIN
    int UC_TAG_P3
    int UC_TAG_P3_LIN
    int UC_TAG_REC2020
    int UC_TAG_REC2020_LIN
    int UC_TAG_A98
    int UC_TAG_A98_LIN
    int UC_TAG_PROPHOTO
    int UC_TAG_PROPHOTO_LIN
    int UC_TAG_XYZ
    int UC_TAG_XYY
    int UC_TAG_LAB
    int UC_TAG_LCH
    int UC_TAG_OKLAB
    int UC_TAG_OKLCH
    int UC_TAG_HSV
    int UC_TAG_HSL
    int UC_TAG_HWB
    int UC_TAG_CMYK
    int UC_TAG_YCBCR
    int UC_TAG_ICTCP
    int UC_TAG_JZAZBZ
    int UC_TAG_CAM16
    int UC_TAG_CAM16_UCS
    int UC_TAG_HCT
    cdef struct uc_color:
        float comps[4]
        int tag
    uc_color uc_color_make(int tag, float c0, float c1, float c2, float alpha)
    uc_color uc_color_srgb(float r, float g, float b)
    uc_color uc_color_oklch(float l, float c, float h)
    uc_color uc_parse(const char *s)
    size_t uc_format_css(uc_color c, int legacy, char *buf, size_t size)
    void uc_color_components(uc_color c, float *c0, float *c1, float *c2)
    float uc_color_alpha(uc_color c)
    int uc_color_tag(uc_color c)
    uc_color uc_gamut_map(uc_color c, int target)
    uc_color uc_convert(uc_color c, int target)
    double uc_contrast(uc_color fg, uc_color bg)
    double uc_contrast_metric(uc_color fg, uc_color bg, const char *metric)
    double uc_distance(uc_color a, uc_color b, const char *metric)

# Populate the Nim registries once on import.
uc_init()

cdef str _format_css(uc_color c, bint legacy):
    """Measure-then-fill helper for uc_format_css."""
    cdef size_t need = uc_format_css(c, legacy, NULL, 0)
    if need == 0:
        return ""
    cdef char* buf = <char*>malloc(need + 1)
    if buf == NULL:
        raise MemoryError()
    uc_format_css(c, legacy, buf, need + 1)
    cdef str s = buf[:need].decode("utf-8")
    free(buf)
    return s

cdef class Color:
    """A perceptual color: 4 float32 components + a SpaceTag. Build via the
    classmethods `parse` / `srgb` / `oklch` / `make`; a failed build raises
    ValueError (the C sentinel has tag == UC_TAG_UNKNOWN)."""
    cdef uc_color _c

    cdef inline int _check(self) except -1:
        if self._c.tag == UC_TAG_UNKNOWN:
            raise ValueError("invalid color (sentinel)")
        return 0

    def __init__(self):
        self._c.tag = UC_TAG_UNKNOWN

    @classmethod
    def parse(cls, str s):
        cdef Color r = Color()
        r._c = uc_parse(s.encode("utf-8"))
        r._check()
        return r

    @classmethod
    def srgb(cls, float r, float g, float b):
        cdef Color out = Color()
        out._c = uc_color_srgb(r, g, b)
        out._check()
        return out

    @classmethod
    def oklch(cls, float l, float c, float h):
        cdef Color out = Color()
        out._c = uc_color_oklch(l, c, h)
        out._check()
        return out

    @classmethod
    def make(cls, int tag, float c0, float c1, float c2, float alpha=1.0):
        cdef Color out = Color()
        out._c = uc_color_make(tag, c0, c1, c2, alpha)
        out._check()
        return out

    @property
    def tag(self):
        return self._c.tag

    @property
    def alpha(self):
        return uc_color_alpha(self._c)

    @property
    def components(self):
        cdef float c0, c1, c2
        uc_color_components(self._c, &c0, &c1, &c2)
        return (c0, c1, c2)

    def format_css(self, bint legacy=False):
        return _format_css(self._c, legacy)

    def convert(self, int target):
        cdef Color out = Color()
        out._c = uc_convert(self._c, target)
        out._check()
        return out

    def gamut_map(self, int target):
        cdef Color out = Color()
        out._c = uc_gamut_map(self._c, target)
        out._check()
        return out

    def contrast(self, Color bg, str metric=None):
        cdef double v
        if metric is None:
            v = uc_contrast(self._c, bg._c)
        else:
            v = uc_contrast_metric(self._c, bg._c, metric.encode("utf-8"))
        if v != v:  # NaN: sentinel operand or bad metric
            raise ValueError("contrast failed (sentinel operand or bad metric)")
        return v

    def distance(self, Color other, str metric):
        cdef double v = uc_distance(self._c, other._c, metric.encode("utf-8"))
        if v != v:
            raise ValueError("distance failed (sentinel operand or bad metric)")
        return v

    def __repr__(self):
        return "Color(%s)" % self.format_css()

    def __str__(self):
        return self.format_css()


def version():
    """C library version string."""
    return uc_version().decode("ascii")


def abi_major():
    return uc_abi_major()


def abi_minor():
    return uc_abi_minor()


def abi_patch():
    return uc_abi_patch()


def parse(str s):
    return Color.parse(s)


def srgb(float r, float g, float b):
    return Color.srgb(r, g, b)


def oklch(float l, float c, float h):
    return Color.oklch(l, c, h)


def make(int tag, float c0, float c1, float c2, float alpha=1.0):
    return Color.make(tag, c0, c1, c2, alpha)


def contrast(Color fg, Color bg, str metric=None):
    cdef double v
    if metric is None:
        v = uc_contrast(fg._c, bg._c)
    else:
        v = uc_contrast_metric(fg._c, bg._c, metric.encode("utf-8"))
    if v != v:
        raise ValueError("contrast failed (sentinel operand or bad metric)")
    return v


def distance(Color a, Color b, str metric):
    cdef double v = uc_distance(a._c, b._c, metric.encode("utf-8"))
    if v != v:
        raise ValueError("distance failed (sentinel operand or bad metric)")
    return v


# SpaceTag ordinals, mirrored from UniColor.h so callers can pass `uc.TAG_OKLCH`
# without C #defines. Kept in sync with the header.
TAG_UNKNOWN = UC_TAG_UNKNOWN
TAG_SRGB = UC_TAG_SRGB
TAG_SRGB_LIN = UC_TAG_SRGB_LIN
TAG_P3 = UC_TAG_P3
TAG_P3_LIN = UC_TAG_P3_LIN
TAG_REC2020 = UC_TAG_REC2020
TAG_REC2020_LIN = UC_TAG_REC2020_LIN
TAG_A98 = UC_TAG_A98
TAG_A98_LIN = UC_TAG_A98_LIN
TAG_PROPHOTO = UC_TAG_PROPHOTO
TAG_PROPHOTO_LIN = UC_TAG_PROPHOTO_LIN
TAG_XYZ = UC_TAG_XYZ
TAG_XYY = UC_TAG_XYY
TAG_LAB = UC_TAG_LAB
TAG_LCH = UC_TAG_LCH
TAG_OKLAB = UC_TAG_OKLAB
TAG_OKLCH = UC_TAG_OKLCH
TAG_HSV = UC_TAG_HSV
TAG_HSL = UC_TAG_HSL
TAG_HWB = UC_TAG_HWB
TAG_CMYK = UC_TAG_CMYK
TAG_YCBCR = UC_TAG_YCBCR
TAG_ICTCP = UC_TAG_ICTCP
TAG_JZAZBZ = UC_TAG_JZAZBZ
TAG_CAM16 = UC_TAG_CAM16
TAG_CAM16_UCS = UC_TAG_CAM16_UCS
TAG_HCT = UC_TAG_HCT