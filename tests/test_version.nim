# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import UniColor

suite "version":
  test "version string":
    check UniColorVersion == "0.1.0"
  test "module markers include core":
    check coreModule in ucModuleMarkers
