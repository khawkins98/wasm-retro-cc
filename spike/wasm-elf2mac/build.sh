#!/usr/bin/env bash
#
# spike/wasm-elf2mac/build.sh — Phase 2.3 Elf2Mac port.
#
# Cmake-based unlike cc1/binutils (autoconf). Smaller source tree;
# Boost header-only. Same wasm flags pattern at relink time.
#
# Usage:
#   bash spike/wasm-elf2mac/build.sh stage1   # native cmake build
#   bash spike/wasm-elf2mac/build.sh stage2   # wasm via emcmake
#   bash spike/wasm-elf2mac/build.sh relink   # extract make link line + add wasm flags
#   bash spike/wasm-elf2mac/build.sh smoke    # node + Elf2Mac --help
#   bash spike/wasm-elf2mac/build.sh clean

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
STAGE1_DIR="${BUILD_DIR}/stage1"
STAGE2_DIR="${BUILD_DIR}/stage2"
IMAGE_TAG="wasm-retro-cc/phase2-1-builder:latest"

run_in_container() {
  docker run --rm \
    -v "${SCRIPT_DIR}:/spike" \
    -e EMSDK=/opt/emsdk \
    -e PATH=/opt/emsdk:/opt/emsdk/upstream/emscripten:/opt/emsdk/upstream/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --entrypoint /bin/bash \
    "${IMAGE_TAG}" -c "$1"
}

check_image() {
  if ! docker image inspect "${IMAGE_TAG}" > /dev/null 2>&1; then
    echo "ERROR: image not built — run: bash spike/wasm-cc1/build.sh image" >&2
    exit 1
  fi
}

# Standalone CMakeLists.txt that wires ResourceFiles + Elf2Mac as
# subdirectories of a synthesized parent project. The Retro68 build
# normally orchestrates this through its top-level CMakeLists.txt; we
# extract just the bits we need.
# Make a writable copy of /Retro68/Elf2Mac and patch RealLD to a
# no-op so the wasm build can run convert-only (skip fork+exec ld).
# In the wasm pipeline, JS glue orchestrates ld externally and passes
# the resulting ELF path to Elf2Mac. RealLD's fork() in the original
# source is what made Elf2Mac.wasm exit -1 on Module instantiation.
prepare_elf2mac() {
  local target_dir="$1"
  run_in_container "
    set -e
    rm -rf $target_dir
    cp -r /Retro68/Elf2Mac $target_dir
    cd $target_dir

    # Stub out RealLD's body — the fork+exec is the offending block.
    # Python with proper brace-counting since simple regex can't
    # match a balanced {...}.
    python3 << 'PYEOF'
src = open('Elf2Mac.cc').read()
# Find the start of RealLD's body
sig = 'void RealLD(vector<string> args)'
start = src.find(sig)
if start < 0:
    raise SystemExit('RealLD signature not found')
# Find the opening brace after the signature
brace_open = src.find('{', start)
# Match braces to find the body end
depth = 0
i = brace_open
while i < len(src):
    if src[i] == '{':
        depth += 1
    elif src[i] == '}':
        depth -= 1
        if depth == 0:
            brace_close = i
            break
    i += 1
patched_body = (
    sig + '\\n'
    '{\\n'
    '    /* Phase 2.3c patch: convert-only mode. The JS host\\n'
    '     * orchestrates wasm ld externally; this function is a\\n'
    '     * no-op. The ELF file Elf2Mac expects to read next\\n'
    '     * (outputFile + .gdb) must be present in MEMFS before\\n'
    '     * main() is invoked. */\\n'
    '    (void)args;\\n'
    '}'
)
out = src[:start] + patched_body + src[brace_close+1:]
open('Elf2Mac.cc', 'w').write(out)
PYEOF
    echo 'patched Elf2Mac.cc OK'
    grep -A1 'void RealLD' Elf2Mac.cc | head -3
  "
}

