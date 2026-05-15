#!/bin/bash
# Inner script for cmd_libelf — runs inside the wasm-retro-cc builder
# container. Separated from build.sh so we don't fight heredoc quoting.
set -euo pipefail

ELFUTILS_VERSION="${ELFUTILS_VERSION:-0.190}"

cd /spike/build/libelf

if [ ! -d "elfutils-${ELFUTILS_VERSION}" ]; then
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    autoconf automake libtool m4 \
    pkg-config zlib1g-dev liblzma-dev libzstd-dev \
    gawk gettext > /dev/null 2>&1
  curl -sL "https://sourceware.org/elfutils/ftp/${ELFUTILS_VERSION}/elfutils-${ELFUTILS_VERSION}.tar.bz2" | tar -xj
fi

cd "elfutils-${ELFUTILS_VERSION}"

if [ ! -f Makefile ]; then
  # Find config.guess — sometimes top-level, sometimes config/.
  CONFIG_GUESS=$(find . -maxdepth 2 -name config.guess | head -1)
  if [ -z "$CONFIG_GUESS" ]; then
    echo "ERROR: cannot find config.guess" >&2
    find . -name '*.guess' 2>&1 | head
    exit 1
  fi
  BUILD_TRIPLE=$(bash "$CONFIG_GUESS")
  echo "[libelf] build triple: ${BUILD_TRIPLE}"
  echo "[libelf] using config.guess: ${CONFIG_GUESS}"

  # -sUSE_ZLIB=1 pulls in Emscripten's zlib port. Required by elfutils
  # at configure time (gzdirect link probe).
  # -Wno-error because elfutils builds with -Werror by default and emcc
  # is noisier than gcc; we accept the warnings.
  export CFLAGS="-Os -g0 -Wno-error -Dwait4=__syscall_wait4 -sUSE_ZLIB=1"
  export CPPFLAGS="-Dwait4=__syscall_wait4"

  emconfigure ./configure \
    --build="${BUILD_TRIPLE}" \
    --host=wasm32-unknown-emscripten \
    --disable-shared \
    --disable-nls \
    --disable-debuginfod \
    --disable-libdebuginfod \
    --disable-symbol-versioning \
    --without-zstd \
    --without-lzma \
    --prefix=/spike/build/libelf/install \
    2>&1 | tee /spike/build/libelf/configure.log | tail -40
fi

echo "[libelf] building libelf only"
emmake make -k -j"$(nproc)" -C libelf 2>&1 | tee /spike/build/libelf/build.log | tail -30
ls -lh libelf/libelf.a 2>&1 || echo "(no libelf.a)"
