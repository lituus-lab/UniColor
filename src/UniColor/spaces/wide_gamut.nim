# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# wide_gamut — Display P3, Rec2020, A98, ProPhoto RGB descriptors + their
# linear variants. Each encoded space carries its primaries->XYZ matrix (frozen,
# standard IEC/ITU/ISO values) and a transfer kind; the conversion module
# applies the transfer. P3 shares the sRGB 2.4 piecewise (tkSrgb); Rec2020 uses
# the BT.2020 OETF (tkRec2020, 4.5 linear / 0.45 power); A98 is simple gamma 2.2
# (tkGamma); ProPhoto is 1.8 piecewise (tkProPhoto) and anchored at D50, so
# conversion must adapt D50<->D65 at the hub boundary. Linear variants reuse
# the same primaries matrix with no transfer and an unbounded range. Matrices
# verified against colour-science / Lindbloom.

import UniColor/math/matrices
import UniColor/math/whitepoint
import UniColor/core/space_tag
import UniColor/spaces/descriptor
import UniColor/spaces/registry

const
  p3ToXyz: Mat3 = [[0.4865709, 0.2656677, 0.1982173],
                   [0.2289746, 0.6917385, 0.0792869],
                   [0.0000000, 0.0451134, 1.0439444]]

  rec2020ToXyz: Mat3 = [[0.6369580, 0.1446169, 0.1688810],
                        [0.2627002, 0.6779981, 0.0593017],
                        [0.0000000, 0.0280727, 1.0609253]]

  a98ToXyz: Mat3 = [[0.5766691, 0.1855582, 0.1882286],
                    [0.2973439, 0.6273539, 0.0752913],
                    [0.0270312, 0.0706872, 0.9913374]]

  proPhotoToXyz: Mat3 = [[0.7976742, 0.1351916, 0.0316382],
                         [0.2880402, 0.7118741, 0.0000922],
                         [0.0000000, 0.0000000, 0.8252100]]

func p3Descriptor*(): SpaceDescriptor =
  ## Display P3 (Apple), D65, sRGB 2.4 transfer, wider gamut than sRGB.
  makeRgbDescriptor("p3", tagP3, famRgbEncoded, wpD65, tkSrgb, 0.0, p3ToXyz, true)

func p3LinearDescriptor*(): SpaceDescriptor =
  ## Linear Display P3: same primaries, no transfer, unbounded.
  makeRgbDescriptor("p3-linear", tagP3Lin, famRgbLinear, wpD65, tkNone, 0.0,
      p3ToXyz, true)

func rec2020Descriptor*(): SpaceDescriptor =
  ## Rec2020 (BT.2020), D65. Transfer is the BT.2020 OETF (4.5 linear / 0.45
  ## power); the 12-bit linear variant is not exposed as a separate descriptor.
  makeRgbDescriptor("rec2020", tagRec2020, famRgbEncoded, wpD65, tkRec2020, 0.0,
      rec2020ToXyz, true)

func rec2020LinearDescriptor*(): SpaceDescriptor =
  makeRgbDescriptor("rec2020-linear", tagRec2020Lin, famRgbLinear, wpD65,
      tkNone, 0.0, rec2020ToXyz, true)

func a98Descriptor*(): SpaceDescriptor =
  ## Adobe RGB (1998), D65, simple gamma 2.2.
  makeRgbDescriptor("a98", tagA98, famRgbEncoded, wpD65, tkGamma, 2.2, a98ToXyz,
      true)

func a98LinearDescriptor*(): SpaceDescriptor =
  makeRgbDescriptor("a98-linear", tagA98Lin, famRgbLinear, wpD65, tkNone, 0.0,
      a98ToXyz, true)

func proPhotoDescriptor*(): SpaceDescriptor =
  ## ProPhoto RGB (ROMM), D50, 1.8 piecewise. Primaries include imaginary
  ## points, so XYZ can fall outside the spectral locus and is preserved. The
  ## EOTF linear-toe threshold is 1/32 (16/512) per ISO 22028-2.
  makeRgbDescriptor("prophoto", tagProPhoto, famRgbEncoded, wpD50, tkProPhoto,
      1.8, proPhotoToXyz, true)

func proPhotoLinearDescriptor*(): SpaceDescriptor =
  makeRgbDescriptor("prophoto-linear", tagProPhotoLin, famRgbLinear, wpD50,
      tkNone, 0.0, proPhotoToXyz, true)

discard registerSpace(p3Descriptor())
discard registerSpace(p3LinearDescriptor())
discard registerSpace(rec2020Descriptor())
discard registerSpace(rec2020LinearDescriptor())
discard registerSpace(a98Descriptor())
discard registerSpace(a98LinearDescriptor())
discard registerSpace(proPhotoDescriptor())
discard registerSpace(proPhotoLinearDescriptor())
