#!/usr/bin/env bash
#
# spike/wasm-binutils/build.sh — Phase 2.2 (`as`) + 2.3 (`ld`) port.
#
# Mirrors spike/wasm-cc1/build.sh structure. Uses the same Docker
# image (built by `bash spike/wasm-cc1/build.sh image`); shared
# CONFIG_SITE answers; same iteration patterns.
#
# Usage:
#   bash spike/wasm-binutils/build.sh stage1   # native (gen* + headers)
#   bash spike/wasm-binutils/build.sh stage2   # wasm canadian cross
#   bash spike/wasm-binutils/build.sh relink   # wasm flags for as/ld
#   bash spike/wasm-binutils/build.sh smoke    # as --version
#   bash spike/wasm-binutils/build.sh clean

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
STAGE1_DIR="${BUILD_DIR}/stage1"
STAGE2_DIR="${BUILD_DIR}/stage2"
IMAGE_TAG="wasm-retro-cc/phase2-1-builder:latest"

run_in_container() {
  local cmd="$1"
  docker run --rm \
    -v "${SCRIPT_DIR}:/spike" \
    -e EMSDK=/opt/emsdk \
    -e PATH=/opt/emsdk:/opt/emsdk/upstream/emscripten:/opt/emsdk/upstream/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --entrypoint /bin/bash \
    "${IMAGE_TAG}" \
    -c "${cmd}"
}

check_image() {
  if ! docker image inspect "${IMAGE_TAG}" > /dev/null 2>&1; then
    echo "ERROR: image ${IMAGE_TAG} not built." >&2
    echo "       Run: bash spike/wasm-cc1/build.sh image" >&2
    exit 1
  fi
}

cmd_stage1() {
  check_image
  mkdir -p "${STAGE1_DIR}"

  echo "[stage1] configuring native binutils (target=m68k-apple-macos)"
  run_in_container "
    set -euo pipefail
    cd /spike/build/stage1
    if [ ! -f Makefile ]; then
      /Retro68/binutils/configure \\
        --target=m68k-apple-macos \\
        --disable-gold \\
        --disable-werror \\
        --disable-nls \\
        --disable-multilib \\
        --without-zstd \\
        --prefix=/spike/build/stage1/install \\
        2>&1 | tee configure.log
    fi
    echo '[stage1] building native (this is the long step)'
    make -j\"\$(nproc)\" all-gas all-ld all-libiberty all-libctf 2>&1 | tee build.log | tail -30
    echo '[stage1] as size:'
    ls -lh gas/as-new 2>/dev/null && cp gas/as-new gas/as
    ls -lh ld/ld-new 2>/dev/null && cp ld/ld-new ld/ld
  "
}

cmd_stage2() {
  if [ ! -f "${STAGE1_DIR}/gas/as-new" ]; then
    echo "stage 2 needs stage 1 outputs — run 'stage1' first" >&2
    exit 1
  fi
  check_image
  mkdir -p "${STAGE2_DIR}"

  # Reuse the same config.site as cc1's Phase 2.1 work — answers
  # apply to libiberty regardless of which top-level source tree
  # pulls it in.
  cat > "${STAGE2_DIR}/config.site" <<'SITE'
ac_cv_func_fork=no
ac_cv_func_vfork=no
ac_cv_func_kill=no
ac_cv_func_pipe=no
ac_cv_func_dup2=yes
ac_cv_func_mmap=yes
ac_cv_func_setjmp=yes
ac_cv_func_longjmp=yes
ac_cv_func_sigaction=no
ac_cv_func_sigsetmask=no
ac_cv_func_wait4=no
ac_cv_func_waitpid=no
ac_cv_func_psignal=yes
ac_cv_have_decl_psignal=yes
SITE

  echo "[stage2] configuring canadian cross (build=auto, host=wasm32-emscripten, target=m68k-apple-macos)"
  run_in_container "
    set -euo pipefail
    cd /spike/build/stage2

    if [ ! -f Makefile ]; then
      BUILD_TRIPLE=\$(/Retro68/binutils/config.guess)
      echo \"[stage2] build triple: \${BUILD_TRIPLE}\"
      CXXFLAGS=\"-Dwait4=__syscall_wait4 -Os -g0\" \\
      CFLAGS=\"-Dwait4=__syscall_wait4 -Os -g0\" \\
      CONFIG_SITE=/spike/build/stage2/config.site \\
      emconfigure /Retro68/binutils/configure \\
        --build=\${BUILD_TRIPLE} \\
        --host=wasm32-unknown-emscripten \\
        --target=m68k-apple-macos \\
        --disable-gold \\
        --disable-werror \\
        --disable-nls \\
        --disable-multilib \\
        --disable-shared \\
        --disable-threads \\
        --without-zstd \\
        --prefix=/spike/build/stage2/install \\
        2>&1 | tee configure.log | tail -100
    fi

    echo '[stage2] building as + ld with emmake (-k so unrelated tool failures do not kill our targets)'
    export CONFIG_SITE=/spike/build/stage2/config.site
    emmake make -k -j\"\$(nproc)\" all-gas all-ld 2>&1 | tee build.log | tail -50
    # Per Phase 2.1 pattern, do not trust make exit code; check artefacts.
    true
  "
}

