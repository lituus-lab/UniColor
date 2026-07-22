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

/* A handle proc returns NULL on failure. */
static void check_ptr_null(const char *name, void *got) {
  if (got != NULL) { printf("FAIL %s: expected NULL, got %p\n", name, got); failures++; }
  else printf("ok   %s = NULL\n", name);
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

  /* --- theme handle -------------------------------------------------- */

  uc_color blue = uc_color_oklch(0.65f, 0.18f, 250.0f);

  /* Primitives carry a color and a NULL alias; semantics carry an alias and
   * leave the color unused. Build background + text.primary, then a semantic
   * text.muted aliasing text.primary. */
  uc_token prims[] = {
    { "background",   red,  NULL },
    { "text.primary", blue, NULL }
  };
  uc_token sems[] = {
    { "text.muted", { { 0.0f, 0.0f, 0.0f, 0.0f }, 0 }, "text.primary" }
  };
  uc_theme *th = uc_theme_make(prims, 2, sems, 1, NULL, 0);
  if (th == NULL) { printf("FAIL theme_make: NULL\n"); failures++; }
  else printf("ok   theme_make\n");

  check_int("theme count", uc_theme_count(th), 3);
  check_int("theme has text.muted", uc_theme_has_role(th, "text.muted"), 1);
  check_int("theme missing role", uc_theme_has_role(th, "nope"), 0);

  /* text.muted aliases text.primary (blue) -> resolves to blue's tag. */
  uc_color muted = uc_theme_resolve(th, "text.muted");
  check_color_ok("theme resolve text.muted", muted);
  check_int("theme resolve text.muted tag", uc_color_tag(muted), UC_TAG_OKLCH);
  check_color_sentinel("theme resolve missing", uc_theme_resolve(th, "nope"));

  /* Export to CSS: :root block with the two primitive vars. */
  { char buf[256];
    size_t n = uc_theme_export(th, "css", 0, buf, sizeof buf);
    if (n == 0 || strstr(buf, "--background") == NULL) {
      printf("FAIL theme_export css: \"%s\" (len %zu)\n", buf, n); failures++;
    } else printf("ok   theme_export css = \"%s\" (len %zu)\n", buf, n); }
  check_int("theme_export unknown format", (int)uc_theme_export(th, "nopefmt", 0, NULL, 0), 0);

  uc_theme_free(th);
  /* free(NULL) is a no-op (must not crash). */
  uc_theme_free(NULL);

  /* --- palette handle ------------------------------------------------ */

  /* Ordered 3-color ramp: colorAt indexes, sample blends, len/tag/intent. */
  uc_color ramp[] = { red, blue, white };
  uc_palette *pal = uc_palette_make(UC_PAL_TAG_ORDERED, ramp, 3,
      UC_PAL_INTENT_SEQUENTIAL, 0);
  if (pal == NULL) { printf("FAIL palette_make: NULL\n"); failures++; }
  else printf("ok   palette_make\n");
  check_int("palette len", uc_palette_len(pal), 3);
  check_int("palette tag", uc_palette_tag(pal), UC_PAL_TAG_ORDERED);
  check_int("palette intent", uc_palette_intent(pal), UC_PAL_INTENT_SEQUENTIAL);
  check_color_ok("palette color_at 0", uc_palette_color_at(pal, 0));
  check_int("palette color_at 0 tag", uc_color_tag(uc_palette_color_at(pal, 0)),
      UC_TAG_SRGB);
  check_color_sentinel("palette color_at oob", uc_palette_color_at(pal, 9));
  { uc_color mid = uc_palette_sample(pal, 0.5);
    check_color_ok("palette sample 0.5", mid); }
  check_color_sentinel("palette sample oob", uc_palette_sample(pal, 2.0));

  /* Rejected: empty colors -> NULL; bad tag -> NULL. */
  check_ptr_null("palette empty", uc_palette_make(UC_PAL_TAG_ORDERED, NULL, 0,
      UC_PAL_INTENT_SEQUENTIAL, 0));
  check_ptr_null("palette bad tag", uc_palette_make(999, ramp, 3,
      UC_PAL_INTENT_SEQUENTIAL, 0));

  uc_palette_free(pal);
  uc_palette_free(NULL);

  /* --- import ABI ---------------------------------------------------- */

  /* Round-trip: export a theme to JSON, import it back, resolve a role. Guard
   * src (theme_make can fail) and only import a payload that export produced —
   * json is zero-init so a skipped/failed export never reads uninit. */
  uc_token iprims[] = {
    { "background",   red,  NULL },
    { "text.primary", blue, NULL }
  };
  uc_theme *src = uc_theme_make(iprims, 2, NULL, 0, NULL, 0);
  char json[1024] = {0};
  if (src == NULL) {
    printf("FAIL import src theme_make: NULL\n"); failures++;
  } else {
    size_t jn = uc_theme_export(src, "json", 0, json, sizeof json);
    if (jn == 0 || strstr(json, "\"background\"") == NULL) {
      printf("FAIL export json: \"%s\"\n", json); failures++;
    } else {
      printf("ok   export json (len %zu)\n", jn);

      uc_theme *imp = uc_import_theme(json, "json", 0);
      if (imp == NULL) { printf("FAIL import_theme: NULL\n"); failures++; }
      else {
        check_color_ok("import resolve background", uc_theme_resolve(imp, "background"));
        uc_theme_free(imp);
      }

      /* Reported handle: format name + warning count, then free. */
      uc_import_report *rep = uc_import_reported(json, "json", 0);
      if (rep == NULL) { printf("FAIL import_reported: NULL\n"); failures++; }
      else {
        { char fn[32];
          uc_import_format_name(rep, fn, sizeof fn);
          check_str("import format_name", fn, "json"); }
        check_int("import warning_count", uc_import_warning_count(rep), 0);
        uc_import_report_free(rep);
      }
    }
    uc_theme_free(src);
  }
  uc_import_report_free(NULL); /* no-op. */

  /* Failures: NULL input, unknown importer (json is a valid empty string if
   * export was skipped, so these read no uninit memory). */
  check_ptr_null("import NULL input", uc_import_theme(NULL, "json", 0));
  check_ptr_null("import unknown fmt", uc_import_theme(json, "nopefmt", 0));

  /* --- validation ABI ----------------------------------------------- */

  /* Passing theme: black text on white surface meets WCAG AA. */
  uc_token vgood[] = {
    { "surface",      white, NULL },
    { "text.primary", black, NULL }
  };
  uc_theme *vt = uc_theme_make(vgood, 2, NULL, 0, NULL, 0);
  if (vt == NULL) { printf("FAIL validate pass theme_make: NULL\n"); failures++; }
  else {
    uc_validation *vr = uc_validate_theme(vt);
    if (vr == NULL) { printf("FAIL validate_theme: NULL\n"); failures++; }
    else {
      check_int("validate score (pass)", uc_validation_score(vr), 100);
      check_int("validate worst (pass)", uc_validation_worst(vr), UC_SEVERITY_INFO);
      check_int("validate rule_count", uc_validation_rule_count(vr), 1);
      { char rname[64];
        uc_validation_rule_name(vr, 0, rname, sizeof rname);
        check_str("validate rule name", rname, "contrast-text-primary"); }
      check_int("validate rule severity (pass)",
          uc_validation_rule_severity(vr, 0), UC_SEVERITY_INFO);
      check_dbl_tol("validate rule threshold",
          uc_validation_rule_threshold(vr, 0), 4.5, 1e-6);
      { double m = uc_validation_rule_metric(vr, 0);
        if (isnan(m) || m < 4.5) { printf("FAIL validate rule metric: %g\n", m); failures++; }
        else printf("ok   validate rule metric = %g\n", m); }
      { char msg[256];
        size_t mn = uc_validation_rule_message(vr, 0, msg, sizeof msg);
        if (mn == 0) { printf("FAIL validate rule message: empty\n"); failures++; }
        else printf("ok   validate rule message (len %zu)\n", mn); }
      /* Out-of-range rule index: severity 0, metric NaN. */
      check_int("validate rule oob severity", uc_validation_rule_severity(vr, 9), 0);
      check_dbl("validate rule oob metric", uc_validation_rule_metric(vr, 9), NAN);
      uc_validation_free(vr);
    }
    uc_theme_free(vt);
  }

  /* Failing theme: white text on white surface fails AA (score 90, Error). */
  uc_token vbad[] = {
    { "surface",      white, NULL },
    { "text.primary", white, NULL }
  };
  uc_theme *vtf = uc_theme_make(vbad, 2, NULL, 0, NULL, 0);
  if (vtf == NULL) { printf("FAIL validate fail theme_make: NULL\n"); failures++; }
  else {
    uc_validation *vrf = uc_validate_theme(vtf);
    if (vrf == NULL) { printf("FAIL validate_theme (fail): NULL\n"); failures++; }
    else {
      check_int("validate score (fail)", uc_validation_score(vrf), 90);
      check_int("validate worst (fail)", uc_validation_worst(vrf), UC_SEVERITY_ERROR);
      check_int("validate rule severity (fail)",
          uc_validation_rule_severity(vrf, 0), UC_SEVERITY_ERROR);
      uc_validation_free(vrf);
    }
    uc_theme_free(vtf);
  }

  uc_validation_free(NULL); /* no-op. */

  if (failures == 0) { printf("\nAll C ABI tests passed.\n"); return 0; }
  printf("\n%d C ABI test(s) FAILED.\n", failures);
  return 1;
}