# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# registry — distance & contrast metric registration (data-driven descriptors,
# init-once / read-only). Built-in ΔE + contrast metrics registered at import
# (idempotent, no overwrite), lookup O(1) by name. Mirrors the spaces registry
# pattern: extensible until an application calls `seal*` (the engine leaves
# built-ins unsealed so user extensions can register).
#
# Contextual normalization:
#   - `distance(a, b, metric)` converts both operands to the metric's reference
#     space via the hub BEFORE calling the metric proc (which reads comps
#     directly in that space). This is the normalization: a color in any
#     registered space is mapped into the metric's context. ΔE procs read comps
#     directly (no internal conversion), so the dispatcher owns it.
#   - `contrast(fg, bg, metric)` delegates to the metric proc, which does its
#     own hub conversion (apcaContrast/bpcaContrast/contrastRatio convert to
#     sRGB internally). The dispatcher is thin.
# NO cross-metric comparison — thresholds are named per metric (ApcaFine,
# WcagAaNormal, ...) in their own modules; the registry stores metadata, not
# thresholds.
import std/options
import std/tables
import UniColor/core/core
import UniColor/core/space_tag
import UniColor/conversion/conversion
import UniColor/contrast/deltae
import UniColor/contrast/cmc
import UniColor/contrast/ok
import UniColor/contrast/hdr
import UniColor/contrast/cam16ucs
import UniColor/contrast/wcag
import UniColor/contrast/apca
import UniColor/contrast/bridgepca

type
  DistanceMetric* = object
    ## Descriptor for a color-distance metric (ΔE family). Data-driven:
    ## identity + function pointer + metadata. `compute` reads `comp(0..2)`
    ## directly in `referenceSpace` — the dispatcher converts operands there
    ## first (contextual normalization).
    name*: string
    referenceSpace*: SpaceTag
    jnd*: float64 # JND threshold for interpretation; 0.0 when undocumented.
    symmetric*: bool # false for ΔE94/CMC (a→b ≠ b→a).
    compute*: proc(a, b: Color): float64 {.raises: [].}

  ContrastMetric* = object
    ## Descriptor for a contrast metric (WCAG / APCA / BridgePCA). `compute`
    ## does its own hub conversion to the metric's working space, so the
    ## dispatcher passes operands unchanged.
    name*: string
    signed*: bool # true = signed Lc (APCA/BridgePCA, BoW+/WoB−); false = unsigned ratio (WCAG).
    experimental*: bool # true = opt-in (APCA/BridgePCA); false = WCAG default.
    default*: bool # true = WCAG 2.2 (the default metric).
    compute*: proc(text, bg: Color): Result[float64, ColorError] {.raises: [].}

# Registry state — module-level tables, idempotent registration, optional seal
# (mirrors spaces/registry.nim). Thread-safe by immutability after `seal*`.
var
  distByName: Table[string, DistanceMetric]
  distSealed: bool
  contrastByName: Table[string, ContrastMetric]
  contrastSealed: bool

proc registerDistanceMetric*(d: DistanceMetric): bool {.raises: [].} =
  ## Idempotent registration: returns false if `d.name` is empty, already
  ## present (no overwrite), or the registry is sealed. The caller must check
  ## the bool (no silent error).
  if distSealed or d.name.len == 0 or distByName.hasKey(d.name):
    return false
  distByName[d.name] = d
  true

proc registerContrastMetric*(m: ContrastMetric): bool {.raises: [].} =
  ## Idempotent registration of a contrast metric (same contract as
  ## `registerDistanceMetric`).
  if contrastSealed or m.name.len == 0 or contrastByName.hasKey(m.name):
    return false
  contrastByName[m.name] = m
  true

proc lookupDistanceMetric*(name: string): Option[DistanceMetric] {.raises: [].} =
  ## O(1) lookup by name; `none` if absent (absence = Option, not an error).
  ## `getOrDefault` avoids the `Table[]` KeyError the effect system would
  ## otherwise flag (we guard with `hasKey`, but the effect analyzer cannot see
  ## through the guard).
  if distByName.hasKey(name):
    some(distByName.getOrDefault(name))
  else:
    none(DistanceMetric)

proc lookupContrastMetric*(name: string): Option[ContrastMetric] {.raises: [].} =
  ## O(1) lookup by name; `none` if absent.
  if contrastByName.hasKey(name):
    some(contrastByName.getOrDefault(name))
  else:
    none(ContrastMetric)

proc sealDistanceMetrics*() {.raises: [].} =
  distSealed = true

proc sealContrastMetrics*() {.raises: [].} =
  contrastSealed = true

proc distanceMetricCount*(): int {.raises: [].} =
  distByName.len

proc contrastMetricCount*(): int {.raises: [].} =
  contrastByName.len

const DefaultContrastMetric* = "wcag22" # the default contrast metric.

