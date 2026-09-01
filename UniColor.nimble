# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# UniColor — perceptual color engine.

version       = "1.1.0"
author        = "lituus-lab"
description   = "Perceptual color engine (Nim + C ABI + Python)"
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "https://github.com/lbartoletti/NimContracts#main"

# nimble 0.22 exits 0 even when an `exec` inside a task fails, so a task's exit
# code says nothing about whether its body ran. Each task writes a marker as
# its last statement; `tools/gate.nim` removes the marker, runs the task, and
# fails if it is not there afterwards. `nimble canary` proves the gate still
# bites -- if that one ever passes, every other green result is worthless.
const gateExe =
  when defined(windows): "build/unigate.exe" else: "build/unigate"

template done(task: string) =
  mkDir "build/.gate"
  writeFile("build/.gate/" & task & ".ok", "")

proc gate(task: string): string =
  ## `exec gate("test")` -- builds the tool on first use.
  if not fileExists(gateExe):
    exec "nim c --hints:off -o:" & gateExe & " tools/gate.nim"
  gateExe & " " & task

task canary, "Must fail: proves the gate still catches a broken build":
  # No `done` here on purpose: the exec below raises, so the marker is never
  # written and the gate reports the failure nimble swallowed.
  exec "nim c -r --hints:off --path:src -o:build/canary tests/canary_broken.nim"

task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"
  done "lint"

task checkVGraph, "Fail on an import that climbs the layers in vgraph.cfg":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"
  done "checkVGraph"

task docsDeps, "Install the docs toolchain (nimib)":
  exec "nimble install -y nimib"
  done "docsDeps"

task book, "Build the nimib book (needs nimib)":
  # nimib compiles and runs the book's code blocks: a drift fails the build.
  exec "nim c -r --path:src --hints:off -o:build/book book/index.nim"
  done "book"

task docs, "API reference + book into pages/ — what CI publishes":
  rmDir "pages"
  exec "nim doc --index:on --outdir:pages/api --project --hints:off src/UniColor.nim"
  exec gate("book")
  # The book is the landing page; the generated reference sits under api/.
  cpFile "book/index.html", "pages/index.html"
  done "docs"

task test, "Nim tests (debug, contracts active)":
  exec "nim c -r --path:src -o:build/test_all tests/test_all.nim"
  done "test"

task testRelease, "Nim tests (release, contracts compiled away)":
  exec "nim c -r -d:release --path:src -o:build/test_all_rel tests/test_all.nim"
  done "testRelease"

task testCi, "Nim tests (CI subset, debug)":
  exec "nim c -r --path:src -o:build/test_all tests/test_all.nim"
  done "testCi"

task testCiRelease, "Nim tests (CI subset, release)":
  exec "nim c -r -d:release --path:src -o:build/test_all_rel tests/test_all.nim"
  done "testCiRelease"

task testAll, "debug + release + C ABI":
  exec gate("test")
  exec gate("testRelease")
  exec gate("ctest")
  done "testAll"

task example, "Nim demo":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"
  done "example"

task benchmarkPalette, "Benchmark scalar, prepared, and batch palette sampling":
  exec "nim c -r -d:release --path:src --hints:off" &
       " -o:build/benchmark_palette benchmarks/benchmark_palette.nim"
  done "benchmarkPalette"

const
  cliExe =
    when defined(windows): "build/unicolor.exe"
    else: "build/unicolor"

task cli, "Build the unicolor CLI":
  exec "nim c -d:release --path:src -o:" & cliExe &
       " src/UniColor/cli/cli.nim"
  done "cli"

