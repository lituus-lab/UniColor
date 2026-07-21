# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniColor — perceptual color engine. Umbrella module.
import UniColor/core/core
import UniColor/math/math
import UniColor/spaces/spaces
import UniColor/conversion/conversion
import UniColor/contrast/contrast
import UniColor/interpolation/interpolation
import UniColor/palette/palette
import UniColor/accessibility/accessibility
import UniColor/theme/theme
import UniColor/image/image
import UniColor/validation/validation
export core
export math
export spaces
export conversion
export contrast
export interpolation
export palette
export accessibility
export theme
export image
export validation

const
  UniColorVersion* = "0.1.0"
  ucModuleMarkers* = [coreModule, mathModule, spacesModule, conversionModule,
    contrastModule, interpolationModule, paletteModule, accessibilityModule,
    themeModule, imageModule, validationModule]
