#!/usr/bin/env bash
#
# spike/demos/build-demo.sh — build any single-file Mac demo via the
# pinned Retro68 image. Same pattern as spike/build-retro68.sh, but
# parameterised by source path so we can build multiple demos without
# duplicating the script.
#
# Usage:
#   bash spike/demos/build-demo.sh <source.c> [<CamelCaseAppName>]
#
# Example:
#   bash spike/demos/build-demo.sh spike/demos/lines.c Lines
#
# Outputs:
#   spike/demos/build/<basename>.bin  — complete MacBinary II APPL
#   spike/demos/build/<basename>.sha  — SHA-256 provenance
#
# The app name (Retro68 CMake target) defaults to a Title-Cased version
# of the basename. CamelCase the app name explicitly if you want a
# specific Finder display name.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
RETRO68_IMAGE="ghcr.io/autc04/retro68@sha256:e8b6cc8ac3c0cf26dcb299d5396cc7055c102b6bc46b67e2df960453af8ae92b"

SRC="${1:?usage: $0 <source.c> [<CamelCaseAppName>]}"
if [ ! -f "${SRC}" ]; then
  echo "source not found: ${SRC}" >&2; exit 1
fi
SRC_ABS="$(cd "$(dirname "${SRC}")" && pwd)/$(basename "${SRC}")"
BASENAME="$(basename "${SRC}" .c)"
APPNAME="${2:-${BASENAME^}}"   # default: capitalise first letter (bash 4)

mkdir -p "${BUILD_DIR}"
echo "=== Building ${SRC} as ${APPNAME} ==="
docker pull "${RETRO68_IMAGE}" > /dev/null

docker run --rm \
  -v "${SCRIPT_DIR}:/spike-demos" \
  -v "$(dirname "${SRC_ABS}"):/src" \
  --entrypoint /bin/bash \
  "${RETRO68_IMAGE}" \
  -c "
    set -euo pipefail
    mkdir -p /tmp/work && cd /tmp/work
    cp /src/$(basename "${SRC_ABS}") .

    cat > CMakeLists.txt <<EOF
cmake_minimum_required(VERSION 3.15)
project(${APPNAME} C)
add_application(${APPNAME}
  TYPE APPL
  CREATOR \"????\"
  $(basename "${SRC_ABS}")
)
EOF

    cmake . \\
      -DCMAKE_TOOLCHAIN_FILE=/Retro68-build/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake \\
      -DCMAKE_BUILD_TYPE=Release
    cmake --build .
    cp ${APPNAME}.bin /spike-demos/build/${BASENAME}.bin
  "

BIN="${BUILD_DIR}/${BASENAME}.bin"
if [ ! -f "${BIN}" ]; then
  echo "FAIL: ${BIN} was not produced" >&2; exit 1
fi
shasum -a 256 "${BIN}" | tee "${BUILD_DIR}/${BASENAME}.sha"
echo "=== Built ${BIN}  ($(wc -c < "${BIN}") bytes) ==="