# emcc EXPORTED_FUNCTIONS: the uc_wasm_* color adapters (emscripten's JS wrappers
# cannot marshal the 20-byte uc_color struct by value) plus the handle / string
# uc_* the JS glue calls directly. Single-quoted, emcc's array syntax; the
# surrounding ['...'] is added in the task exec below.
const
  wasmOut = "build/wasm/unicolor.js"
  wasmExports = "_uc_init','_uc_version','_uc_abi_major','_uc_abi_minor','_uc_abi_patch'," &
    "'_uc_format_css','_uc_wasm_parse','_uc_wasm_make','_uc_wasm_srgb'," &
    "'_uc_wasm_oklch','_uc_wasm_format_css'," &
    "'_uc_wasm_convert','_uc_wasm_gamut_map','_uc_wasm_theme_resolve'," &
    "'_uc_wasm_palette_color_at','_uc_wasm_palette_sample','_uc_wasm_palette_role'," &
    "'_uc_wasm_contrast','_uc_wasm_contrast_metric','_uc_wasm_distance'," &
    "'_uc_theme_make','_uc_theme_free','_uc_theme_count','_uc_theme_has_role'," &
    "'_uc_theme_export','_uc_palette_make','_uc_palette_free','_uc_palette_len'," &
    "'_uc_palette_tag','_uc_palette_intent','_uc_import_theme','_uc_import_palette'," &
    "'_uc_import_reported','_uc_import_report_free','_uc_import_format_name'," &
    "'_uc_import_schema_version','_uc_import_warning_count','_uc_import_warning'," &
    "'_uc_validate_theme','_uc_validate_palette','_uc_validation_free'," &
    "'_uc_validation_score','_uc_validation_worst','_uc_validation_rule_count'," &
    "'_uc_validation_rule_name','_uc_validation_rule_severity','_uc_validation_rule_metric'," &
    "'_uc_validation_rule_threshold','_uc_validation_rule_message','_malloc','_free"
  wasmRt = "ccall','cwrap','UTF8ToString','getValue','setValue','stringToUTF8'," &
    "'lengthBytesUTF8"

task wasm, "Build the WASM module (unicolor.wasm + JS glue) via emscripten":
  # Nim -> C (emcc as the clang frontend) -> emcc link. --threads:off: the C ABI
  # is single-threaded; pthreads would need a worker and -s USE_PTHREADS.
  #
  # The link flags go to a response file: the EXPORTED_* arrays are emcc's
  # single-quoted JS syntax (`['_uc_init',...]`), and embedding those single
  # quotes inside a double-quoted `--passL:"..."` breaks nimscript's `sh -c`
  # quoting. A response file is whitespace-split, so each `-s FLAG=[...]` (no
  # spaces) is one token, and the quotes reach emcc verbatim.
  #
  # EXPORT_ES6: the factory `export default`s the module instead of the UMD
  # `module.exports` branch. A UMD factory loaded as ESM (a consumer with
  # `{"type":"module"}` above the tarball) skips that branch and exports
  # nothing; EXPORT_ES6 makes it a real ES module, so the glue's
  # `mod.default ?? mod` resolves in every consumer context.
  exec "mkdir -p build/wasm"
  writeFile("build/wasm/flags.txt",
    "-s WASM=1\n" &
    "-s MODULARIZE=1\n" &
    "-s EXPORT_ES6=1\n" &
    "-s EXPORT_NAME=UniColorModule\n" &
    "-s EXPORTED_FUNCTIONS=['" & wasmExports & "']\n" &
    "-s EXPORTED_RUNTIME_METHODS=['" & wasmRt & "']\n" &
    "-s ALLOW_MEMORY_GROWTH=1\n")
  exec "nim c --noMain --mm:arc --threads:off -d:release --path:src" &
    " --os:linux --cpu=wasm32 --cc:clang --clang.exe=emcc --clang.linkerexe=emcc" &
    " --passC:\"-s WASM=1 -O2\"" &
    " --passL:@build/wasm/flags.txt" &
    " -o:" & wasmOut & " src/UniColor/wasm/wasm.nim"
  done "wasm"

task wasmTest, "Build the WASM module and run the node test suite":
  exec gate("wasm")
  exec "node tests/wasm/test_unicolor.js"
  done "wasmTest"

# Nim takes `-o:` literally and appends no platform extension.
const
  sharedLib =
    when defined(windows): "libUniColor.dll"
    elif defined(macosx): "libUniColor.dylib"
    else: "libUniColor.so"
  staticLib = "libUniColor.a"  # MinGW `ar` on Windows, so `.a` everywhere.

  # @rpath install_name, so the copy bundled in the wheel is found at import.
  macArgs =
    when defined(macosx): " --passL:\"-Wl,-install_name,@rpath/" & sharedLib & "\""
    else: ""

task clib, "C shared library":
  exec "nim c --app:lib --noMain --mm:arc -d:release --path:src -o:" & sharedLib &
       macArgs & " src/UniColor/c_api.nim"
  done "clib"

task clibStatic, "C static library":
  exec "nim c --app:staticlib -d:staticNoAutoInit --noMain --mm:arc -d:release --path:src -o:" &
       staticLib & " src/UniColor/c_api.nim"
  done "clibStatic"

