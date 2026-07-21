# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniColor — perceptual color engine. Umbrella module.
import UniColor/core/core
import UniColor/math/math
export core
export math

const
  UniColorVersion* = "0.1.0"
  ucModuleMarkers* = [coreModule, mathModule]
