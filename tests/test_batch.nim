# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import UniColor

suite "BatchOpts defaults":
  test "defaultBatchOpts is the serial path":
    let opts = defaultBatchOpts()
    check opts.parallel == false
    check opts.threads == 0