task clibMsvc, "C static library, MSVC ABI (Windows Python extension)":
  # CPython on Windows is MSVC-built and cannot link MinGW output.
  exec "nim c --cc:vcc --app:staticlib -d:staticNoAutoInit --noMain --mm:arc -d:release --path:src" &
       " -o:UniColor.lib src/UniColor/c_api.nim"
  done "clibMsvc"

# Nim's MinGW toolchain names it mingw32-make.
let makeExe = if findExe("mingw32-make").len > 0: "mingw32-make" else: "make"

# `make -C`, not `cd dir && make`: nimble's exec runs no shell on Windows.
task ctest, "C ABI tests":
  exec gate("clibStatic")
  exec makeExe & " -C tests/c"
  done "ctest"

task cexample, "C demo":
  exec gate("clibStatic")
  exec makeExe & " -C examples/c"
  done "cexample"

task pyDeps, "Install Python build deps (setuptools, Cython, pytest) if missing":
  exec "python3 -m pip install --break-system-packages --quiet setuptools wheel \"Cython>=3.0.0\" pytest"
  # Ubuntu ships a setuptools that predates PEP 639 and cannot parse the SPDX
  # licence pyproject.toml declares. pip refuses to uninstall a distro- or
  # brew-managed package, so install over it rather than --upgrade it.
  # packaging comes with it: setuptools 77 reads packaging.licenses, which the
  # distro's older copy does not have, and it shadows the vendored one.
  exec "python3 -m pip install --break-system-packages --quiet --ignore-installed \"setuptools>=77\" \"packaging>=24.2\""
  done "pyDeps"

# The extension links the vcc static lib on Windows, the shared lib elsewhere.
task pyLib, "Build the library the Python extension links against":
  when defined(windows):
    exec gate("clibMsvc")
  else:
    exec gate("clib")
  done "pyLib"

task pyNotebookDeps, "Install notebook build deps (nbformat, nbclient, ipykernel) if missing":
  exec "python3 -m pip install --break-system-packages --quiet nbformat nbclient ipykernel"
  done "pyNotebookDeps"

task buildCython, "Cython extension in-place":
  exec gate("pyLib")
  exec gate("pyDeps")
  # nimscript `cd` (lib/system/nimscript.nim) changes the VM cwd for the next
  # exec without a shell, so the task works under nimble's no-shell exec on Windows.
  cd "py"
  exec "python3 setup.py build_ext --inplace"
  cd ".."
  done "buildCython"

task pyTest, "Cython extension + pytest":
  exec gate("buildCython")
  cd "py"
  exec "python3 -m pytest -q"
  cd ".."
  done "pyTest"

task pyWheel, "wheel":
  exec gate("pyLib")
  exec gate("pyDeps")
  cd "py"
  exec "python3 setup.py bdist_wheel"
  cd ".."
  done "pyWheel"

task coverage, "LCOV + HTML coverage report for the Nim sources (needs lcov)":
  # gcov and lcov driven directly, no coco. Linux and macOS only.
  # --debugger:native attributes lines to the .nim sources, not the generated C.
  # --include keeps stdlib out of the capture, where lcov 2.x aborts on Nim's
  # codegen.
  # `mismatch` is the one suppression, and it is not optional: lcov 2.x checks
  # its own end line for a function against gcov's, and Nim's generated
  # destructors disagree -- a closure environment, a seq, NimContracts'
  # PostConditionDefect. Removing one only advances lcov to the next, so there
  # is no source-level fix. Every other lcov error still fails the build.
  let cache = "build/covcache"
  rmDir cache
  rmDir "coverage"
  exec "nim c --path:src --nimcache:" & cache &
       " --debugger:native --passC:--coverage --passL:--coverage" &
       " -o:build/test_coverage tests/test_all.nim"
  exec "./build/test_coverage"
  exec "lcov --capture --directory " & cache & " --base-directory ." &
       " --include \"*/src/UniColor/*\" --output-file lcov.info --quiet --ignore-errors mismatch"
  # gcov can attribute a final generated expression to EOF + 1; `range` is
  # genhtml's filter for that compiler artefact, and it wants the matching
  # category allowance before applying it. lcov 2.0 -- the one ubuntu-latest
  # installs -- rejects `range` as a category outright, and does not make the
  # check that needs it; 2.5 does both. Measured on each, not assumed.
  let genhtmlRange =
    if gorgeEx("genhtml --version").output.contains("LCOV version 2.0"): ""
    else: " --filter range --ignore-errors range"
  exec "genhtml lcov.info" & genhtmlRange &
       " --output-directory coverage --legend --quiet"
  exec "lcov --summary lcov.info"
  done "coverage"
