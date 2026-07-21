# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# space_tag — SpaceTag (distinct int32) + ABI-stable built-in tags + user ids.
# Lives in core (not spaces) to avoid the core<->spaces cycle: a Color carries
# a SpaceTag. Open/Closed: built-ins are frozen constants (add = minor); user
# spaces receive an id >= TAG_USER_BASE assigned at registration (spaces module).

import std/hashes

type
  SpaceTag* = distinct int32
    ## ABI-stable space identifier. `distinct int32` (open): built-ins are
    ## frozen constants; user spaces receive a dynamic id >= TAG_USER_BASE.

func `==`*(a, b: SpaceTag): bool {.borrow.}
func `<`*(a, b: SpaceTag): bool {.borrow.}
func `<=`*(a, b: SpaceTag): bool {.borrow.}

func id*(t: SpaceTag): int32 {.inline, raises: [].} =
  ## Raw value (ABI-stable / hash / debug).
  int32(t)

func `$`*(t: SpaceTag): string {.raises: [].} =
  "SpaceTag(" & $int32(t) & ")"

func hash*(t: SpaceTag): Hash {.inline, raises: [].} =
  ## Hash consistent with `==` (for tables/keys).
  hash(int32(t))

# Built-in tags — frozen values. Add = minor; remove/recode = major; never
# recode in-place (would break the ABI).
const
  tagUnknown* = SpaceTag(0) # sentinel: unknown/uninitialized space (invalid Color)

  # Encoded + linear RGB.
  tagSrgb* = SpaceTag(1)
  tagSrgbLin* = SpaceTag(2)
  tagP3* = SpaceTag(3)
  tagP3Lin* = SpaceTag(4)
  tagRec2020* = SpaceTag(5)
  tagRec2020Lin* = SpaceTag(6)
  tagA98* = SpaceTag(7)
  tagA98Lin* = SpaceTag(8)
  tagProPhoto* = SpaceTag(9)
  tagProPhotoLin* = SpaceTag(10)

  # CIE.
  tagXyz* = SpaceTag(11)
  tagXyy* = SpaceTag(12)
  tagLab* = SpaceTag(13)   # CIELAB
  tagLch* = SpaceTag(14)   # CIELCH

  # OK.
  tagOklab* = SpaceTag(15)
  tagOklch* = SpaceTag(16) # perceptual

  # Cylindrical derived from RGB.
  tagHsv* = SpaceTag(17)
  tagHsl* = SpaceTag(18)
  tagHwb* = SpaceTag(19)

  # Info loss — CMYK 4-chrom -> ColorX (4-chromatic Color, separate type).
  tagCmyk* = SpaceTag(20)
  tagYcbcr* = SpaceTag(21)

  # HDR / appearance.
  tagIctcp* = SpaceTag(22)
  tagJzazbz* = SpaceTag(23)
  tagCam16* = SpaceTag(24)
  tagCam16Ucs* = SpaceTag(25)
  tagHct* = SpaceTag(26)   # Material

  # Base of user ids (spaces registered at runtime).
  TAG_USER_BASE* = SpaceTag(1000)

func isBuiltin*(t: SpaceTag): bool {.inline, raises: [].} =
  ## A built-in tag (1 .. TAG_USER_BASE-1). Excludes the sentinel and user ids.
  let v = int32(t)
  v > 0 and v < int32(TAG_USER_BASE)

func isUser*(t: SpaceTag): bool {.inline, raises: [].} =
  ## A user-space tag (>= TAG_USER_BASE).
  int32(t) >= int32(TAG_USER_BASE)

func spaceName*(t: SpaceTag): string {.raises: [].} =
  ## Canonical built-in name — diagnostic / `$`. User -> "user", sentinel ->
  ## "unknown".
  case t
  of tagSrgb: "srgb"
  of tagSrgbLin: "srgb-linear"
  of tagP3: "p3"
  of tagP3Lin: "p3-linear"
  of tagRec2020: "rec2020"
  of tagRec2020Lin: "rec2020-linear"
  of tagA98: "a98"
  of tagA98Lin: "a98-linear"
  of tagProPhoto: "prophoto"
  of tagProPhotoLin: "prophoto-linear"
  of tagXyz: "xyz"
  of tagXyy: "xyy"
  of tagLab: "lab"
  of tagLch: "lch"
  of tagOklab: "oklab"
  of tagOklch: "oklch"
  of tagHsv: "hsv"
  of tagHsl: "hsl"
  of tagHwb: "hwb"
  of tagCmyk: "cmyk"
  of tagYcbcr: "ycbcr"
  of tagIctcp: "ictcp"
  of tagJzazbz: "jzazbz"
  of tagCam16: "cam16"
  of tagCam16Ucs: "cam16-ucs"
  of tagHct: "hct"
  of tagUnknown: "unknown"
  else:
    if isUser(t): "user"
    else: "unknown"
