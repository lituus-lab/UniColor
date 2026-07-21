# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# metrics — a11y contrast consumer layer. Adds the role/size THRESHOLD layer
# on top of the dispatched `contrast(fg, bg, metric)`:
#   - WCAG 2.2 role thresholds: role-based, AA default / AAA if `strict`.
#   - APCA/BridgePCA size thresholds: size-based, reusing the core constants.
# No cross-metric comparison: WCAG role thresholds apply to the unsigned-ratio
# metric (wcag22); APCA/BridgePCA size thresholds apply to the signed-Lc
# metrics (apca, bridgepca). `contrastForRole` rejects signed-Lc metrics (a
# role is not a size); `contrastForSize` rejects wcag22 (a size is not a ratio).
# All procs pure: no Color mutation, deterministic, no side effects.
import UniColor/core/core
import UniColor/contrast/contrast # `contrast` + Wcag*/Apca*/Bpca* constants.

type
  RoleKind* = enum
    ## WCAG contrast role. Text roles use 4.5:1 AA (3.0 large), non-text roles
    ## use 3.0, disabled is exempt. `strict` upgrades text roles to AAA.
    roleTextPrimary
    roleTextLarge
    roleTextSecondary
    roleTextMuted
    roleTextDisabled
    roleLink
    roleLinkVisited
    roleFocus
    roleBorder
    roleOutline
    roleSyntax
    roleStatusIcon
    roleStatusLabel
    roleUiComponent

  ApcaSize* = enum
    ## APCA/BridgePCA text/element size class. APCA thresholds are size-based
    ## (not role-based) because APCA Lc is perceptual and size-dependent;
    ## BridgePCA shares the same scale.
    sizeFine
    sizeNormal
    sizeLarge
    sizeNonText
    sizeSymbols

  ContrastVerdict* = object
    ## Result of a role/size contrast check. `value` is in the metric's native
    ## unit (ratio for wcag22, signed Lc for apca/bridgepca); `pass` is
    ## `abs(value) >= threshold` (abs is a no-op for the unsigned ratio and
    ## corrects the sign for APCA Lc).
    pass*: bool
    value*: float64
    threshold*: float64
    metric*: string

# WCAG role threshold. Pure table lookup; `strict` forces AAA for text roles
# (non-text roles and disabled have no AAA tier — unchanged). Disabled is
# exempt (0.0, always passes).
proc wcagRoleThreshold*(role: RoleKind, strict: bool): float64 {.raises: [].} =
  case role
  of roleTextDisabled:
    0.0 # exempt — disabled state, no minimum.
  of roleTextPrimary, roleTextSecondary, roleLink, roleLinkVisited, roleSyntax,
      roleStatusLabel:
    if strict: WcagAaaNormal else: WcagAaNormal # 7.0 / 4.5
  of roleTextLarge:
    if strict: WcagAaaLarge else: WcagAaLarge # 4.5 / 3.0
  of roleTextMuted:
    3.0 # attenuated text — 3.0 minimum; no AAA tier for muted.
  of roleFocus, roleBorder, roleOutline, roleStatusIcon, roleUiComponent:
    WcagNonText # 3.0 — non-text / UI components; no AAA tier.

# APCA/BridgePCA size threshold (reuses the core constants — single source of
# truth). `metric` must be a signed-Lc metric (apca/bridgepca); wcag22 is
# rejected with UnknownMetric — no cross-metric. APCA and BridgePCA share the
# same thresholds today; kept separate so BridgePCA can diverge if it ever does.
proc apcaSizeThreshold*(size: ApcaSize, metric: string): Result[float64,
    ColorError] {.raises: [].} =
  case metric
  of "apca":
    case size
    of sizeFine: ok[float64, ColorError](ApcaFine)
    of sizeNormal: ok[float64, ColorError](ApcaNormal)
    of sizeLarge: ok[float64, ColorError](ApcaLarge)
    of sizeNonText: ok[float64, ColorError](ApcaNonText)
    of sizeSymbols: ok[float64, ColorError](ApcaSymbols)
  of "bridgepca":
    case size
    of sizeFine: ok[float64, ColorError](BpcaFine)
    of sizeNormal: ok[float64, ColorError](BpcaNormal)
    of sizeLarge: ok[float64, ColorError](BpcaLarge)
    of sizeNonText: ok[float64, ColorError](BpcaNonText)
    of sizeSymbols: ok[float64, ColorError](BpcaSymbols)
  else:
    err[float64, ColorError](colorError(UnknownMetric,
        "not a signed-Lc size metric: " & metric, "apcaSizeThreshold"))

# Verdict builder — measures the contrast via the core dispatcher, compares
# |value| to the threshold. Shared by the role (WCAG) and size (APCA/BridgePCA)
# entry points so the pass rule and error handling are defined once.
proc verdict(fg, bg: Color, metric: string, threshold: float64): Result[
    ContrastVerdict, ColorError] {.raises: [].} =
  let cR = contrast(fg, bg, metric) # delegate to the core registry dispatcher.
  if cR.isErr:
    return err[ContrastVerdict, ColorError](cR.error)
  let value = cR.get
  ok[ContrastVerdict, ColorError](ContrastVerdict(
      pass: abs(value) >= threshold, value: value, threshold: threshold,
          metric: metric))

proc contrastForRole*(fg, bg: Color, role: RoleKind, metric = "wcag22",
    strict = false): Result[ContrastVerdict, ColorError] {.raises: [].} =
  ## WCAG role-aware contrast verdict. The role defines the threshold (AAA if
  ## `strict`); `metric` must be the unsigned-ratio `wcag22`. A signed-Lc
  ## metric is rejected with `InvalidOp`: a role is not a size — use
  ## `contrastForSize` for those.
  if metric != "wcag22":
    return err[ContrastVerdict, ColorError](colorError(InvalidOp,
        "contrastForRole is WCAG role-based; metric '" & metric &
        "' is signed-Lc (use contrastForSize)", "contrastForRole"))
  verdict(fg, bg, metric, wcagRoleThreshold(role, strict))

proc contrastForSize*(fg, bg: Color, size: ApcaSize, metric = "apca",
    strict = false): Result[ContrastVerdict, ColorError] {.raises: [].} =
  ## APCA/BridgePCA size-aware contrast verdict. The size defines the threshold
  ## (reusing the core Apca*/Bpca* constants); `metric` must be a signed-Lc
  ## metric (apca/bridgepca). The unsigned wcag22 ratio is rejected (a size is
  ## not a role — no cross-metric). `strict` has no APCA AAA tier (APCA defines
  ## no AAA level) — accepted for API symmetry but does not change the
  ## threshold (documented no-op).
  let thR = apcaSizeThreshold(size, metric)
  if thR.isErr:
    return err[ContrastVerdict, ColorError](thR.error)
  verdict(fg, bg, metric, thR.get)
