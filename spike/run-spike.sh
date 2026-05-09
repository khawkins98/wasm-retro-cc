#!/usr/bin/env bash
# spike/run-spike.sh — Phase 0 feasibility script
#
# Tests whether PCC's m68k backend produces output that can be linked
# against pre-compiled Retro68 stubs and produce a bootable Mac binary.
#
# Usage:
#   bash spike/run-spike.sh setup      # extract Retro68 stubs from Docker and clone PCC
#   bash spike/run-spike.sh build-pcc  # build PCC for m68k code generation
#   bash spike/run-spike.sh compile    # compile hello.c with native PCC
#   bash spike/run-spike.sh compare    # compare against Retro68 reference output
#   bash spike/run-spike.sh all        # run setup, build-pcc, compile, compare

set -euo pipefail
SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PCC_SRC="${SPIKE_DIR}/pcc-src"      # git clone of PCC goes here
STUBS_DIR="${SPIKE_DIR}/retro68-stubs"
HEADERS_DIR="${SPIKE_DIR}/retro68-headers"
BUILD_DIR="${SPIKE_DIR}/build"
RETRO68_IMAGE="ghcr.io/autc04/retro68:latest"

# ── setup ──────────────────────────────────────────────────────────────────
cmd_setup() {
  echo "=== Extracting Retro68 stubs from Docker image ==="
  docker pull "${RETRO68_IMAGE}"
  mkdir -p "${STUBS_DIR}" "${HEADERS_DIR}"

  # Use --entrypoint /bin/bash to bypass the Retro68 docker-entrypoint.sh,
  # which prints "Using multiversal interfaces" to stdout and corrupts the
  # tar stream when piped.  tar -h dereferences symlinks (libInterface.a
  # is a relative symlink pointing outside the lib/ directory).
  docker run --rm --entrypoint /bin/bash "${RETRO68_IMAGE}" \
    -c 'tar -hcf - -C /Retro68-build/toolchain/m68k-apple-macos lib' \
    | tar -xf - --strip-components=1 -C "${STUBS_DIR}"

  docker run --rm --entrypoint /bin/bash "${RETRO68_IMAGE}" \
    -c 'tar -hcf - -C /Retro68-build/toolchain/m68k-apple-macos include' \
    | tar -xf - --strip-components=1 -C "${HEADERS_DIR}"

  echo "Stubs extracted to: ${STUBS_DIR}"
  echo "Headers extracted to: ${HEADERS_DIR}"

  if [ ! -d "${PCC_SRC}" ]; then
    echo "=== Cloning PCC ==="
    git clone https://github.com/IanHarvey/pcc "${PCC_SRC}"
  fi
}

# ── build-pcc ──────────────────────────────────────────────────────────────
cmd_build_pcc() {
  echo "=== Building PCC for native host (to test m68k codegen) ==="
  pushd "${PCC_SRC}" > /dev/null
  # --target=m68k-unknown-apple is required: PCC's configure.ac maps the
  # 'apple' OS token to 'abi=classic68k' which activates the m68k backend.
  # 'm68k-unknown-elf' is not in PCC's supported target list.
  ./configure --target=m68k-unknown-apple
  make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
  popd > /dev/null
  echo "=== PCC built ==="
}

# ── compile ────────────────────────────────────────────────────────────────
cmd_compile() {
  echo "=== Compiling hello.c with PCC m68k backend ==="
  mkdir -p "${BUILD_DIR}"

  # Locate the pcc binary (BINPREFIX varies after config.sub canonicalisation,
  # e.g. m68k-unknown-apple-pcc or m68k-apple-macos-pcc).
  PCC_BIN=$(find "${PCC_SRC}/cc/cc" -name "*pcc" -type f 2>/dev/null | head -1)
  if [ -z "${PCC_BIN}" ]; then
    echo "ERROR: pcc binary not found under ${PCC_SRC}/cc/cc — did build-pcc succeed?"
    exit 1
  fi
  echo "Using PCC binary: ${PCC_BIN}"

  # Use PCC to compile to assembly, then assemble with GNU as (m68k)
  "${PCC_BIN}" \
    -I "${SPIKE_DIR}/../src/include" \
    -S -o "${BUILD_DIR}/hello.s" \
    "${SPIKE_DIR}/hello.c" \
    && echo "PCC compilation: OK" \
    || { echo "PCC compilation: FAILED"; exit 1; }

  echo "--- Assembly output (first 60 lines) ---"
  head -60 "${BUILD_DIR}/hello.s"

  # Assemble
  m68k-linux-gnu-as -m68000 -o "${BUILD_DIR}/hello.o" "${BUILD_DIR}/hello.s" \
    && echo "Assembly: OK" \
    || { echo "Assembly: FAILED (is m68k-linux-gnu-as installed?)"; exit 1; }

  # Link against pre-compiled Retro68 stubs
  # NOTE: This is the critical test — do the symbol names match?
  m68k-linux-gnu-ld \
    -m m68kelf \
    -T "${SPIKE_DIR}/mac.ld" \
    "${STUBS_DIR}/crt0.o" \
    "${BUILD_DIR}/hello.o" \
    "${STUBS_DIR}/libretro68.a" \
    "${STUBS_DIR}/libc.a" \
    -o "${BUILD_DIR}/hello.elf" \
    && echo "Linking: OK" \
    || { echo "Linking: FAILED — see symbol errors above"; exit 1; }

  echo "=== hello.elf produced at ${BUILD_DIR}/hello.elf ==="
}

# ── compare ───────────────────────────────────────────────────────────────
cmd_compare() {
  echo "=== Building reference with Retro68 GCC (via Docker) ==="
  docker run --rm \
    -v "${SPIKE_DIR}:/spike" \
    "${RETRO68_IMAGE}" \
    bash -c "
      cd /tmp && mkdir ref && cd ref
      cp /spike/hello.c .
      cat > CMakeLists.txt << 'EOF'
cmake_minimum_required(VERSION 3.15)
project(HelloSpike C)
add_application(HelloSpike CREATOR ???? hello.c)
EOF
      cmake . -DCMAKE_TOOLCHAIN_FILE=/Retro68-build/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake
      cmake --build .
      cp HelloSpike.bin /spike/build/hello-retro68.bin
    "

  echo "=== Comparison ==="
  echo "PCC output size:     $(wc -c < "${BUILD_DIR}/hello.elf" 2>/dev/null || echo 'NOT BUILT')"
  echo "Retro68 output size: $(wc -c < "${BUILD_DIR}/hello-retro68.bin" 2>/dev/null || echo 'NOT BUILT')"
  echo ""
  echo "Symbol diff (PCC output):"
  nm "${BUILD_DIR}/hello.elf" 2>/dev/null | sort || true
  echo ""
  echo "NOTE: Sizes will differ (ELF vs MacBinary) but symbol names should match."
  echo "If PCC output has undefined symbols that Retro68 reference resolves, those"
  echo "are missing from our shim headers or stub archive."
}

# ── dispatch ──────────────────────────────────────────────────────────────
case "${1:-all}" in
  setup)     cmd_setup ;;
  build-pcc) cmd_build_pcc ;;
  compile)   cmd_compile ;;
  compare)   cmd_compare ;;
  all)       cmd_setup && cmd_build_pcc && cmd_compile && cmd_compare ;;
  *)         echo "Usage: $0 [setup|build-pcc|compile|compare|all]"; exit 1 ;;
esac
