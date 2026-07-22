// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#ifndef UC_H
#define UC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UC_VERSION_MAJOR 0
#define UC_VERSION_MINOR 1
#define UC_VERSION_PATCH 0
#define UC_VERSION "0.1.0"

#define UC_VERSION_AT_LEAST(ma, mi, pa) \
  ((UC_VERSION_MAJOR > (ma)) || \
   (UC_VERSION_MAJOR == (ma) && UC_VERSION_MINOR > (mi)) || \
   (UC_VERSION_MAJOR == (ma) && UC_VERSION_MINOR == (mi) && \
    UC_VERSION_PATCH >= (pa)))

/* SpaceTag ordinals — frozen (add = minor, remove/recode = major). The sentinel
 * UC_TAG_UNKNOWN (0) is the failure marker returned by color-producing procs;
 * the validating constructor never emits it, so a non-zero tag is a real color. */
#define UC_TAG_UNKNOWN     0
#define UC_TAG_SRGB        1
#define UC_TAG_SRGB_LIN    2
#define UC_TAG_P3          3
#define UC_TAG_P3_LIN      4
#define UC_TAG_REC2020     5
#define UC_TAG_REC2020_LIN 6
#define UC_TAG_A98         7
#define UC_TAG_A98_LIN     8
#define UC_TAG_PROPHOTO    9
#define UC_TAG_PROPHOTO_LIN 10
#define UC_TAG_XYZ         11
#define UC_TAG_XYY         12
#define UC_TAG_LAB         13
#define UC_TAG_LCH         14
#define UC_TAG_OKLAB       15
#define UC_TAG_OKLCH       16
#define UC_TAG_HSV         17
#define UC_TAG_HSL         18
#define UC_TAG_HWB         19
#define UC_TAG_CMYK        20
#define UC_TAG_YCBCR       21
#define UC_TAG_ICTCP       22
#define UC_TAG_JZAZBZ      23
#define UC_TAG_CAM16       24
#define UC_TAG_CAM16_UCS   25
#define UC_TAG_HCT         26
#define UC_TAG_USER_BASE   1000

/* Color: 4 float32 components (3 chromatic + alpha) + a SpaceTag int32. 20
 * bytes, POD, passed and returned by value. A color with tag == UC_TAG_UNKNOWN
 * is the failure sentinel. Never raises; single-threaded, reentrant. */
typedef struct uc_color {
  float    comps[4];
  int32_t  tag;
} uc_color;

/* Run Nim module initializers — populates the contrast / import / export /
 * spaces / validation registries. Call once before any registry-based proc
 * (uc_contrast, uc_distance, uc_convert, uc_gamut_map, import/export/validate). */
void uc_init(void);

/* Static version string; do not free. */
const char *uc_version(void);

/* ABI numbers, matching the UC_VERSION_* macros. */
int uc_abi_major(void);
int uc_abi_minor(void);
int uc_abi_patch(void);

/* Validating constructor: returns a sentinel (tag == UC_TAG_UNKNOWN) on an
 * unknown space, alpha outside [0,1], or a NaN/Inf component at bounds.
 * Out-of-gamut components are preserved. */
uc_color uc_color_make(int tag, float c0, float c1, float c2, float alpha);

/* Opaque sRGB / OKLCH colors (alpha 1). Sentinel on NaN/Inf components. */
uc_color uc_color_srgb(float r, float g, float b);
uc_color uc_color_oklch(float l, float c, float h);

/* Parse a CSS Color 4 string (hex / rgb() / oklch()). Sentinel on NULL, a
 * malformed string, or a deferred form (oklab/lab/lch/color/hsl/hwb). */
uc_color uc_parse(const char *s);

/* Format a color as CSS: "#rrggbb[aa]" when legacy != 0, else "oklch(L C h[/a])".
 * Writes up to size-1 bytes + NUL into buf and returns the required length
 * (excl. NUL). If buf is NULL or size is 0, returns the required length without
 * writing. A sentinel c formats as the empty string (length 0). */
size_t uc_format_css(uc_color c, int legacy, char *buf, size_t size);

/* Write the 3 chromatic components (zeros for the sentinel). Null c0/c1/c2 is
 * undefined. */
void uc_color_components(uc_color c, float *c0, float *c1, float *c2);

/* Alpha straight [0,1] (0 for the sentinel). */
float uc_color_alpha(uc_color c);

/* The SpaceTag as a raw int32 (UC_TAG_UNKNOWN for the sentinel). */
int uc_color_tag(uc_color c);

/* Gamut-map / convert c into the target space. Sentinel on a sentinel input or
 * an unknown target. */
uc_color uc_gamut_map(uc_color c, int target);
uc_color uc_convert(uc_color c, int target);

/* WCAG 2.2 contrast ratio (default metric). NaN on a sentinel operand or a
 * metric failure. */
double uc_contrast(uc_color fg, uc_color bg);

/* Contrast under a named metric ("wcag22" / "apca" / "bridgepca"). NaN on a
 * sentinel operand, a NULL metric, an unknown metric, or a failure. */
double uc_contrast_metric(uc_color fg, uc_color bg, const char *metric);

/* Perceptual distance under a named metric (deltaE76/94/2000/cmc/ok/itp/jz/
 * cam16Ucs). NaN on a sentinel operand, a NULL metric, an unknown metric, or a
 * failure. */
double uc_distance(uc_color a, uc_color b, const char *metric);

/* --- theme handle ----------------------------------------------------- */

/* Opaque theme handle (a 3-layer token tree). The caller owns it; free with
 * uc_theme_free. */
typedef struct uc_theme uc_theme;

/* A theme-tree node as the host passes it. `name` is the role; a primitive
 * carries its `color` and leaves `alias` NULL, a semantic / component carries
 * its `alias` target and leaves `color` unused. Field order and types match
 * the Nim UcToken so an array of `uc_token` can be read in place. */
typedef struct uc_token {
  const char *name;
  uc_color    color;
  const char *alias;
} uc_token;

/* Build an immutable 3-layer token tree from parallel C token arrays. Returns
 * NULL on a validation error (empty name, duplicate role, bad alias). The
 * caller owns the handle; free it with uc_theme_free. */
uc_theme *uc_theme_make(uc_token *prim, size_t nprim, uc_token *sem,
    size_t nsem, uc_token *comp, size_t ncomp);

/* Release a theme handle and its token-tree storage. NULL is a no-op. */
void uc_theme_free(uc_theme *t);

/* Resolve a role to a color (component -> semantic -> primitive). Returns the
 * sentinel on a NULL handle / role, an undefined role, a dangling alias, or a
 * cycle. */
uc_color uc_theme_resolve(uc_theme *t, const char *role);

/* Total tokens across the three layers (0 for NULL). */
int uc_theme_count(uc_theme *t);

/* 1 if `role` is defined in any layer, else 0 (0 for NULL handle / role). */
int uc_theme_has_role(uc_theme *t, const char *role);

/* Render the theme to a registered format string ("css", "json", "tailwind",
 * ...). `legacy` non-zero emits sRGB legacy hex instead of OKLCH. Writes up to
 * size-1 bytes + NUL into buf and returns the required length (excl. NUL);
 * measure-only when buf is NULL / size is 0; 0 on a NULL handle / name or an
 * unknown format. */
size_t uc_theme_export(uc_theme *t, const char *name, int legacy, char *buf,
    size_t size);

#ifdef __cplusplus
}
#endif

#endif /* UC_H */