# Make a writable copy of /Retro68/ResourceFiles and apply our patch
# (boost::filesystem → std::filesystem). The Retro68 image is read-only
# inside the container; we materialise the patched source under the
# build tree so cmake's add_subdirectory can reach it.
prepare_resourcefiles() {
  local target_dir="$1"
  run_in_container "
    set -e
    rm -rf $target_dir
    cp -r /Retro68/ResourceFiles $target_dir
    cd $target_dir

    # Swap boost::filesystem -> std::filesystem in ResourceFile.cc.
    # Boost.Filesystem requires a compiled library (libboost_filesystem),
    # not part of header-only Boost; emscripten doesn't ship it. The
    # std::filesystem API is C++17 and equivalent for the operations
    # ResourceFile.cc uses (path manipulation, basic_fstream).
    sed -i \
      -e 's|#include <boost/filesystem.hpp>|#include <filesystem>\n#include <vector>\n#include <functional>\n#include <algorithm>|' \
      -e 's|#include \"boost/filesystem/fstream.hpp\"|#include <fstream>|' \
      -e 's|namespace fs = boost::filesystem;|namespace fs = std::filesystem;|' \
      -e 's|fs::ifstream|std::ifstream|g' \
      -e 's|fs::ofstream|std::ofstream|g' \
      -e 's|fs::fstream|std::fstream|g' \
      ResourceFile.cc

    # Drop the Boost components requirement in CMakeLists.txt — header
    # -only Boost is enough now. Also strip the ResInfo executable
    # build (separate CLI tool that depends on Boost.program_options,
    # not needed by Elf2Mac).
    sed -i \
      -e 's|find_package(Boost COMPONENTS filesystem system REQUIRED)|find_package(Boost REQUIRED)|' \
      -e 's|find_package(Boost COMPONENTS program_options REQUIRED)|# ResInfo dependency removed for Elf2Mac wasm build|' \
      -e '/^add_executable(ResInfo /,/^target_include_directories(ResInfo /d' \
      -e 's|\${Boost_LIBRARIES} \${HFS_LIBRARY}|\${HFS_LIBRARY}|' \
      CMakeLists.txt
    # Remove the empty trailing target_include_directories(ResInfo …) line if any
    grep -v "ResInfo" CMakeLists.txt > CMakeLists.txt.new && mv CMakeLists.txt.new CMakeLists.txt

    echo 'patched ResourceFiles OK'
  "
}

write_cmakelists() {
  cat > "$1" <<'CMAKE'
cmake_minimum_required(VERSION 3.15)
project(Elf2MacStandalone C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Boost REQUIRED)
include_directories(${Boost_INCLUDE_DIR})

# ELF: Retro68's "ELF" target is what Elf2Mac links against for libelf.
# Phase 2.3b decision (option b in LEARNINGS): we replace libelf with a
# hand-rolled 200-LOC MinimalElf that implements just the 10 libelf
# functions Elf2Mac uses (elf_begin, elf_getshdr, gelf_getsym, etc).
# Same target name "ELF" so /Retro68/Elf2Mac/CMakeLists.txt
# (target_link_libraries(Elf2Mac ResourceFiles ELF)) keeps working
# unchanged.
add_subdirectory(/spike/minimal-elf ${CMAKE_CURRENT_BINARY_DIR}/MinimalElf)
add_library(ELF INTERFACE)
target_link_libraries(ELF INTERFACE MinimalElf)

# HFS: ResourceFile.cc uses libhfs in ONE method (writes .dsk volume).
# Elf2Mac never calls that method. We provide a shim hfs-stub.h +
# hfs-stub.c that satisfies the compile-time include and supplies
# no-op definitions for link-time symbol resolution. See
# spike/wasm-elf2mac/hfs-stub.h for full rationale.
add_library(hfs-stub STATIC /spike/hfs-stub.c)
target_include_directories(hfs-stub PUBLIC /spike)
# Rename hfs-stub.h to hfs.h in the include path so the existing
# #include "hfs.h" in ResourceFile.cc picks it up. Easiest path:
# create a symlink in the build tree.
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/hfs-shim/hfs.h "#include \"/spike/hfs-stub.h\"\n")
include_directories(BEFORE ${CMAKE_CURRENT_BINARY_DIR}/hfs-shim)

set(HFS_LIBRARY hfs-stub CACHE STRING "stub — see hfs-stub.h")
set(HFS_INCLUDE_DIR ${CMAKE_CURRENT_BINARY_DIR}/hfs-shim CACHE PATH "stub — see hfs-stub.h")

