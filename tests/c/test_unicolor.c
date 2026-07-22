// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stddef.h>
#include "UniColor.h"

static int failures = 0;

static void check_str(const char *name, const char *got, const char *want) {
  if (strcmp(got, want) != 0) { printf("FAIL %s: got \"%s\" want \"%s\"\n", name, got, want); failures++; }
  else printf("ok   %s = \"%s\"\n", name, got);
}

static void check_int(const char *name, int got, int want) {
  if (got != want) { printf("FAIL %s: got %d want %d\n", name, got, want); failures++; }
  else printf("ok   %s = %d\n", name, got);
}

/* Exact double compare, NaN/Inf-aware (a NaN want matches a NaN got, signed Inf
 * matches by sign). */
static void check_dbl(const char *name, double got, double want) {
  int ok = (isnan(got) && isnan(want))
        || (isinf(got) && isinf(want) && (got > 0) == (want > 0))
        || (got == want);
  if (!ok) { printf("FAIL %s: got %g want %g\n", name, got, want); failures++; }
  else printf("ok   %s = %g\n", name, got);
}

/* Approximate double compare within an absolute tolerance. */
static void check_dbl_tol(const char *name, double got, double want, double tol) {
  if (fabs(got - want) > tol) { printf("FAIL %s: got %g want %g (tol %g)\n", name, got, want, tol); failures++; }
  else printf("ok   %s = %g (want %g)\n", name, got, want);
}

/* A uc_color is the failure sentinel when its tag is UC_TAG_UNKNOWN. */
static void check_color_ok(const char *name, uc_color c) {
  if (c.tag == UC_TAG_UNKNOWN) { printf("FAIL %s: got sentinel\n", name); failures++; }
  else printf("ok   %s tag=%d\n", name, c.tag);
}
static void check_color_sentinel(const char *name, uc_color c) {
  if (c.tag != UC_TAG_UNKNOWN) { printf("FAIL %s: expected sentinel, got tag %d\n", name, c.tag); failures++; }
  else printf("ok   %s = sentinel\n", name);
}

