// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#include <stdio.h>
#include "UniColor.h"

int main(void) {
  printf("UniColor %s (ABI %d.%d.%d)\n", uc_version(),
         uc_abi_major(), uc_abi_minor(), uc_abi_patch());
  return 0;
}