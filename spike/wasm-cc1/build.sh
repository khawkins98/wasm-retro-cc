#!/usr/bin/env bash
#
# spike/wasm-cc1/build.sh — Phase 2.1 cc1 → WASM build.
#
# Stage 1 (native, x86_64-linux-gnu): standard Retro68 cross-cc1 build.
#   • Confirms the source tree builds at all
#   • Produces generated headers (insn-*.h, tm.h) and build-time tools
#     (gen*, build-*) that stage 2 reuses via --with-build-time-tools
#
# Stage 2 (canadian, build=x86_64 host=wasm32-emscripten target=m68k):
#   • emconfigure with --disable-bootstrap (impossible to bootstrap a
#     wasm-host compiler from inside itself)
#   • emmake all-gcc to build just cc1 (skip libgcc/libstdc++/libssp)
#
# Smoke test: load cc1.mjs from Node, invoke --version. Phase 2.1 is
# "done" when this exits 0 with version output — MEMFS pipe-through is
# the follow-up sub-spike.
#
# Usage:
#   bash spike/wasm-cc1/build.sh             # full pipeline
#   bash spike/wasm-cc1/build.sh stage1      # native only
#   bash spike/wasm-cc1/build.sh stage2      # wasm cross only (needs stage1)
#   bash spike/wasm-cc1/build.sh smoke       # smoke test only
#   bash spike/wasm-cc1/build.sh clean       # remove build/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
STAGE1_DIR="${BUILD_DIR}/stage1"
STAGE2_DIR="${BUILD_DIR}/stage2"
IMAGE_TAG="wasm-retro-cc/phase2-1-builder:latest"

# Run a command inside the build container with the spike dir mounted
# at /spike (mirroring the Dockerfile's WORKDIR). All stage-1 / stage-2
# artefacts land back on the host under build/ via that mount.
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

cmd_image() {
  if docker image inspect "${IMAGE_TAG}" > /dev/null 2>&1; then
    echo "[image] cached ${IMAGE_TAG}"
  else
    echo "[image] building ${IMAGE_TAG} (this takes 20–40 minutes on first run)"
    docker build -t "${IMAGE_TAG}" -f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"
  fi
}

# ── Stage 1: native m68k-apple-macos cross build ──────────────────
# We DON'T need the full Retro68 toolchain at runtime — only the GCC
# build outputs (generated headers + build-time tools). The
# `make all-gcc` target stops short of libgcc, which is fine because
# stage 2 will rebuild gcc anyway. Stage 1 exists purely to:
#   (a) prove the source tree builds clean (catches Retro68 patch
#       conflicts before we throw Emscripten into the mix)
#   (b) populate $STAGE1_DIR/gcc/build/ with gen* tools that stage 2
#       feeds in via --with-build-time-tools
cmd_stage1() {
  cmd_image
  mkdir -p "${STAGE1_DIR}"

  echo "[stage1] configuring native cross (build=host=x86_64-linux-gnu, target=m68k-apple-macos)"
  run_in_container "
    set -euo pipefail
    cd /spike/build/stage1
    if [ ! -f Makefile ]; then
      /Retro68/gcc/configure \\
        --target=m68k-apple-macos \\
        --enable-languages=c \\
        --disable-bootstrap \\
        --disable-libssp \\
        --disable-libstdcxx \\
        --disable-libquadmath \\
        --disable-shared \\
        --disable-threads \\
        --disable-nls \\
        --disable-multilib \\
        --disable-checking \\
        --without-headers \\
        --without-isl \\
        --prefix=/spike/build/stage1/install \\
        2>&1 | tee configure.log
    fi
    echo '[stage1] building all-gcc (this is the long step)'
    make all-gcc -j\"\$(nproc)\" 2>&1 | tee build.log | tail -50
    echo '[stage1] cc1 size:'
    ls -lh gcc/cc1
  "
}

