# cython: language_level=3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Cython binding over the UniColor C ABI. Importing this module runs uc_init
once, populating the contrast / spaces / import / export / validation
registries before any registry-based call."""
from libc.stdlib cimport malloc, free
from libc.stdint cimport int64_t

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
    # PaletteTag / PaletteIntent ordinals (frozen in UniColor.h).
    int UC_PAL_TAG_ORDERED
    int UC_PAL_TAG_UNORDERED
    int UC_PAL_TAG_SCIENTIFIC
    int UC_PAL_TAG_TERMINAL
    int UC_PAL_TAG_CATEGORICAL
    int UC_PAL_TAG_CONTINUOUS
    int UC_PAL_TAG_SEMANTIC
    int UC_PAL_INTENT_QUALITATIVE
    int UC_PAL_INTENT_SEQUENTIAL
    int UC_PAL_INTENT_DIVERGING
    int UC_PAL_INTENT_UI
    int UC_PAL_INTENT_SCIENTIFIC
    int UC_PAL_INTENT_CATEGORICAL
    int UC_PAL_INTENT_TERMINAL
    # theme handle
    ctypedef struct uc_theme:
        pass
    ctypedef struct uc_token:
        const char *name
        uc_color color
        const char *alias
    uc_theme *uc_theme_make(uc_token *prim, size_t nprim, uc_token *sem,
        size_t nsem, uc_token *comp, size_t ncomp)
    void uc_theme_free(uc_theme *t)
    uc_color uc_theme_resolve(uc_theme *t, const char *role)
    int uc_theme_count(uc_theme *t)
    int uc_theme_has_role(uc_theme *t, const char *role)
    size_t uc_theme_export(uc_theme *t, const char *name, int legacy, char *buf,
        size_t size)
    # palette handle
    ctypedef struct uc_palette:
        pass
    uc_palette *uc_palette_make(int tag, uc_color *colors, size_t ncolors,
        int intent, int64_t seed)
    void uc_palette_free(uc_palette *p)
    uc_color uc_palette_color_at(uc_palette *p, int i)
    uc_color uc_palette_sample(uc_palette *p, double t)
    uc_color uc_palette_role(uc_palette *p, const char *role)
    int uc_palette_len(uc_palette *p)
    int uc_palette_tag(uc_palette *p)
    int uc_palette_intent(uc_palette *p)

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

# PaletteTag / PaletteIntent ordinals, mirrored from UniColor.h.
PAL_TAG_ORDERED = UC_PAL_TAG_ORDERED
PAL_TAG_UNORDERED = UC_PAL_TAG_UNORDERED
PAL_TAG_SCIENTIFIC = UC_PAL_TAG_SCIENTIFIC
PAL_TAG_TERMINAL = UC_PAL_TAG_TERMINAL
PAL_TAG_CATEGORICAL = UC_PAL_TAG_CATEGORICAL
PAL_TAG_CONTINUOUS = UC_PAL_TAG_CONTINUOUS
PAL_TAG_SEMANTIC = UC_PAL_TAG_SEMANTIC
PAL_INTENT_QUALITATIVE = UC_PAL_INTENT_QUALITATIVE
PAL_INTENT_SEQUENTIAL = UC_PAL_INTENT_SEQUENTIAL
PAL_INTENT_DIVERGING = UC_PAL_INTENT_DIVERGING
PAL_INTENT_UI = UC_PAL_INTENT_UI
PAL_INTENT_SCIENTIFIC = UC_PAL_INTENT_SCIENTIFIC
PAL_INTENT_CATEGORICAL = UC_PAL_INTENT_CATEGORICAL
PAL_INTENT_TERMINAL = UC_PAL_INTENT_TERMINAL


cdef uc_token* _toks(list toks, list keep, size_t* n):
    """Build a C `uc_token` array from a list of `(name, color|None,
    alias|None)` tuples. `keep` holds the encoded bytes alive for the call."""
    n[0] = len(toks)
    if n[0] == 0:
        return NULL
    cdef uc_token* arr = <uc_token*>malloc(n[0] * sizeof(uc_token))
    if arr == NULL:
        raise MemoryError()
    cdef size_t i
    cdef tuple t
    cdef bytes nb, ab
    cdef Color col
    for i in range(n[0]):
        t = <tuple>toks[i]
        nb = (<str>t[0]).encode("utf-8")
        keep.append(nb)
        arr[i].name = nb
        if t[1] is None:
            arr[i].color.tag = UC_TAG_UNKNOWN
        else:
            col = <Color>t[1]
            arr[i].color = col._c
        if t[2] is None:
            arr[i].alias = NULL
        else:
            ab = (<str>t[2]).encode("utf-8")
            keep.append(ab)
            arr[i].alias = ab
    return arr


cdef class Theme:
    """A 3-layer token tree (primitives / semantics / components). Build via
    `Theme.make(prims, sems, comps)` where each layer is a list of
    `(name, color|None, alias|None)` tuples; primitives carry a color, semantics
    and components carry an alias. The handle is freed on GC."""
    cdef uc_theme* _h

    def __dealloc__(self):
        if self._h != NULL:
            uc_theme_free(self._h)

    @classmethod
    def make(cls, list prims, list sems=None, list comps=None):
        if sems is None:
            sems = []
        if comps is None:
            comps = []
        cdef list keep = []
        cdef size_t na, ns, nc
        cdef uc_token* pa = _toks(prims, keep, &na)
        cdef uc_token* sa = _toks(sems, keep, &ns)
        cdef uc_token* ca = _toks(comps, keep, &nc)
        cdef uc_theme* h = uc_theme_make(pa, na, sa, ns, ca, nc)
        if pa != NULL:
            free(pa)
        if sa != NULL:
            free(sa)
        if ca != NULL:
            free(ca)
        if h == NULL:
            raise ValueError(
                "theme build failed (empty name, duplicate role, or bad alias)")
        cdef Theme t = Theme()
        t._h = h
        return t

    def resolve(self, str role):
        cdef Color out = Color()
        out._c = uc_theme_resolve(self._h, role.encode("utf-8"))
        out._check()
        return out

    def has_role(self, str role):
        return bool(uc_theme_has_role(self._h, role.encode("utf-8")))

    @property
    def count(self):
        return uc_theme_count(self._h)

    def export(self, str name, bint legacy=False):
        cdef bytes nb = name.encode("utf-8")
        cdef size_t need = uc_theme_export(self._h, nb, legacy, NULL, 0)
        if need == 0:
            return ""
        cdef char* buf = <char*>malloc(need + 1)
        if buf == NULL:
            raise MemoryError()
        uc_theme_export(self._h, nb, legacy, buf, need + 1)
        cdef str s = buf[:need].decode("utf-8")
        free(buf)
        return s


cdef uc_color* _cols(list colors, size_t* n):
    """Build a C `uc_color` array from a list of Color."""
    n[0] = len(colors)
    if n[0] == 0:
        return NULL
    cdef uc_color* arr = <uc_color*>malloc(n[0] * sizeof(uc_color))
    if arr == NULL:
        raise MemoryError()
    cdef size_t i
    cdef Color c
    for i in range(n[0]):
        c = <Color>colors[i]
        arr[i] = c._c
    return arr


cdef class Palette:
    """An immutable palette. Build via `Palette.make(tag, colors, intent,
    seed=0)`; the handle is freed on GC. `color_at` / `sample` / `role` raise
    ValueError when the C call returns the sentinel (wrong structure or range)."""
    cdef uc_palette* _h

    def __dealloc__(self):
        if self._h != NULL:
            uc_palette_free(self._h)

    @classmethod
    def make(cls, int tag, list colors, int intent, int64_t seed=0):
        cdef size_t n
        cdef uc_color* arr = _cols(colors, &n)
        cdef uc_palette* h = uc_palette_make(tag, arr, n, intent, seed)
        if arr != NULL:
            free(arr)
        if h == NULL:
            raise ValueError(
                "palette build failed (bad tag/intent or empty colors)")
        cdef Palette p = Palette()
        p._h = h
        return p

    def color_at(self, int i):
        cdef Color out = Color()
        out._c = uc_palette_color_at(self._h, i)
        out._check()
        return out

    def sample(self, double t):
        cdef Color out = Color()
        out._c = uc_palette_sample(self._h, t)
        out._check()
        return out

    def role(self, str name):
        cdef Color out = Color()
        out._c = uc_palette_role(self._h, name.encode("utf-8"))
        out._check()
        return out

    def __len__(self):
        return uc_palette_len(self._h)

    @property
    def tag(self):
        return uc_palette_tag(self._h)

    @property
    def intent(self):
        return uc_palette_intent(self._h)


def theme(list prims, list sems=None, list comps=None):
    return Theme.make(prims, sems, comps)


def palette(int tag, list colors, int intent, int64_t seed=0):
    return Palette.make(tag, colors, intent, seed)