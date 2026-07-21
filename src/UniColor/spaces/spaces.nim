# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# spaces — registry + descriptors of color spaces. DATA only (data-driven):
# conversion logic lives in `conversion`. Each space submodule registers its
# descriptor at load time (import side effect); importing `spaces/spaces`
# materializes all registered spaces, then seals the registry read-only.
import UniColor/spaces/descriptor
import UniColor/spaces/registry
import UniColor/spaces/srgb
import UniColor/spaces/linear
import UniColor/spaces/xyz
import UniColor/spaces/xyy
import UniColor/spaces/lab
import UniColor/spaces/lch
import UniColor/spaces/oklab
import UniColor/spaces/oklch
import UniColor/spaces/wide_gamut
import UniColor/spaces/hsv_hsl_hwb
import UniColor/spaces/cmyk
import UniColor/spaces/ycbcr
import UniColor/spaces/hdr
import UniColor/spaces/cam16
import UniColor/spaces/hct
# All built-ins registered above (import side effects); lock the registry.
sealSpaces()
export descriptor
export registry
export srgb
export linear
export xyz
export xyy
export lab
export lch
export oklab
export oklch
export wide_gamut
export hsv_hsl_hwb
export cmyk
export ycbcr
export hdr
export cam16
export hct

const spacesModule* = "0.1.0"