cmd_relink() {
  if [ ! -d "${STAGE2_DIR}/gas" ]; then
    echo "relink needs stage 2 outputs — run 'stage2' first" >&2
    exit 1
  fi
  echo "[relink] producing as.mjs / ld.mjs with wasm-aware flags"
  # Strategy: capture the real link command from \`make V=1\`, append
  # our wasm flags, redirect output to .mjs. Hardcoded .o lists drift
  # against binutils' makefile reality (different names, different
  # libraries, different orders); using make as source of truth is
  # the only robust path.
  run_in_container "
    set -euo pipefail

    LDFLAGS_WASM='-sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=1GB -sINITIAL_MEMORY=128MB -sSUPPORT_LONGJMP=wasm -sLLD_REPORT_UNDEFINED=1 -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORTED_FUNCTIONS=_main,_malloc,_free -sEXPORTED_RUNTIME_METHODS=FS,ERRNO_CODES,NODEFS,allocateUTF8,callMain -lnodefs.js'
    export CONFIG_SITE=/spike/build/stage2/config.site

    # as relink
    cd /spike/build/stage2/gas
    rm -f as-new as-new.wasm
    AS_LINK=\$(emmake make V=1 as-new 2>&1 | grep -E '^libtool: link: /opt/emsdk' | tail -1 | sed -e 's/^libtool: link: //')
    if [ -n \"\$AS_LINK\" ]; then
      echo '[relink] as link cmd captured; patching for wasm flags'
      AS_LINK_PATCHED=\$(echo \"\$AS_LINK\" | sed -e 's/-o as-new /-o as.mjs /g')
      eval \"\$AS_LINK_PATCHED \$LDFLAGS_WASM -sEXPORT_NAME=createAS\" 2>&1 | tail -10
    else
      echo '[relink] FAIL: could not capture as link command'
    fi

    # ld relink
    cd /spike/build/stage2/ld
    rm -f ld-new ld-new.wasm
    LD_LINK=\$(emmake make V=1 ld-new 2>&1 | grep -E '^libtool: link: /opt/emsdk' | tail -1 | sed -e 's/^libtool: link: //')
    if [ -n \"\$LD_LINK\" ]; then
      echo '[relink] ld link cmd captured; patching for wasm flags'
      LD_LINK_PATCHED=\$(echo \"\$LD_LINK\" | sed -e 's/-o ld-new /-o ld.mjs /g')
      eval \"\$LD_LINK_PATCHED \$LDFLAGS_WASM -sEXPORT_NAME=createLD\" 2>&1 | tail -10
    else
      echo '[relink] FAIL: could not capture ld link command'
    fi
  "

  echo '[relink] outputs:'
  ls -lh "${STAGE2_DIR}/gas/as.mjs" "${STAGE2_DIR}/gas/as.wasm" 2>/dev/null || echo '  (no as.mjs)'
  ls -lh "${STAGE2_DIR}/ld/ld.mjs" "${STAGE2_DIR}/ld/ld.wasm" 2>/dev/null || echo '  (no ld.mjs)'
}

cmd_smoke() {
  if [ ! -f "${STAGE2_DIR}/gas/as.mjs" ]; then
    echo "smoke needs ${STAGE2_DIR}/gas/as.mjs — run 'relink' first" >&2
    exit 1
  fi
  echo "[smoke] loading as.mjs and calling main(['--version'])"
  cd "${STAGE2_DIR}/gas"
  node --input-type=module -e "
    import('./as.mjs').then(async (mod) => {
      const Module = await mod.default({
        print: (s) => console.log('[as]', s),
        printErr: (s) => console.error('[as err]', s),
        noInitialRun: true,
      });
      try {
        const rc = Module.callMain(['--version']);
        console.log('[smoke] exit code:', rc);
      } catch (e) {
        if (e.name === 'ExitStatus') {
          console.log('[smoke] exit:', e.status);
          process.exit(e.status);
        }
        throw e;
      }
    });
  "
}

cmd_clean() {
  rm -rf "${BUILD_DIR}"
}

case "${1:-stage1}" in
  stage1) cmd_stage1 ;;
  stage2) cmd_stage2 ;;
  relink) cmd_relink ;;
  smoke)  cmd_smoke ;;
  clean)  cmd_clean ;;
  *) echo "usage: $0 [stage1|stage2|relink|smoke|clean]" >&2; exit 2 ;;
esac
