// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#include <stdio.h>
#include <string.h>
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

int main(void) {
  check_str("version",    uc_version(),    UC_VERSION);
  check_int("abi_major",  uc_abi_major(),  UC_VERSION_MAJOR);
  check_int("abi_minor",  uc_abi_minor(),  UC_VERSION_MINOR);
  check_int("abi_patch",  uc_abi_patch(),  UC_VERSION_PATCH);

  if (failures == 0) { printf("\nAll C ABI tests passed.\n"); return 0; }
  printf("\n%d C ABI test(s) FAILED.\n", failures);
  return 1;
}