# ResourceFiles (patched copy at /spike/build/<stage>/ResourceFiles-src
# — boost::filesystem replaced with std::filesystem so wasm doesn't
# need a compiled Boost.Filesystem).
add_subdirectory(/spike/build/RESOURCEFILES_DIR ${CMAKE_CURRENT_BINARY_DIR}/ResourceFiles)

# Elf2Mac (patched copy at /spike/build/Elf2Mac-src — RealLD stubbed
# to no-op so the wasm build doesn't fork+exec ld on Module init).
add_subdirectory(/spike/build/ELF2MAC_DIR ${CMAKE_CURRENT_BINARY_DIR}/Elf2Mac)
CMAKE
}

# Build libelf for wasm — needed by Elf2Mac for ELF parsing
# (gelf_getshdr, elf_nextscn, etc.). Emscripten's port catalog
# doesn't ship libelf. We grab the libelfin source (a slim libelf
# replacement that builds with just a C compiler — no autoconf/libtool)
# and compile it with emcc into a static archive.
#
# Source: https://github.com/aclements/libelfin — header-only wrapper
# over libelf. NOT what we want — Elf2Mac uses the gelf.h API
# directly.
#
# Better choice: elfutils' libelf. Standard autoconf, ~10K LOC. We
# fetch the source tarball and emconfigure-build it the same way as
# binutils' libbfd.
ELFUTILS_VERSION=0.190

cmd_libelf() {
  check_image
  mkdir -p "${BUILD_DIR}/libelf"
  # Heredoc-via-separate-script. Embedding elfutils configure directly
  # in run_in_container's heredoc kept breaking the host bash parser
  # around the CFLAGS line. Keep the inner script in its own file.
  run_in_container "ELFUTILS_VERSION=${ELFUTILS_VERSION} bash /spike/build-libelf-inner.sh"
}

cmd_stage1() {
  check_image
  mkdir -p "${STAGE1_DIR}"
  prepare_resourcefiles /spike/build/ResourceFiles-stage1
  prepare_elf2mac /spike/build/Elf2Mac-stage1
  write_cmakelists "${STAGE1_DIR}/CMakeLists.txt"
  sed -i.bak \
    -e 's|RESOURCEFILES_DIR|ResourceFiles-stage1|g' \
    -e 's|ELF2MAC_DIR|Elf2Mac-stage1|g' \
    "${STAGE1_DIR}/CMakeLists.txt"

  echo "[stage1] configuring native cmake (host build)"
  run_in_container "
    set -euo pipefail
    cd /spike/build/stage1
    if [ ! -f Makefile ]; then
      cmake . -DCMAKE_BUILD_TYPE=Release 2>&1 | tee configure.log | tail -30
    fi
    echo '[stage1] building'
    make -j\"\$(nproc)\" Elf2Mac 2>&1 | tee build.log | tail -20
    ls -lh Elf2Mac 2>&1 || echo '(no Elf2Mac binary produced)'
  "
}

cmd_stage2() {
  if [ ! -f "${STAGE1_DIR}/Elf2Mac/Elf2Mac" ]; then
    echo "stage 2 needs stage 1 output (${STAGE1_DIR}/Elf2Mac/Elf2Mac) — run 'stage1' first" >&2
    exit 1
  fi
  check_image
  mkdir -p "${STAGE2_DIR}"
  # Stage just the Boost subdirectory we need so -DBoost_INCLUDE_DIR
  # points at boost/ alone, not all of /usr/include (which pulls host
  # aarch64 glibc headers that confuse emcc).
  run_in_container "
    mkdir -p /spike/build/boost-headers/boost
    cp -r /usr/include/boost/. /spike/build/boost-headers/boost/
  "
  prepare_resourcefiles /spike/build/ResourceFiles-stage2
  prepare_elf2mac /spike/build/Elf2Mac-stage2
  write_cmakelists "${STAGE2_DIR}/CMakeLists.txt"
  sed -i.bak \
    -e 's|RESOURCEFILES_DIR|ResourceFiles-stage2|g' \
    -e 's|ELF2MAC_DIR|Elf2Mac-stage2|g' \
    "${STAGE2_DIR}/CMakeLists.txt"

  echo "[stage2] configuring wasm cross via emcmake"
  run_in_container "
    set -euo pipefail
    cd /spike/build/stage2
    if [ ! -f Makefile ]; then
      # Emscripten's CMake toolchain restricts search paths to the
      # wasm sysroot; host /usr/include/boost is not auto-discovered.
      # Boost is header-only here (no compiled components), so just
      # point Boost_INCLUDE_DIR at the host install and CMake's
      # FindBoost is satisfied.
      emcmake cmake . \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS=\"-Os -g0 -fwasm-exceptions\" \
        -DBoost_INCLUDE_DIR=/spike/build/boost-headers \
        -DBoost_NO_BOOST_CMAKE=ON \
        2>&1 | tee configure.log | tail -50
    fi
    echo '[stage2] building'
    emmake make -j\"\$(nproc)\" Elf2Mac 2>&1 | tee build.log | tail -30 || true
    ls -lh Elf2Mac Elf2Mac.wasm 2>&1 || echo '(no artefacts)'
  "
}

