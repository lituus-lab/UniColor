# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/json
import std/monotimes
import std/times
import UniColor

const
  Workloads = [1_000, 100_000, 1_000_000]
  Repeats = 3

type Measurement = object
  milliseconds: float64
  checksum: float64

proc elapsedMilliseconds(started: MonoTime): float64 =
  (getMonoTime() - started).inNanoseconds.float64 / 1_000_000.0

proc sampleValues(count: int): seq[float64] =
  result = newSeq[float64](count)
  if count == 1:
    return
  let denominator = float64(count - 1)
  for index in 0 ..< count:
    result[index] = float64(index) / denominator

proc scalarMeasurement(palette: Palette,
    values: openArray[float64]): Measurement =
  let started = getMonoTime()
  var checksum = 0.0
  for value in values:
    let sampled = palette.sample(value)
    if sampled.isErr:
      quit sampled.error.message
    checksum += sampled.get.comp(0).float64
  Measurement(milliseconds: elapsedMilliseconds(started), checksum: checksum)

proc preparedMeasurement(sampler: PreparedPaletteSampler,
    values: openArray[float64]): Measurement =
  let started = getMonoTime()
  var checksum = 0.0
  for value in values:
    let sampled = sampler.sample(value)
    if sampled.isErr:
      quit sampled.error.message
    checksum += sampled.get.comp(0).float64
  Measurement(milliseconds: elapsedMilliseconds(started), checksum: checksum)

proc batchMeasurement(sampler: PreparedPaletteSampler,
    values: openArray[float64]): Measurement =
  let started = getMonoTime()
  let sampled = sampler.sampleBatch(values)
  if sampled.isErr:
    quit sampled.error.message
  var checksum = 0.0
  for color in sampled.get:
    checksum += color.comp(0).float64
  Measurement(milliseconds: elapsedMilliseconds(started), checksum: checksum)

proc bestMeasurement(palette: Palette, sampler: PreparedPaletteSampler,
    values: openArray[float64], mode: int): Measurement =
  result.milliseconds = Inf
  for _ in 0 ..< Repeats:
    let current = case mode
      of 0: scalarMeasurement(palette, values)
      of 1: preparedMeasurement(sampler, values)
      else: batchMeasurement(sampler, values)
    if current.milliseconds < result.milliseconds:
      result = current

let palette = viridis(6).get
let sampler = palette.prepareSampler().get
var rows = newJArray()
for count in Workloads:
  let values = sampleValues(count)
  discard scalarMeasurement(palette, values)
  discard preparedMeasurement(sampler, values)
  discard batchMeasurement(sampler, values)
  let
    scalar = bestMeasurement(palette, sampler, values, 0)
    prepared = bestMeasurement(palette, sampler, values, 1)
    batch = bestMeasurement(palette, sampler, values, 2)
  if abs(scalar.checksum - prepared.checksum) > 1.0e-6 or
      abs(scalar.checksum - batch.checksum) > 1.0e-6:
    quit "palette benchmark checksum mismatch"
  rows.add(%*{
    "samples": count,
    "repeats": Repeats,
    "scalar_ms": scalar.milliseconds,
    "prepared_ms": prepared.milliseconds,
    "batch_ms": batch.milliseconds,
    "prepared_speedup": scalar.milliseconds / prepared.milliseconds,
    "batch_speedup": scalar.milliseconds / batch.milliseconds,
    "checksum": scalar.checksum
  })
echo $(%*{
  "benchmark": "ordered_palette_sampling",
  "build": "release",
  "selection": "best_of_repeats",
  "rows": rows
})
