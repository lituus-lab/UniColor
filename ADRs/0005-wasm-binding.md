<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0005: WASM binding

- Status: Accepted
- Date: 2026-07-21
- Scope: `src/UniColor/wasm/`, `wasm/`, `nimble wasm`/`wasmTest`

## Decision

Alongside the native C ABI and Python binding, a WASM build is planned via
Emscripten (Nim -> C -> `emcc`), `--threads:off` (the C ABI is
single-threaded; enabling pthreads would need a worker and
`-s USE_PTHREADS`). Implementation specifics (export lists, struct
marshalling for calls reachable from JS, module format) land with the
binding itself and are documented in its own code comments.
