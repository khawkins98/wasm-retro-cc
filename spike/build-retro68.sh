#!/usr/bin/env bash
#
# spike/build-retro68.sh — Phase 2.0 Retro68 GCC derisk build.
#
# Compiles spike/hello_toolbox.c with the pinned Retro68 GCC toolchain
# (via Docker) and produces a complete MacBinary II APPL ready to vendor
# into classic-vibe-mac as a prebuilt playground demo.
#
# Why pinned by SHA256: build reproducibility across machines and CI.
# The same digest is used by the archived spike-pcc/run-spike.sh so any
# comparisons between Phase 1 (PCC) and Phase 2 (Retro68) artefacts use
# the exact same Retro68 reference toolchain. If we ever rebase to a
# newer Retro68 image, every vendored binary's provenance block in
# classic-vibe-mac MUST be updated alongside.
#
# Usage:
#   bash spike/build-retro68.sh           # default: build hello_toolbox
#   bash spike/build-retro68.sh clean     # remove spike/build/
#
# Output:
#   spike/build/hello-toolbox-retro68.bin   # complete MacBinary II APPL
#   spike/build/hello-toolbox-retro68.sha   # SHA-256 of the .bin
#
# Exit status: 0 on success; non-zero if Docker / CMake / link fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"

# Pinned Retro68 image — matches spike-pcc/run-spike.sh so artefacts
# from both phases can be compared without compiler-version drift.
RETRO68_IMAGE="ghcr.io/autc04/retro68@sha256:e8b6cc8ac3c0cf26dcb299d5396cc7055c102b6bc46b67e2df960453af8ae92b"

cmd_clean() {
  echo "=== Cleaning ${BUILD_DIR} ==="
  rm -rf "${BUILD_DIR}"
}

cmd_build() {
  mkdir -p "${BUILD_DIR}"

  echo "=== Pulling pinned Retro68 image (cached if present) ==="
  docker pull "${RETRO68_IMAGE}" > /dev/null

  echo "=== Building hello_toolbox with Retro68 GCC ==="
  # We bind-mount $SCRIPT_DIR so the container sees:
  #   /spike/hello_toolbox.c       — our source
  #   /spike/build/                — output landing zone
  # The container builds inside /tmp/work to keep build artefacts off
  # the host (only the final .bin is copied back).
  docker run --rm \
    -v "${SCRIPT_DIR}:/spike" \
    --entrypoint /bin/bash \
    "${RETRO68_IMAGE}" \
    -c '
      set -euo pipefail
      mkdir -p /tmp/work
      cd /tmp/work
      cp /spike/hello_toolbox.c .

      cat > CMakeLists.txt <<EOF
cmake_minimum_required(VERSION 3.15)
project(HelloToolboxRetro68 C)

# add_application is the Retro68 CMake macro that drives the full
# pipeline: gcc → as → ld → Rez (jump table + CODE 0) → MakeAPPL →
# MacBinary II. Output: HelloToolboxRetro68.bin, a complete APPL.
add_application(HelloToolboxRetro68
  TYPE APPL
  CREATOR "????"
  hello_toolbox.c
)
EOF

      cmake . \
        -DCMAKE_TOOLCHAIN_FILE=/Retro68-build/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake \
        -DCMAKE_BUILD_TYPE=Release
      # Build the ALL target (no --target). The .bin is produced by the
      # implicit <name>_APPL custom target that add_application wires up;
      # building HelloToolboxRetro68 alone only produces .code.bin (the
      # partial MacBinary used by the cv-mac splice path).
      cmake --build .

      cp HelloToolboxRetro68.bin /spike/build/hello-toolbox-retro68.bin
    '

  local BIN="${BUILD_DIR}/hello-toolbox-retro68.bin"
  if [ ! -f "${BIN}" ]; then
    echo "FAIL: ${BIN} was not produced" >&2
    exit 1
  fi

  shasum -a 256 "${BIN}" | tee "${BUILD_DIR}/hello-toolbox-retro68.sha"

  echo ""
  echo "=== Built ==="
  echo "  ${BIN}"
  echo "  size: $(wc -c < "${BIN}") bytes"
  echo ""
  echo "Next step: inspect with python3 spike-pcc/inspect_macbinary.py ${BIN}"
}

case "${1:-build}" in
  build) cmd_build ;;
  clean) cmd_clean ;;
  *) echo "usage: $0 [build|clean]" >&2; exit 2 ;;
esac
