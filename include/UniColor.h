// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#ifndef UC_H
#define UC_H

#include <stddef.h>

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

/* Static version string; do not free. */
const char *uc_version(void);

/* ABI numbers, matching the UC_VERSION_* macros. */
int uc_abi_major(void);
int uc_abi_minor(void);
int uc_abi_patch(void);

#ifdef __cplusplus
}
#endif

#endif /* UC_H */