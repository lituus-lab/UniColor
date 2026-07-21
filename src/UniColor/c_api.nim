# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## C ABI for UniColor. Built --app:staticlib/--app:lib --noMain --mm:arc -d:release.
## Keep in sync with include/UniColor.h; tests/c links the header against this lib.
## Never raises; every entry point is reentrant and single-threaded.
import ../UniColor

const
  AbiMajor = 0
  AbiMinor = 1
  AbiPatch = 0

# Unmangled C symbols, C calling convention, exported from the shared lib.
{.push exportc, cdecl, dynlib.}

proc uc_version(): cstring =
  ## Static version string; do not free.
  UniColorVersion.cstring

proc uc_abi_major(): cint = AbiMajor.cint
proc uc_abi_minor(): cint = AbiMinor.cint
proc uc_abi_patch(): cint = AbiPatch.cint

{.pop.}
