<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# Palette sampling benchmark

`nimble benchmarkPalette` compiles `benchmark_palette.nim` with `-d:release`.
It measures the best of three runs after one warm-up for each workload and
prints JSON. Every path contributes the first color component to a checksum;
the program fails rather than reporting timings if the checksums differ.

Reference run on 2026-08-15, Darwin arm64 T8132, Nim 2.2.10:

| Samples | `Palette.sample` | Prepared scalar | Prepared batch | Best speedup |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.754 ms | 0.184 ms | 0.188 ms | 4.10× |
| 100,000 | 64.506 ms | 18.013 ms | 18.361 ms | 3.58× |
| 1,000,000 | 643.923 ms | 179.459 ms | 185.501 ms | 3.59× |

Preparation removes stop construction and validation and converts each stop
into the interpolation space once. The scalar convenience path deliberately
retains per-call validation and conversion. Batch sampling currently improves
allocation shape and API ergonomics; it is a serial, order-stable loop, not
SIMD or parallel execution. Results from different machines are not directly
comparable.