proc distance*(a, b: Color, metric: string): Result[float64,
    ColorError] {.raises: [].} =
  ## Dispatched distance: look up `metric`, convert both operands to its
  ## reference space via the hub (contextual normalization), then call its
  ## `compute`. Returns `err` with `UnknownMetric` if the name is absent, or the
  ## hub conversion error otherwise. NaN/Inf in the operands propagate through
  ## `to` and the metric.
  ##
  ## Same-space pass-through: a color already in the metric's reference space is
  ## handed to `compute` unchanged. `to` routes same-space through the XYZ hub
  ## (no short-path for X->X), which injects the hub round-trip error (~1e-3) —
  ## that would corrupt the metric result for the common case "caller built
  ## colors in the metric's own space". Skipping the conversion here keeps the
  ## dispatcher bit-identical to the direct proc in that case.
  let d = lookupDistanceMetric(metric)
  if d.isNone:
    return err[float64, ColorError](colorError(UnknownMetric,
        "unknown distance metric: " & metric, "distance"))
  let desc = d.get
  let refSpace = desc.referenceSpace
  let aR = if a.spaceTag == refSpace: ok[Color, ColorError](a) else: a.to(refSpace)
  if aR.isErr:
    return err[float64, ColorError](aR.error)
  let bR = if b.spaceTag == refSpace: ok[Color, ColorError](b) else: b.to(refSpace)
  if bR.isErr:
    return err[float64, ColorError](bR.error)
  ok[float64, ColorError](desc.compute(aR.get, bR.get))

proc contrast*(fg, bg: Color, metric: string): Result[float64,
    ColorError] {.raises: [].} =
  ## Dispatched contrast: look up `metric` and call its `compute` (which does
  ## its own hub conversion). Returns `err` with `UnknownMetric` if the name is
  ## absent, else the metric's result (propagating its hub error). Polarity
  ## matters: `fg` is the text, `bg` the background.
  let m = lookupContrastMetric(metric)
  if m.isNone:
    return err[float64, ColorError](colorError(UnknownMetric,
        "unknown contrast metric: " & metric, "contrast"))
  m.get.compute(fg, bg)

proc contrast*(fg, bg: Color): Result[float64, ColorError] {.raises: [].} =
  ## Convenience overload — the default metric (WCAG 2.2).
  contrast(fg, bg, DefaultContrastMetric)

# Bootstrap — register built-in metrics at import (idempotent, no overwrite).
# Closures wrap the metric procs so all descriptors share a uniform `compute`
# signature (deltaE_cmc carries default l,c params, so it needs the wrapper; the
# rest are wrapped for uniformity).
discard registerDistanceMetric(DistanceMetric(name: "deltaE76",
    referenceSpace: tagLab, jnd: 2.3, symmetric: true,
    compute: proc(a, b: Color): float64 {.raises: [].} = deltaE76(a, b)))
discard registerDistanceMetric(DistanceMetric(name: "deltaE94",
    referenceSpace: tagLab, jnd: 1.0, symmetric: false,
    compute: proc(a, b: Color): float64 {.raises: [].} = deltaE94(a, b)))
discard registerDistanceMetric(DistanceMetric(name: "deltaE2000",
    referenceSpace: tagLab, jnd: 1.0, symmetric: true,
    compute: proc(a, b: Color): float64 {.raises: [].} = deltaE2000(a, b)))
discard registerDistanceMetric(DistanceMetric(name: "deltaE_cmc",
    referenceSpace: tagLab, jnd: 1.0, symmetric: false,
    compute: proc(a, b: Color): float64 {.raises: [].} = deltaE_cmc(a, b)))
discard registerDistanceMetric(DistanceMetric(name: "deltaE_ok",
    referenceSpace: tagOklab, jnd: 0.02, symmetric: true,
    compute: proc(a, b: Color): float64 {.raises: [].} = deltaE_ok(a, b)))
discard registerDistanceMetric(DistanceMetric(name: "deltaE_itp",
    referenceSpace: tagIctcp, jnd: 1.0, symmetric: true,
    compute: proc(a, b: Color): float64 {.raises: [].} = deltaE_itp(a, b)))
discard registerDistanceMetric(DistanceMetric(name: "deltaE_jz",
    referenceSpace: tagJzazbz, jnd: 0.0, symmetric: true,
    compute: proc(a, b: Color): float64 {.raises: [].} = deltaE_jz(a, b)))
discard registerDistanceMetric(DistanceMetric(name: "deltaE_cam16Ucs",
    referenceSpace: tagCam16Ucs, jnd: 0.0, symmetric: true,
    compute: proc(a, b: Color): float64 {.raises: [].} = deltaE_cam16Ucs(a, b)))

discard registerContrastMetric(ContrastMetric(name: "wcag22", signed: false,
    experimental: false, default: true, compute: contrastRatio))
discard registerContrastMetric(ContrastMetric(name: "apca", signed: true,
    experimental: true, default: false, compute: apcaContrast))
discard registerContrastMetric(ContrastMetric(name: "bridgepca", signed: true,
    experimental: true, default: false, compute: bpcaContrast))
