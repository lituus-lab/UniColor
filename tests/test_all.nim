# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# Aggregator: importing each test module runs its suites at load time, so a
# single `nim c -r` covers everything (used by `nimble test` and coverage).
import std/unittest
import test_version
import test_numerics
import test_result
import test_space_tag
import test_color_error
import test_color
import test_simd
import test_parse_color
import test_batch
import test_math
import test_spaces
import test_conversion
import test_contrast
import test_interpolation