cmd_relink() {
  if [ ! -d "${STAGE2_DIR}" ]; then
    echo "relink needs stage 2 — run 'stage2' first" >&2
    exit 1
  fi
  echo "[relink] producing Elf2Mac.mjs with wasm-aware flags"
  run_in_container "
    set -euo pipefail
    cd /spike/build/stage2

    # -fwasm-exceptions because Boost.algorithm (header-only) throws
    # C++ exceptions. Must match the compile-side flag in stage 2
    # CXXFLAGS — exception model is sticky across .o + link.
    LDFLAGS_WASM='-fwasm-exceptions -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=1GB -sINITIAL_MEMORY=64MB -sSUPPORT_LONGJMP=wasm -sLLD_REPORT_UNDEFINED=1 -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORTED_FUNCTIONS=_main,_malloc,_free -sEXPORTED_RUNTIME_METHODS=FS,ERRNO_CODES,NODEFS,allocateUTF8,callMain -lnodefs.js -sEXPORT_NAME=createElf2Mac'

    cd Elf2Mac 2>/dev/null || cd .
    rm -f Elf2Mac Elf2Mac.js Elf2Mac.wasm
    # CMake uses VERBOSE=1 (not V=1) for verbose output. Emcc's
    # cmake-driven link emits to Elf2Mac.js (not Elf2Mac) — sed on
    # that to get .mjs.
    LINK_LINE=\$(VERBOSE=1 emmake make Elf2Mac 2>&1 | grep -E 'em\\+\\+|emcc' | tail -1)
    if [ -z \"\$LINK_LINE\" ]; then
      echo 'Could not capture link line'
      exit 1
    fi
    PATCHED=\$(echo \"\$LINK_LINE\" | sed -e 's|-o Elf2Mac.js |-o Elf2Mac.mjs |g')
    echo '[relink] re-linking with wasm flags'
    eval \"\$PATCHED \$LDFLAGS_WASM\" 2>&1 | tail -10
  "

  echo '[relink] outputs:'
  find "${STAGE2_DIR}" -maxdepth 4 -name "Elf2Mac.mjs" -o -name "Elf2Mac.wasm" 2>&1
}

cmd_smoke() {
  local mjs=$(find "${STAGE2_DIR}" -name "Elf2Mac.mjs" 2>/dev/null | head -1)
  if [ -z "$mjs" ]; then
    echo "smoke needs Elf2Mac.mjs — run 'relink' first" >&2
    exit 1
  fi
  echo "[smoke] loading ${mjs}"
  node --input-type=module -e "
    import('${mjs}').then(async (mod) => {
      const Module = await mod.default({
        noInitialRun: true,
        print: (s) => console.log('[e2m]', s),
        printErr: (s) => console.error('[e2m err]', s),
      });
      try {
        const rc = Module.callMain(['--help']);
        console.log('[smoke] exit:', rc);
      } catch (e) {
        if (e.name === 'ExitStatus') process.exit(e.status);
        throw e;
      }
    });
  "
}

cmd_clean() { rm -rf "${BUILD_DIR}"; }

case "${1:-stage1}" in
  libelf) cmd_libelf ;;
  stage1) cmd_stage1 ;;
  stage2) cmd_stage2 ;;
  relink) cmd_relink ;;
  smoke)  cmd_smoke ;;
  clean)  cmd_clean ;;
  *) echo "usage: $0 [libelf|stage1|stage2|relink|smoke|clean]" >&2; exit 2 ;;
esac