int main(void) {
  uc_init(); /* populate the contrast / spaces / import / export registries. */

  check_str("version",    uc_version(),    UC_VERSION);
  check_int("abi_major",  uc_abi_major(),  UC_VERSION_MAJOR);
  check_int("abi_minor",  uc_abi_minor(),  UC_VERSION_MINOR);
  check_int("abi_patch",  uc_abi_patch(),  UC_VERSION_PATCH);

  /* --- color core --------------------------------------------------- */

  /* Construct sRGB / OKLCH: tag set, components round-trip, alpha 1. */
  uc_color red = uc_color_srgb(1.0f, 0.0f, 0.0f);
  check_color_ok("srgb red", red);
  check_int("srgb red tag", uc_color_tag(red), UC_TAG_SRGB);
  { float c0, c1, c2;
    uc_color_components(red, &c0, &c1, &c2);
    check_dbl_tol("srgb red c0", c0, 1.0, 1e-6);
    check_dbl_tol("srgb red c1", c1, 0.0, 1e-6);
    check_dbl_tol("srgb red c2", c2, 0.0, 1e-6); }
  check_dbl("srgb red alpha", uc_color_alpha(red), 1.0);

  uc_color ok = uc_color_oklch(0.65f, 0.18f, 250.0f);
  check_color_ok("oklch", ok);
  check_int("oklch tag", uc_color_tag(ok), UC_TAG_OKLCH);

  /* Rejected constructors return the sentinel. */
  check_color_sentinel("make bad alpha", uc_color_make(UC_TAG_SRGB, 0.5f, 0.5f, 0.5f, 2.0f));
  check_color_sentinel("make unknown tag", uc_color_make(UC_TAG_UNKNOWN, 0.5f, 0.5f, 0.5f, 1.0f));
  check_color_sentinel("make NaN comp", uc_color_make(UC_TAG_SRGB, NAN, 0.0f, 0.0f, 1.0f));

  /* Parse: hex -> sRGB, oklch -> OKLCH, malformed/NULL -> sentinel. */
  uc_color ph = uc_parse("#ff0000");
  check_color_ok("parse #ff0000", ph);
  check_int("parse #ff0000 tag", uc_color_tag(ph), UC_TAG_SRGB);
  { float c0, c1, c2;
    uc_color_components(ph, &c0, &c1, &c2);
    check_dbl_tol("parse #ff0000 c0", c0, 1.0, 1e-6);
    check_dbl_tol("parse #ff0000 c1", c1, 0.0, 1e-6);
    check_dbl_tol("parse #ff0000 c2", c2, 0.0, 1e-6); }
  check_color_ok("parse oklch", uc_parse("oklch(0.65 0.18 250)"));
  check_color_sentinel("parse bogus", uc_parse("notacolor"));
  check_color_sentinel("parse NULL", uc_parse(NULL));

  /* Format: legacy sRGB hex, OKLCH form, measure-only, sentinel -> 0. */
  { char buf[64];
    size_t n = uc_format_css(red, 1, buf, sizeof buf);
    check_int("format srgb hex len", (int)n, 7);
    check_str("format srgb hex", buf, "#ff0000"); }
  { char buf[64];
    size_t n = uc_format_css(ok, 0, buf, sizeof buf);
    if (n == 0 || strncmp(buf, "oklch(", 6) != 0) { printf("FAIL format oklch: \"%s\"\n", buf); failures++; }
    else printf("ok   format oklch = \"%s\" (len %zu)\n", buf, n); }
  { size_t m = uc_format_css(red, 1, NULL, 0);
    check_int("format measure-only", (int)m, 7); }
  check_int("format sentinel len", (int)uc_format_css(uc_parse("notacolor"), 1, NULL, 0), 0);

  /* Convert sRGB -> OKLCH changes the tag; gamut-map OKLCH -> sRGB lands sRGB. */
  uc_color redOklch = uc_convert(red, UC_TAG_OKLCH);
  check_color_ok("convert red->oklch", redOklch);
  check_int("convert red->oklch tag", uc_color_tag(redOklch), UC_TAG_OKLCH);
  uc_color okSrgb = uc_gamut_map(ok, UC_TAG_SRGB);
  check_color_ok("gamut_map oklch->srgb", okSrgb);
  check_int("gamut_map oklch->srgb tag", uc_color_tag(okSrgb), UC_TAG_SRGB);
  check_color_sentinel("convert unknown target", uc_convert(red, 9999));

  /* Contrast: black/white = 21 (WCAG 2.2); NaN on sentinel operand or bad metric. */
  uc_color black = uc_color_srgb(0.0f, 0.0f, 0.0f);
  uc_color white = uc_color_srgb(1.0f, 1.0f, 1.0f);
  check_dbl_tol("contrast black/white", uc_contrast(black, white), 21.0, 0.01);
  check_dbl("contrast sentinel", uc_contrast(uc_parse("notacolor"), white), NAN);
  check_dbl("contrast bad metric", uc_contrast_metric(black, white, "bogus"), NAN);
  { double apca = uc_contrast_metric(black, white, "apca");
    if (isnan(apca)) { printf("FAIL contrast apca: got NaN\n"); failures++; }
    else printf("ok   contrast apca = %g\n", apca); }

  /* Distance: positive between distinct colors, NaN on bad metric, 0 identical. */
  { double d = uc_distance(red, white, "deltaE_ok");
    if (isnan(d) || d < 0.0) { printf("FAIL distance red/white: got %g\n", d); failures++; }
    else printf("ok   distance red/white = %g\n", d); }
  check_dbl("distance bad metric", uc_distance(red, white, "bogus"), NAN);
  check_dbl("distance identical", uc_distance(red, red, "deltaE_ok"), 0.0);

  if (failures == 0) { printf("\nAll C ABI tests passed.\n"); return 0; }
  printf("\n%d C ABI test(s) FAILED.\n", failures);
  return 1;
}