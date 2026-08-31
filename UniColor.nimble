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

task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"

task checkVGraph, "Fail on an import that climbs the layers in vgraph.cfg":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"

task docsDeps, "Install the docs toolchain (nimib)":
  exec "nimble install -y nimib"

task book, "Build the nimib book (needs nimib)":
  # nimib compiles and runs the book's code blocks: a drift fails the build.
  exec "nim c -r --path:src --hints:off -o:build/book book/index.nim"

task docs, "API reference + book into pages/ — what CI publishes":
  rmDir "pages"
  exec "nim doc --index:on --outdir:pages/api --project --hints:off src/UniColor.nim"
  exec "nimble book"
  # The book is the landing page; the generated reference sits under api/.
  cpFile "book/index.html", "pages/index.html"

task test, "Nim tests (debug, contracts active)":
  exec "nim c -r --path:src -o:build/test_all tests/test_all.nim"

task testRelease, "Nim tests (release, contracts compiled away)":
  exec "nim c -r -d:release --path:src -o:build/test_all_rel tests/test_all.nim"

task testCi, "Nim tests (CI subset, debug)":
  exec "nim c -r --path:src -o:build/test_all tests/test_all.nim"

task testCiRelease, "Nim tests (CI subset, release)":
  exec "nim c -r -d:release --path:src -o:build/test_all_rel tests/test_all.nim"

task testAll, "debug + release + C ABI":
  exec "nimble test"
  exec "nimble testRelease"
  exec "nimble ctest"

task example, "Nim demo":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"

task benchmarkPalette, "Benchmark scalar, prepared, and batch palette sampling":
  exec "nim c -r -d:release --path:src --hints:off" &
       " -o:build/benchmark_palette benchmarks/benchmark_palette.nim"

const
  cliExe =
    when defined(windows): "build/unicolor.exe"
    else: "build/unicolor"

task cli, "Build the unicolor CLI":
  exec "nim c -d:release --path:src -o:" & cliExe &
       " src/UniColor/cli/cli.nim"

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

task wasmTest, "Build the WASM module and run the node test suite":
  exec "nimble wasm"
  exec "node tests/wasm/test_unicolor.js"

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

task clibStatic, "C static library":
  exec "nim c --app:staticlib -d:staticNoAutoInit --noMain --mm:arc -d:release --path:src -o:" &
       staticLib & " src/UniColor/c_api.nim"

task clibMsvc, "C static library, MSVC ABI (Windows Python extension)":
  # CPython on Windows is MSVC-built and cannot link MinGW output.
  exec "nim c --cc:vcc --app:staticlib -d:staticNoAutoInit --noMain --mm:arc -d:release --path:src" &
       " -o:UniColor.lib src/UniColor/c_api.nim"

# Nim's MinGW toolchain names it mingw32-make.
let makeExe = if findExe("mingw32-make").len > 0: "mingw32-make" else: "make"

# `make -C`, not `cd dir && make`: nimble's exec runs no shell on Windows.
task ctest, "C ABI tests":
  exec "nimble clibStatic"
  exec makeExe & " -C tests/c"

task cexample, "C demo":
  exec "nimble clibStatic"
  exec makeExe & " -C examples/c"

task pyDeps, "Install Python build deps (setuptools, Cython, pytest) if missing":
  exec "python3 -m pip install --break-system-packages --quiet setuptools wheel \"Cython>=3.0.0\" pytest"

# The extension links the vcc static lib on Windows, the shared lib elsewhere.
task pyLib, "Build the library the Python extension links against":
  when defined(windows):
    exec "nimble clibMsvc"
  else:
    exec "nimble clib"

task pyNotebookDeps, "Install notebook build deps (nbformat, nbclient, ipykernel) if missing":
  exec "python3 -m pip install --break-system-packages --quiet nbformat nbclient ipykernel"

task buildCython, "Cython extension in-place":
  exec "nimble pyLib"
  exec "nimble pyDeps"
  # nimscript `cd` (lib/system/nimscript.nim) changes the VM cwd for the next
  # exec without a shell, so the task works under nimble's no-shell exec on Windows.
  cd "py"
  exec "python3 setup.py build_ext --inplace"
  cd ".."

task pyTest, "Cython extension + pytest":
  exec "nimble buildCython"
  cd "py"
  exec "python3 -m pytest -q"
  cd ".."

task pyWheel, "wheel":
  exec "nimble pyLib"
  exec "nimble pyDeps"
  cd "py"
  exec "python3 setup.py bdist_wheel"
  cd ".."

task coverage, "LCOV + HTML coverage report for the Nim sources (needs lcov)":
  # gcov and lcov driven directly, no coco. Linux and macOS only.
  # --debugger:native attributes lines to the .nim sources, not the generated C.
  # --include keeps stdlib out of the capture, where lcov 2.x aborts on Nim's
  # codegen. Together they leave nothing to suppress: no --ignore-errors here,
  # so a real problem still fails the build.
  let cache = "build/covcache"
  rmDir cache
  rmDir "coverage"
  exec "nim c --path:src --nimcache:" & cache &
       " --debugger:native --passC:--coverage --passL:--coverage" &
       " -o:build/test_coverage tests/test_all.nim"
  exec "./build/test_coverage"
  exec "lcov --capture --directory " & cache & " --base-directory ." &
       " --include \"*/src/UniColor/*\" --output-file lcov.info --quiet"
  exec "genhtml lcov.info --output-directory coverage --legend --quiet"
  exec "lcov --summary lcov.info"