# ── Stage 2: canadian cross (host=wasm32-emscripten) ──────────────
# This is the load-bearing experiment. emconfigure tells autoconf to
# treat emcc as the host compiler; the long-tail of AC_CHECK_FUNCS
# probes is pre-answered via config.cache to dodge bogus wasm-ld link
# probes (see README landmine #1).
cmd_stage2() {
  if [ ! -f "${STAGE1_DIR}/gcc/cc1" ]; then
    echo "stage 2 needs stage 1 outputs at ${STAGE1_DIR}/gcc/cc1 — run 'stage1' first" >&2
    exit 1
  fi
  cmd_image
  mkdir -p "${STAGE2_DIR}"

  # Pre-populate a config.site with the answers we know are correct
  # for a no-fork no-exec wasm32 host. These probes otherwise fail
  # silently or get the wrong answer.
  #
  # WHY config.site, not --cache-file: GCC's top-level configure is
  # passed --cache-file, but sub-configures (libiberty/, libcpp/,
  # gcc/...) each run their own configure inside `make all-gcc` and
  # do NOT reliably inherit the parent's cache. CONFIG_SITE is read
  # by every autoconf-generated configure regardless of nesting —
  # the only reliable injection point. Confirmed by attempt 3
  # (psignal): top-level configure honoured the cache, libiberty's
  # sub-configure did not, same conflict recurred.
  #
  # Pattern: emscripten declares some POSIX function in its sysroot
  # headers but doesn't link it (or links an ENOSYS stub). Autoconf
  # link probe answers "no" → libiberty defines its own replacement
  # → compilation sees both declarations → error. Force "yes" for
  # the conflict-prone ones so libiberty skips its replacement.
  #
  # Belt-and-braces with -Dwait4=__syscall_wait4 in CFLAGS below.
  # Source: Emception build-llvm.sh + their issue #2.
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

  echo "[stage2] configuring canadian cross"
  run_in_container "
    set -euo pipefail
    cd /spike/build/stage2

    # GCC depends on GMP/MPFR/MPC at build time. Stage 1 found them on
    # the apt-installed host paths; stage 2 (host=wasm32-emscripten)
    # can't reuse those — they need to be wasm-compiled in-tree. GCC
    # ships contrib/download_prerequisites for exactly this — drops
    # GMP/MPFR/MPC/ISL source tarballs into the GCC src tree, and
    # configure picks them up automatically. Idempotent (skips on
    # re-run if symlinks present).
    if [ ! -d /Retro68/gcc/gmp ]; then
      echo '[stage2] downloading GMP/MPFR/MPC prerequisites'
      (cd /Retro68/gcc && ./contrib/download_prerequisites)
    fi

    # The bundled config.sub in GMP/MPFR/MPC predates wasm32 support
    # and rejects \`wasm32-unknown-emscripten\` with
    #   Invalid configuration \`wasm32-unknown-emscripten':
    #   system \`emscripten' not recognized
    # GCC's own config.sub (timestamp 2021-10-27 in our tree) knows
    # the triplet. Overwrite each prerequisite's autoconf helpers
    # with the GCC tree's newer copies. Idempotent.
    echo '[stage2] patching prerequisite config.sub/config.guess for wasm32'
    for sub in gmp mpfr mpc isl; do
      if [ -d /Retro68/gcc/\$sub ]; then
        cp /Retro68/gcc/config.sub   /Retro68/gcc/\$sub/config.sub   2>/dev/null || true
        cp /Retro68/gcc/config.guess /Retro68/gcc/\$sub/config.guess 2>/dev/null || true
      fi
    done

    if [ ! -f Makefile ]; then
      # emconfigure flips CC/CXX/AR/RANLIB to emcc/em++/emar/emranlib
      # and adjusts host detection so wasm32-unknown-emscripten is
      # accepted. The --cache-file feeds our pre-seeded answers in.
      #
      # Build triple: use config.guess so this script works on any host
      # (arm64 macOS via Docker → linux/aarch64, x86_64 native, etc).
      # Hard-coding x86_64-linux-gnu broke on Apple Silicon hosts.
      #
      # CXXFLAGS=-Dwait4=__syscall_wait4: see config.cache comment
      # above. Belt-and-braces — config.cache prevents detection;
      # the define repaints any direct references.
      BUILD_TRIPLE=\$(/Retro68/gcc/config.guess)
      echo \"[stage2] build triple: \${BUILD_TRIPLE}\"
      # CFLAGS/CXXFLAGS rationale:
      # -Dwait4=__syscall_wait4 — see config.site notes; emscripten
      #   renamed wait4 between 2.0.31 and 2.0.32.
      # -Os — optimize for size. The default GCC config emits -O2 -g
      #   for stage 2; an unstripped -O2 cc1.wasm came out at 58 MB
      #   in iteration 7, which OOM'd wasm-emscripten-finalize on a
      #   7.75 GB Docker host (finalize spikes to 10+ GB on huge
      #   wasms). -Os shrinks both object files and the final binary.
      # -g0 — no debug info. Strips ~70% of the wasm size; matches
      #   our Phase 2.4 size target (3-5 MB brotli) trajectory.
      CXXFLAGS=\"-Dwait4=__syscall_wait4 -Os -g0\" \\
      CFLAGS=\"-Dwait4=__syscall_wait4 -Os -g0\" \\
      CONFIG_SITE=/spike/build/stage2/config.site \\
      emconfigure /Retro68/gcc/configure \\
        --build=\${BUILD_TRIPLE} \\
        --host=wasm32-unknown-emscripten \\
        --target=m68k-apple-macos \\
        --enable-languages=c \\
        --disable-bootstrap \\
        --disable-libssp \\
        --disable-libstdcxx \\
        --disable-libgcc \\
        --disable-libquadmath \\
        --disable-shared \\
        --disable-threads \\
        --disable-nls \\
        --disable-multilib \\
        --disable-checking \\
        --without-headers \\
        --without-isl \\
        --with-build-time-tools=/spike/build/stage1/gcc/build \\
        --prefix=/spike/build/stage2/install \\
        2>&1 | tee configure.log | tail -100
    fi

    echo '[stage2] building cc1 with emmake (sub-makes inherit CONFIG_SITE)'
    export CONFIG_SITE=/spike/build/stage2/config.site

    # First: build all the prereq libraries (libiberty/libcpp/etc) via
    # all-gcc up to but stopping at the GCC subdir. Then build just
    # cc1 inside gcc/ — this skips gcov-tool, lto1, collect2 et al
    # whose link phases pull in POSIX symbols (ftw, etc.) that
    # emscripten lacks. cc1 is the only artefact Phase 2.1 targets.
    #
    # We run all-libiberty, all-libcpp, etc. first as separate targets
    # rather than \`make cc1\` from clean, because make all-gcc -j was
    # mid-flight when gcov-tool failed; some intermediate state may
    # be inconsistent. Building each lib explicitly ensures order.
    # Emscripten link flags for the final cc1.mjs:
    #   - ALLOW_MEMORY_GROWTH=1     GC heap can grow
    #   - MAXIMUM_MEMORY=1GB        cap below wasm32 2 GB ceiling
    #   - SUPPORT_LONGJMP=wasm      native EH; smaller + faster than JS
    #   - LLD_REPORT_UNDEFINED=1    loud link failure; else dangling
    #                               imports trap at instantiation only
    #                               (Emception build-llvm.sh:51)
    #   - MODULARIZE/EXPORT_ES6     ES module loader for the JS host
    #   - EXPORTED_RUNTIME=FS,…     MEMFS access + readable ERRNO_CODES
    #                               (else every MEMFS bug is numeric)
    export LDFLAGS=\"-sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=1GB -sSUPPORT_LONGJMP=wasm -sLLD_REPORT_UNDEFINED=1 -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORTED_FUNCTIONS=_main,_malloc,_free -sEXPORTED_RUNTIME_METHODS=FS,ERRNO_CODES,allocateUTF8,callMain -o cc1.mjs\"

    # Build all-gcc with -k so gcov-tool's failure (undefined ftw — see
    # iteration 5 in LEARNINGS.md) doesn't abort cc1's link. With -k,
    # make completes every target it can; cc1 is independent of
    # gcov-tool. We then verify cc1.wasm / cc1.mjs appeared explicitly
    # rather than trusting make's exit code.
    #
    # Initial attempt was \`make -C gcc cc1\` but the gcc/ subdir's
    # Makefile isn't generated until the parent make recurses into it
    # — we'd need to bootstrap via all-prereqs first. -k is simpler
    # and gets the same result.
    emmake make all-gcc -k -j\"\$(nproc)\" 2>&1 | tee build.log | tail -50
    # Don't `set -e` past this — make exited non-zero because of
    # gcov-tool, but cc1 may have built.
    true

    echo '[stage2] outputs:'
    ls -lh gcc/cc1.mjs gcc/cc1.wasm 2>/dev/null || echo '(cc1.mjs/wasm not produced — see build.log)'
  "

  if [ -f "${STAGE2_DIR}/gcc/cc1.wasm" ]; then
    shasum -a 256 "${STAGE2_DIR}/gcc/cc1.wasm" | tee "${STAGE2_DIR}/gcc/cc1.sha"
    echo "[stage2] brotli-compressed size:"
    brotli -k "${STAGE2_DIR}/gcc/cc1.wasm" && ls -lh "${STAGE2_DIR}/gcc/cc1.wasm.br"
  fi
}

