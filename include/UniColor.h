// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#ifndef UC_H
#define UC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UC_VERSION_MAJOR 1
#define UC_VERSION_MINOR 1
#define UC_VERSION_PATCH 0
#define UC_VERSION "1.1.0"

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

/* --- palette handle --------------------------------------------------- */

/* PaletteTag ordinals — which indexing mode is valid (colorAt / sample / role).
 * Frozen (add = minor, remove/recode = major). */
#define UC_PAL_TAG_ORDERED     0
#define UC_PAL_TAG_UNORDERED   1
#define UC_PAL_TAG_SCIENTIFIC  2
#define UC_PAL_TAG_TERMINAL    3
#define UC_PAL_TAG_CATEGORICAL 4
#define UC_PAL_TAG_CONTINUOUS  5
#define UC_PAL_TAG_SEMANTIC    6

/* PaletteIntent ordinals — metadata orthogonal to the structure. */
#define UC_PAL_INTENT_QUALITATIVE  0
#define UC_PAL_INTENT_SEQUENTIAL   1
#define UC_PAL_INTENT_DIVERGING    2
#define UC_PAL_INTENT_UI           3
#define UC_PAL_INTENT_SCIENTIFIC   4
#define UC_PAL_INTENT_CATEGORICAL  5
#define UC_PAL_INTENT_TERMINAL     6

/* Opaque palette handle. The caller owns it; free with uc_palette_free. */
typedef struct uc_palette uc_palette;

/* Build an immutable palette from a C color array. `tag` is a UC_PAL_TAG_*
 * ordinal, `intent` a UC_PAL_INTENT_* ordinal. Returns NULL on an out-of-range
 * tag/intent or empty colors. The caller owns the handle; free with
 * uc_palette_free. (Semantic role maps are not exposed over this ABI.) */
uc_palette *uc_palette_make(int tag, uc_color *colors, size_t ncolors,
    int intent, int64_t seed);

/* Release a palette handle and its color/role storage. NULL is a no-op. */
void uc_palette_free(uc_palette *p);

/* Discrete index for the five discrete structures. Sentinel on a NULL handle,
 * a Continuous/Semantic palette, or an out-of-range index. */
uc_color uc_palette_color_at(uc_palette *p, int i);

/* Ordered-ramp sample at t in [0,1]. Sentinel on a NULL handle, a non-ramp
 * structure, or t outside [0,1]. */
uc_color uc_palette_sample(uc_palette *p, double t);

/* Role access for a Semantic palette. Sentinel on a NULL handle/role, a
 * non-Semantic structure, or an unknown role. */
uc_color uc_palette_role(uc_palette *p, const char *role);

/* Number of colors (0 for NULL). */
int uc_palette_len(uc_palette *p);

/* The structure tag as a UC_PAL_TAG_* ordinal (0 for NULL). */
int uc_palette_tag(uc_palette *p);

/* The intent as a UC_PAL_INTENT_* ordinal (0 for NULL). */
int uc_palette_intent(uc_palette *p);

/* --- import ABI ------------------------------------------------------- */

/* Opaque import-report handle (target + warnings + metadata). The caller owns
 * it; free with uc_import_report_free. */
typedef struct uc_import_report uc_import_report;

/* Import `input` as format `name` and return the reconstructed theme. `strict`
 * non-zero fatal-fails on the first recoverable error. Returns NULL on a NULL
 * input/name, an unknown importer, a kind mismatch, or a parse failure. The
 * caller owns the handle; free with uc_theme_free. */
uc_theme *uc_import_theme(const char *input, const char *name, int strict);

/* Import `input` as format `name` and return the reconstructed palette. Returns
 * NULL on a NULL input/name, an unknown importer, a kind mismatch, or a parse
 * failure. Free with uc_palette_free. */
uc_palette *uc_import_palette(const char *input, const char *name, int strict);

/* Import `input` as format `name` and return the full report. The report owns
 * its target; to obtain the theme/palette use uc_import_theme / uc_import_palette
 * — this handle exposes only the diagnostics. Returns NULL on a NULL input/name
 * or an unknown importer. Free with uc_import_report_free. */
uc_import_report *uc_import_reported(const char *input, const char *name,
    int strict);

/* Release an import-report handle and its target/warnings storage. NULL is a
 * no-op. */
void uc_import_report_free(uc_import_report *r);

/* The format name the importer reconstructed. Measure+fill buffer; 0 on NULL. */
size_t uc_import_format_name(uc_import_report *r, char *buf, size_t size);

/* The schema version read from the source ("" if the format carries none).
 * Measure+fill buffer; 0 on NULL. */
size_t uc_import_schema_version(uc_import_report *r, char *buf, size_t size);

/* Number of recoverable warnings in the report (0 for NULL). */
int uc_import_warning_count(uc_import_report *r);

/* The message of warning `i`. Measure+fill buffer; 0 on a NULL handle or an
 * out-of-range index. */
size_t uc_import_warning(uc_import_report *r, int i, char *buf, size_t size);

/* --- validation ABI --------------------------------------------------- */

/* Severity ordinals (Info = passed, Warning = soft, Error = hard, Fatal unused
 * by the built-in rules). */
#define UC_SEVERITY_INFO    0
#define UC_SEVERITY_WARNING 1
#define UC_SEVERITY_ERROR   2
#define UC_SEVERITY_FATAL   3

/* Opaque validation-report handle. The caller owns it; free with
 * uc_validation_free. */
typedef struct uc_validation uc_validation;

/* Run every registered theme / palette rule and return the report. NULL on a
 * NULL handle. Free with uc_validation_free. */
uc_validation *uc_validate_theme(uc_theme *t);
uc_validation *uc_validate_palette(uc_palette *p);

/* Release a validation-report handle and its rule-result storage. NULL is a
 * no-op. */
void uc_validation_free(uc_validation *r);

/* 0..100 score (0 for NULL). */
int uc_validation_score(uc_validation *r);

/* Worst severity as a UC_SEVERITY_* ordinal (0 for NULL). */
int uc_validation_worst(uc_validation *r);

/* Number of rule results (0 for NULL). */
int uc_validation_rule_count(uc_validation *r);

/* Rule `i`'s name. Measure+fill buffer; 0 on a NULL handle or out-of-range. */
size_t uc_validation_rule_name(uc_validation *r, int i, char *buf, size_t size);

/* Rule `i`'s severity as a UC_SEVERITY_* ordinal (0 on NULL / out-of-range). */
int uc_validation_rule_severity(uc_validation *r, int i);

/* Rule `i`'s measured metric (NaN when the rule has none). NaN on NULL /
 * out-of-range. */
double uc_validation_rule_metric(uc_validation *r, int i);

/* Rule `i`'s pass boundary. NaN on NULL / out-of-range. */
double uc_validation_rule_threshold(uc_validation *r, int i);

/* Rule `i`'s human-readable message. Measure+fill buffer; 0 on a NULL handle
 * or out-of-range. */
size_t uc_validation_rule_message(uc_validation *r, int i, char *buf,
    size_t size);

#ifdef __cplusplus
}
#endif

#endif /* UC_H */