# ── Smoke test: does cc1.mjs load and run --version? ──────────────
cmd_smoke() {
  if [ ! -f "${STAGE2_DIR}/gcc/cc1.mjs" ]; then
    echo "smoke test needs ${STAGE2_DIR}/gcc/cc1.mjs — run 'stage2' first" >&2
    exit 1
  fi
  echo "[smoke] loading cc1.mjs and calling main(['--version'])"
  cd "${STAGE2_DIR}/gcc"
  node --input-type=module -e "
    import('./cc1.mjs').then(async (mod) => {
      const Module = await mod.default({
        print: (s) => console.log('[cc1 stdout]', s),
        printErr: (s) => console.error('[cc1 stderr]', s),
        noInitialRun: true,
      });
      const rc = Module.callMain(['--version']);
      console.log('[smoke] exit code:', rc);
      process.exit(rc);
    }).catch((e) => { console.error('[smoke] FAIL:', e); process.exit(1); });
  "
}

cmd_clean() {
  echo "[clean] removing ${BUILD_DIR}"
  rm -rf "${BUILD_DIR}"
}

# ── Relink: produce cc1.mjs with proper Emscripten wasm flags ─────
# GCC's Makefile builds cc1 with `emcc -o cc1` — emcc treats no-extension
# output as Emscripten's classic non-modularized JS + cc1.wasm. Our
# LDFLAGS (MODULARIZE, EXPORT_ES6, ALLOW_MEMORY_GROWTH, etc.) do not
# propagate through GCC's link rule. Manual smoke test of the GCC-
# built cc1 aborted with OOM on Module init because the default 16 MB
# initial heap can't even bootstrap GCC's globals.
#
# This step takes the .o files Stage 2 produced and re-links them with
# the right wasm flags. Result: cc1.mjs (ES module loader) + cc1.wasm
# (wasm binary, may be the same as Stage 2's depending on optimization).
cmd_relink() {
  if [ ! -f "${STAGE2_DIR}/gcc/cc1.wasm" ]; then
    echo "relink needs stage2 outputs — run 'stage2' first" >&2
    exit 1
  fi

  echo "[relink] producing cc1.mjs with wasm-aware Emscripten flags"
  run_in_container "
    set -euo pipefail
    cd /spike/build/stage2/gcc

    # Same object-file list as the cc1 link rule in gcc/Makefile.in.
    # If the makefile changes, this list needs to track it — we accept
    # that brittleness as the price for getting the wasm flags right.
    em++ -Os -g0 \\
      -sALLOW_MEMORY_GROWTH=1 \\
      -sMAXIMUM_MEMORY=1GB \\
      -sINITIAL_MEMORY=128MB \\
      -sSUPPORT_LONGJMP=wasm \\
      -sLLD_REPORT_UNDEFINED=1 \\
      -sMODULARIZE=1 \\
      -sEXPORT_ES6=1 \\
      -sEXPORT_NAME=createCC1 \\
      -sEXPORTED_FUNCTIONS=_main,_malloc,_free \\
      -sEXPORTED_RUNTIME_METHODS=FS,ERRNO_CODES,NODEFS,allocateUTF8,callMain \\
      -lnodefs.js \\
      -o cc1.mjs \\
      c/c-lang.o c-family/stub-objc.o attribs.o c/c-errors.o c/c-decl.o \\
      c/c-typeck.o c/c-convert.o c/c-aux-info.o c/c-objc-common.o \\
      c/c-parser.o c/c-fold.o c/gimple-parser.o c-family/c-common.o \\
      c-family/c-cppbuiltin.o c-family/c-dump.o c-family/c-format.o \\
      c-family/c-gimplify.o c-family/c-indentation.o c-family/c-lex.o \\
      c-family/c-omp.o c-family/c-opts.o c-family/c-pch.o \\
      c-family/c-ppoutput.o c-family/c-pragma.o c-family/c-pretty-print.o \\
      c-family/c-semantics.o c-family/c-ada-spec.o c-family/c-ubsan.o \\
      c-family/known-headers.o c-family/c-attribs.o c-family/c-warn.o \\
      c-family/c-spellcheck.o m68k-mac-pragmas.o default-c.o \\
      cc1-checksum.o libbackend.a main.o libcommon-target.a libcommon.a \\
      ../libcpp/libcpp.a ../libdecnumber/libdecnumber.a \\
      ../libbacktrace/.libs/libbacktrace.a ../libiberty/libiberty.a \\
      -L/spike/build/stage2/./gmp/.libs \\
      -L/spike/build/stage2/./mpfr/src/.libs \\
      -L/spike/build/stage2/./mpc/src/.libs \\
      -lmpc -lmpfr -lgmp \\
      -L./../zlib -lz 2>&1 | tail -30
  "

  if [ -f "${STAGE2_DIR}/gcc/cc1.mjs" ]; then
    shasum -a 256 "${STAGE2_DIR}/gcc/cc1.wasm" | tee "${STAGE2_DIR}/gcc/cc1.sha"
    echo "[relink] cc1.mjs + cc1.wasm built:"
    ls -lh "${STAGE2_DIR}/gcc/cc1.mjs" "${STAGE2_DIR}/gcc/cc1.wasm"
    echo "[relink] brotli size:"
    brotli -k -f "${STAGE2_DIR}/gcc/cc1.wasm" && ls -lh "${STAGE2_DIR}/gcc/cc1.wasm.br"
  else
    echo "[relink] FAIL: cc1.mjs not produced"
    exit 1
  fi
}

case "${1:-all}" in
  image)  cmd_image ;;
  stage1) cmd_stage1 ;;
  stage2) cmd_stage2 ;;
  relink) cmd_relink ;;
  smoke)  cmd_smoke ;;
  clean)  cmd_clean ;;
  all)    cmd_image && cmd_stage1 && cmd_stage2 && cmd_relink && cmd_smoke ;;
  *) echo "usage: $0 [image|stage1|stage2|relink|smoke|clean|all]" >&2; exit 2 ;;
esac
