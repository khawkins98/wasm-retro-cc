#!/usr/bin/env bash
# spike/run-spike.sh — Phase 0/1/2 feasibility script
#
# Tests the PCC m68k compilation pipeline through to MacBinary output.
#
# Phase 0: PCC compiles hello.c → m68k ELF (proves compiler works)
# Phase 1: Retro68 Elf2Mac links the ELF → MacBinary (proves full pipeline)
# Phase 2: Compile + link hello_toolbox.c with libtoolbox-stubs → MacBinary
#           (proves A-trap stubs bridge C cdecl → Mac ROM correctly)
#
# Usage:
#   bash spike/run-spike.sh setup            # extract Retro68 stubs from Docker, clone PCC
#   bash spike/run-spike.sh build-pcc        # build PCC for m68k code generation
#   bash spike/run-spike.sh compile          # Phase 0: compile hello.c with PCC → ELF
#   bash spike/run-spike.sh link             # Phase 1: link ELF → MacBinary via Elf2Mac
#   bash spike/run-spike.sh verify           # Phase 1: validate MacBinary header
#   bash spike/run-spike.sh build-stubs      # Phase 2: assemble libtoolbox-stubs.a
#   bash spike/run-spike.sh compile-toolbox  # Phase 2: compile hello_toolbox.c → ELF
#   bash spike/run-spike.sh link-toolbox     # Phase 2: link toolbox ELF → MacBinary
#   bash spike/run-spike.sh verify-toolbox   # Phase 2: validate toolbox MacBinary header
#   bash spike/run-spike.sh compare          # compare vs Retro68 reference (local only)
#   bash spike/run-spike.sh all              # run all phases end-to-end

set -euo pipefail
SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PCC_SRC="${SPIKE_DIR}/pcc-src"      # git clone of PCC goes here
STUBS_DIR="${SPIKE_DIR}/retro68-stubs"
HEADERS_DIR="${SPIKE_DIR}/retro68-headers"
BUILD_DIR="${SPIKE_DIR}/build"
PCC_PIN="05a6d549952fe7a401b30e87b6df907f6c0a4e88"
# Pinned by digest so Phase 0/1/2 are reproducible against the toolchain layout
# we fingerprinted. Update with care — `LEARNINGS.md` documents many path
# discoveries against this image.
RETRO68_IMAGE="ghcr.io/autc04/retro68@sha256:e8b6cc8ac3c0cf26dcb299d5396cc7055c102b6bc46b67e2df960453af8ae92b"

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
    echo "=== Cloning PCC (pinned to ${PCC_PIN}) ==="
    git clone https://github.com/IanHarvey/pcc "${PCC_SRC}"
    git -C "${PCC_SRC}" checkout "${PCC_PIN}"
  fi
}

# ── build-pcc ──────────────────────────────────────────────────────────────
cmd_build_pcc() {
  echo "=== Building PCC ccom for m68k code generation ==="
  if [ ! -d "${PCC_SRC}" ]; then
    echo "ERROR: ${PCC_SRC} not found — run 'bash spike/run-spike.sh setup' first" >&2
    exit 1
  fi
  pushd "${PCC_SRC}" > /dev/null

  # PCC's configure.ac maps target_os=apple → abi=classic68k → m68k backend.
  # config.sub (2015) treats 'apple' as a vendor alias (not OS) and rejects
  # the triple before configure.ac runs.  Pre-populate config.cache so
  # AC_CANONICAL_TARGET uses the cached values and skips config.sub.
  BUILD_TRIPLE=$(gcc -dumpmachine 2>/dev/null || echo "x86_64-unknown-linux-gnu")
  cat > config.cache << EOF
ac_cv_build=${BUILD_TRIPLE}
ac_cv_build_alias=${BUILD_TRIPLE}
ac_cv_host=${BUILD_TRIPLE}
ac_cv_host_alias=${BUILD_TRIPLE}
ac_cv_target=m68k-unknown-apple
ac_cv_target_alias=m68k-unknown-apple
EOF

  # Apply source patches (union flt → struct flt; USE_IEEEFP_*).
  # See spike/pcc.patch for the full rationale.  --reverse --check first so
  # re-running setup is idempotent (skips if already applied).
  if ! git apply --reverse --check "${SPIKE_DIR}/pcc.patch" 2>/dev/null; then
    git apply "${SPIKE_DIR}/pcc.patch"
    echo "Applied spike/pcc.patch"
  else
    echo "spike/pcc.patch already applied — skipping"
  fi

  ./configure --cache-file=config.cache --target=m68k-unknown-apple --disable-nativefp

  # GCC 10+ defaults to -fno-common: scan.l and common.c both declare
  # 'int lineno' as tentative definitions that used to merge; they now
  # conflict.  Restore the old behaviour for this vendored PCC build.
  sed -i 's/^CFLAGS = /CFLAGS = -fcommon /' cc/ccom/Makefile

  # Build only cc/ccom (the compiler proper).  The cc/cc driver wrapper
  # requires ccconfig.h which is not in the repo and not generated by
  # configure — we invoke ccom directly instead of via the driver.
  make -C cc/ccom -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
  popd > /dev/null
  echo "=== PCC ccom built ==="
}

# ── compile ────────────────────────────────────────────────────────────────
cmd_compile() {
  echo "=== Compiling hello.c with PCC ccom m68k backend ==="
  mkdir -p "${BUILD_DIR}"

  # Locate the ccom binary.  With BINPREFIX=m68k-unknown-apple-, the binary
  # is named m68k-unknown-apple-ccom (or just ccom in some builds).
  CCOM_BIN=$(find "${PCC_SRC}/cc/ccom" -name "*ccom" -type f 2>/dev/null | head -1)
  if [ -z "${CCOM_BIN}" ]; then
    echo "ERROR: ccom binary not found under ${PCC_SRC}/cc/ccom — did build-pcc succeed?"
    exit 1
  fi
  echo "Using ccom binary: ${CCOM_BIN}"

  # ccom is the compiler proper and expects preprocessed input.
  # Step 1: preprocess with the system C preprocessor.
  gcc -E \
    -I "${SPIKE_DIR}/../src/include" \
    "${SPIKE_DIR}/hello.c" \
    -o "${BUILD_DIR}/hello.i" \
    && echo "Preprocessing: OK" \
    || { echo "Preprocessing: FAILED"; exit 1; }

  # Step 2: compile preprocessed C to m68k assembly with PCC ccom.
  "${CCOM_BIN}" "${BUILD_DIR}/hello.i" "${BUILD_DIR}/hello.s" \
    && echo "PCC ccom compilation: OK" \
    || { echo "PCC ccom compilation: FAILED"; exit 1; }

  echo "--- Assembly output (first 60 lines) ---"
  head -60 "${BUILD_DIR}/hello.s"

  # Step 3: assemble the PCC output.
  # Use -m68020 because PCC emits 68020+ instructions (extb.l, muls.l, etc.).
  m68k-linux-gnu-as -m68020 -o "${BUILD_DIR}/hello.o" "${BUILD_DIR}/hello.s" \
    && echo "Assembly: OK" \
    || { echo "Assembly: FAILED (is m68k-linux-gnu-as installed?)"; exit 1; }

  # Step 4: assemble the minimal Phase 0 startup stub.
  m68k-linux-gnu-as -m68020 -o "${BUILD_DIR}/crt0_minimal.o" "${SPIKE_DIR}/crt0_minimal.s" \
    && echo "crt0 assembly: OK" \
    || { echo "crt0 assembly: FAILED"; exit 1; }

  # Step 5: link.
  # Phase 0 uses crt0_minimal.s (provides _start) instead of libretrocrt.a
  # to avoid undefined linker symbols from the full Retro68 CRT.
  # Phase 1 will link with libretrocrt.a + libc.a + libInterface.a.
  m68k-linux-gnu-ld \
    -m m68kelf \
    -T "${SPIKE_DIR}/mac.ld" \
    "${BUILD_DIR}/crt0_minimal.o" \
    "${BUILD_DIR}/hello.o" \
    -o "${BUILD_DIR}/hello.elf" \
    && echo "Linking: OK" \
    || { echo "Linking: FAILED — see symbol errors above"; exit 1; }

  echo "=== hello.elf produced at ${BUILD_DIR}/hello.elf ==="
}

# ── link ──────────────────────────────────────────────────────────────────
cmd_link() {
  echo "=== Phase 1: Linking hello.o → hello.bin via Retro68 Elf2Mac ==="

  # We invoke the m68k-apple-macos-ld symlink (which points to the Elf2Mac
  # binary) with the -elf2mac flag.  This is exactly what Retro68's GCC
  # specs do (gcc/config/m68k/m68k-macos.h LINK_SPEC) when add_application
  # builds a working Mac app.  The combination produces a multi-segment
  # MacBinary APPL with CODE 0 / CODE 1..N + DATA + RELA resources and a
  # properly-sized A5 world.
  #
  # Two things matter and are easy to miss:
  #
  # 1. argv[0] must be 'm68k-apple-macos-ld'.  Elf2Mac dispatches on argv[0]:
  #    invoked as the symlink it acts as a transparent ld wrapper and (with
  #    -elf2mac) generates the linker script libretrocrt needs.  Invoked
  #    directly as 'Elf2Mac' it skips that path; the real ld then fails
  #    with undefined references to _stext / _sdata / _sbss / __CTOR_LIST__
  #    and friends.
  # 2. The -elf2mac flag must be present.  Without it the ld symlink is a
  #    pure passthrough, no linker script is generated, and the link fails
  #    the same way.
  #
  # An earlier version of this spike used 'Elf2Mac --mac-single ...' directly.
  # That mode produces a minimal single-CODE-segment binary with below_a5=0
  # and no DATA / RELA resources, which is incompatible with libretrocrt:
  # Retro68Relocate's non-multiseg path never calls SetCurrentA5(), so the
  # below-A5 globals (qd, etc.) live in unallocated memory and the first
  # Toolbox call after InitGraf hits type 3 (illegal instruction).
  # Verified 2026-05-14 by boot-testing in classic-vibe-mac (BasiliskII
  # Quadra-650, System 7.5.5).  Source citations:
  # Retro68/Elf2Mac/Elf2Mac.cc:101, Object.cc:201-206, libretro/relocate.c:233-308.
  #
  # RETRO68_REAL_LD is no longer needed: when invoked as the symlink,
  # m68k-apple-macos-ld finds the real ld by appending ".real" to its own
  # path, which works automatically.
  #
  # Library order: see comments at the link command below.

  docker run --rm \
    -v "$(cd "${SPIKE_DIR}/.." && pwd)":/work \
    --entrypoint /bin/bash \
    "${RETRO68_IMAGE}" \
    -c "
      set -euo pipefail

      # Locate Elf2Mac and the real ld in the Docker image.
      # Known-good prefix from Phase 0 extraction: /Retro68-build/toolchain
      BINDIR=/Retro68-build/toolchain/bin
      # We invoke Elf2Mac via the m68k-apple-macos-ld symlink (which points to
      # the same binary).  Elf2Mac dispatches on argv[0]: invoked as
      # m68k-apple-macos-ld it acts as a transparent ld wrapper that, with
      # the -elf2mac flag, generates the multi-segment linker script defining
      # _stext / _sdata / _sbss / _ebss / __CTOR_LIST__ / __init_section / etc.
      # libretrocrt's startup needs.  Invoked as 'Elf2Mac' it skips that path
      # and the link fails with undefined references to those linker symbols.
      LD_BIN=\${BINDIR}/m68k-apple-macos-ld
      REAL_LD=\${BINDIR}/m68k-apple-macos-ld.real
      LIBDIR=/Retro68-build/toolchain/m68k-apple-macos/lib

      # Fall back to a full search if the expected paths aren't present.
      if [ ! -x \"\${LD_BIN}\" ]; then
        LD_BIN=\$(find /usr/local -name 'm68k-apple-macos-ld' -type f -o -name 'm68k-apple-macos-ld' -type l 2>/dev/null | head -1)
        BINDIR=\$(dirname \"\${LD_BIN}\")
        REAL_LD=\${BINDIR}/m68k-apple-macos-ld.real
        LIBDIR=\$(dirname \"\${BINDIR}\")/m68k-apple-macos/lib
      fi

      # Fail explicitly if required paths are missing.
      test -e \"\${LD_BIN}\"  || { echo \"FAIL: m68k-apple-macos-ld not found at \${LD_BIN}\"; exit 1; }
      test -x \"\${REAL_LD}\" || { echo \"FAIL: real ld not found at \${REAL_LD}\"; exit 1; }
      test -d \"\${LIBDIR}\"  || { echo \"FAIL: lib dir not found at \${LIBDIR}\"; exit 1; }

      # libgcc.a lives in GCC's private directory (lib/gcc/<target>/<ver>/), not LIBDIR.
      # Find it dynamically to avoid hardcoding the GCC version number.
      TOOLCHAIN_ROOT=\$(dirname \"\${BINDIR}\")
      GCC_LIBDIR=\$(find \"\${TOOLCHAIN_ROOT}/lib/gcc/m68k-apple-macos\" \
                    -name 'libgcc.a' -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
      if [ -z \"\${GCC_LIBDIR}\" ]; then
        GCC_LIBDIR=\$(find /usr/local/lib/gcc/m68k-apple-macos \
                      -name 'libgcc.a' -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
      fi
      test -n \"\${GCC_LIBDIR}\" || { echo \"FAIL: libgcc.a not found\"; exit 1; }

      echo \"LD       : \${LD_BIN}\"
      echo \"Real ld  : \${REAL_LD}\"
      echo \"Lib dir  : \${LIBDIR}\"
      echo \"GCC lib  : \${GCC_LIBDIR}\"

      # Diagnostic: confirm libInterface.a and libgcc.a export the symbols we need.
      echo \"=== lib diagnostics ===\"
      nm \"\${LIBDIR}/libInterface.a\" 2>/dev/null | grep ' T FSWRITE' | head -3 \
        && echo 'libInterface.a: FSWRITE found' \
        || echo 'libInterface.a: FSWRITE NOT found (may cause link failure)'
      nm \"\${GCC_LIBDIR}/libgcc.a\" 2>/dev/null | grep ' T __mulsi3' | head -1 \
        && echo 'libgcc.a: __mulsi3 found' \
        || echo 'libgcc.a: __mulsi3 NOT found'

      # Library deps with circular dependency between libretrocrt, libc, libInterface, libgcc:
      #   libretrocrt:  CRT startup (_start); malloc.c needs __mulsi3 (libgcc) + memcpy (libc);
      #                 syscalls.c needs Mac File Manager traps (libInterface) + __mulsi3.
      #   libc:         exit/atexit/memcpy/strcpy; exit() needs _exit (retrocrt — circular).
      #   libInterface: ALL Mac Toolbox A-trap stubs; required by libretrocrt/syscalls.c.
      #   libgcc:       soft-math helpers (__mulsi3, __udivsi3) from GCC private lib dir.
      #
      # --start-group/--end-group: instructs ld to repeatedly scan all archives in the group
      # until no new undefined symbols are resolved. This correctly handles:
      #   1. syscalls.c.obj extracted late (from 2nd retrocrt pass) needing FSWRITE/__mulsi3
      #   2. libc exit() needing _exit back from retrocrt
      # Without this, manually repeating -lretrocrt still fails because libInterface and
      # libgcc are processed BEFORE syscalls.c.obj is extracted by the second retrocrt pass.
      # -elf2mac activates the Elf2Mac code path inside m68k-apple-macos-ld
      # (a symlink to the Elf2Mac binary).  Without it, ld passes through as
      # plain binutils ld and the link fails with undefined references to
      # _stext / _sdata / _sbss / __CTOR_LIST__ / etc.  -q tells the real
      # ld to be quiet; -undefined=_consolewrite tells it _consolewrite (a
      # libretrocrt symbol) is allowed to be undefined.  These mirror
      # exactly what GCC's LINK_SPEC (gcc/config/m68k/m68k-macos.h) passes.
      \"\${LD_BIN}\" \
        -elf2mac -q -undefined=_consolewrite \
        -o /work/spike/build/hello.bin \
        /work/spike/build/hello.o \
        -L\"\${LIBDIR}\" \
        -L\"\${GCC_LIBDIR}\" \
        --start-group -lretrocrt -lc -lInterface -lgcc --end-group

      echo 'Link: OK'
    " \
    && echo "Phase 1 link: OK" \
    || { echo "Phase 1 link: FAILED"; exit 1; }

  echo "=== hello.bin produced at ${BUILD_DIR}/hello.bin ==="
  ls -lh "${BUILD_DIR}/hello.bin"
}

# ── verify ─────────────────────────────────────────────────────────────────
cmd_verify() {
  echo "=== Phase 1: Validating MacBinary structure ==="
  local BIN="${BUILD_DIR}/hello.bin"

  if [ ! -f "${BIN}" ]; then
    echo "FAIL: hello.bin not found — run 'link' first"
    exit 1
  fi

  # Delegate to inspect_macbinary.py — checks type=APPL, CODE 0+1, below_a5>0,
  # DATA, RELA.  The below_a5 / DATA / RELA checks are what catches a
  # --mac-single regression that would otherwise launch and crash with type 3.
  python3 "${SPIKE_DIR}/inspect_macbinary.py" "${BIN}"
}

# ── build-stubs ────────────────────────────────────────────────────────────
cmd_build_stubs() {
  echo "=== Phase 2: Assembling libtoolbox-stubs.a ==="
  local STUBS_S="${SPIKE_DIR}/../src/stubs/libtoolbox-stubs.s"
  local STUBS_O="${BUILD_DIR}/libtoolbox-stubs.o"
  local STUBS_A="${BUILD_DIR}/libtoolbox-stubs.a"

  mkdir -p "${BUILD_DIR}"
  [ -f "${STUBS_S}" ] || { echo "FAIL: ${STUBS_S} not found"; exit 1; }

  # Assemble with m68k-linux-gnu-as (same toolchain used for Phase 0/1).
  m68k-linux-gnu-as -m68020 "${STUBS_S}" -o "${STUBS_O}" \
    && echo "Assembled: OK" \
    || { echo "Assembly: FAILED"; exit 1; }

  # Archive into a static library.
  m68k-linux-gnu-ar rcs "${STUBS_A}" "${STUBS_O}" \
    && echo "Archived: ${STUBS_A}" \
    || { echo "Archive: FAILED"; exit 1; }

  echo "=== libtoolbox-stubs.a ready ==="
  m68k-linux-gnu-nm "${STUBS_A}" | grep " T " | awk '{print "  " $3}'
}

# ── compile-toolbox ─────────────────────────────────────────────────────────
cmd_compile_toolbox() {
  echo "=== Phase 2: Compiling hello_toolbox.c with PCC ccom m68k backend ==="
  local SRC="${SPIKE_DIR}/hello_toolbox.c"

  [ -f "${SRC}" ] || { echo "FAIL: ${SRC} not found"; exit 1; }

  # Locate ccom (same as cmd_compile).
  CCOM_BIN=$(find "${PCC_SRC}/cc/ccom" -name "*ccom" -type f 2>/dev/null | head -1)
  if [ -z "${CCOM_BIN}" ]; then
    echo "ERROR: ccom binary not found — did build-pcc succeed?"
    exit 1
  fi

  # Preprocess with the system C preprocessor.
  gcc -E \
    -I "${SPIKE_DIR}/../src/include" \
    "${SRC}" \
    -o "${BUILD_DIR}/hello_toolbox.i" \
    && echo "Preprocessing: OK" \
    || { echo "Preprocessing: FAILED"; exit 1; }

  # Compile to m68k assembly with PCC ccom.
  "${CCOM_BIN}" "${BUILD_DIR}/hello_toolbox.i" "${BUILD_DIR}/hello_toolbox.s" \
    && echo "PCC ccom compilation: OK" \
    || { echo "PCC ccom compilation: FAILED"; exit 1; }

  echo "--- Assembly output (first 60 lines) ---"
  head -60 "${BUILD_DIR}/hello_toolbox.s"

  # Assemble to ELF object.
  m68k-linux-gnu-as -m68020 \
    "${BUILD_DIR}/hello_toolbox.s" \
    -o "${BUILD_DIR}/hello_toolbox.o" \
    && echo "Assembly: OK" \
    || { echo "Assembly: FAILED"; exit 1; }

  echo "=== hello_toolbox.o produced ==="
  m68k-linux-gnu-nm "${BUILD_DIR}/hello_toolbox.o" | grep " [TU] " | head -20
}

# ── link-toolbox ────────────────────────────────────────────────────────────
cmd_link_toolbox() {
  echo "=== Phase 2: Linking hello_toolbox.o → hello_toolbox.bin via Elf2Mac ==="

  # Link order: toolbox stubs first (they resolve Toolbox references from hello_toolbox.o),
  # then retrocrt (_start, relocator), then libc (atexit/exit, called by retrocrt).
  docker run --rm \
    -v "$(cd "${SPIKE_DIR}/.." && pwd)":/work \
    --entrypoint /bin/bash \
    "${RETRO68_IMAGE}" \
    -c "
      set -euo pipefail

      BINDIR=/Retro68-build/toolchain/bin
      # See cmd_link for why we use the m68k-apple-macos-ld symlink and -elf2mac
      # rather than calling Elf2Mac directly: argv[0] selects the in-binary
      # code path that generates the linker script libretrocrt needs.
      LD_BIN=\${BINDIR}/m68k-apple-macos-ld
      REAL_LD=\${BINDIR}/m68k-apple-macos-ld.real
      LIBDIR=/Retro68-build/toolchain/m68k-apple-macos/lib

      if [ ! -x \"\${LD_BIN}\" ] && [ ! -L \"\${LD_BIN}\" ]; then
        LD_BIN=\$(find /usr/local -name 'm68k-apple-macos-ld' 2>/dev/null | head -1)
        BINDIR=\$(dirname \"\${LD_BIN}\")
        REAL_LD=\${BINDIR}/m68k-apple-macos-ld.real
        LIBDIR=\$(dirname \"\${BINDIR}\")/m68k-apple-macos/lib
      fi

      test -e \"\${LD_BIN}\"  || { echo \"FAIL: m68k-apple-macos-ld not found at \${LD_BIN}\"; exit 1; }
      test -x \"\${REAL_LD}\" || { echo \"FAIL: real ld not found at \${REAL_LD}\"; exit 1; }
      test -d \"\${LIBDIR}\"  || { echo \"FAIL: lib dir not found at \${LIBDIR}\"; exit 1; }

      TOOLCHAIN_ROOT=\$(dirname \"\${BINDIR}\")
      GCC_LIBDIR=\$(find \"\${TOOLCHAIN_ROOT}/lib/gcc/m68k-apple-macos\" \
                    -name 'libgcc.a' -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
      if [ -z \"\${GCC_LIBDIR}\" ]; then
        GCC_LIBDIR=\$(find /usr/local/lib/gcc/m68k-apple-macos \
                      -name 'libgcc.a' -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
      fi
      test -n \"\${GCC_LIBDIR}\" || { echo \"FAIL: libgcc.a not found\"; exit 1; }

      echo \"LD       : \${LD_BIN}\"
      echo \"Real ld  : \${REAL_LD}\"
      echo \"Lib dir  : \${LIBDIR}\"
      echo \"GCC lib  : \${GCC_LIBDIR}\"

      # libtoolbox-stubs.a is listed BEFORE -lInterface, but it is NOT a shadow:
      # libInterface.a contains only ~30 uppercase OS-level stubs (GESTALT, DELAY,
      # FSWRITE, etc.) — it does NOT define InitGraf / InitFonts / InitWindows /
      # MoveTo / DrawString / etc.  Our libtoolbox-stubs.a is the SOLE provider
      # for those Toolbox calls.  Interface still resolves the File Manager / OS
      # traps that libretrocrt's syscalls.c.obj needs.  Listing stubs first is
      # for ordering hygiene against future Interface contents, not because
      # there is a current symbol collision.
      # --start-group/--end-group handles circular deps between retrocrt/libc/Interface/libgcc.
      # -elf2mac selects Elf2Mac's multi-segment mode inside m68k-apple-macos-ld.
      # See cmd_link for the full rationale and Retro68 source citations.
      \"\${LD_BIN}\" \
        -elf2mac -q -undefined=_consolewrite \
        -o /work/spike/build/hello_toolbox.bin \
        /work/spike/build/hello_toolbox.o \
        /work/spike/build/libtoolbox-stubs.a \
        -L\"\${LIBDIR}\" \
        -L\"\${GCC_LIBDIR}\" \
        --start-group -lretrocrt -lc -lInterface -lgcc --end-group

      echo 'Link (toolbox): OK'
    " \
    && echo "Phase 2 link: OK" \
    || { echo "Phase 2 link: FAILED"; exit 1; }

  echo "=== hello_toolbox.bin produced ==="
  ls -lh "${BUILD_DIR}/hello_toolbox.bin"
}

# ── verify-toolbox ──────────────────────────────────────────────────────────
cmd_verify_toolbox() {
  echo "=== Phase 2: Validating hello_toolbox MacBinary structure ==="
  local BIN="${BUILD_DIR}/hello_toolbox.bin"

  if [ ! -f "${BIN}" ]; then
    echo "FAIL: hello_toolbox.bin not found — run 'link-toolbox' first"
    exit 1
  fi

  python3 "${SPIKE_DIR}/inspect_macbinary.py" "${BIN}"
}

# ── compare ───────────────────────────────────────────────────────────────
# NOTE: This command is NOT run in CI (spike.yml). It is provided for local
# comparison only. It requires Docker and that 'compile' has already run.
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
  setup)            cmd_setup ;;
  build-pcc)        cmd_build_pcc ;;
  compile)          cmd_compile ;;
  link)             cmd_link ;;
  verify)           cmd_verify ;;
  build-stubs)      cmd_build_stubs ;;
  compile-toolbox)  cmd_compile_toolbox ;;
  link-toolbox)     cmd_link_toolbox ;;
  verify-toolbox)   cmd_verify_toolbox ;;
  compare)          cmd_compare ;;
  all)
    cmd_setup && cmd_build_pcc \
      && cmd_compile && cmd_link && cmd_verify \
      && cmd_build_stubs && cmd_compile_toolbox && cmd_link_toolbox && cmd_verify_toolbox \
      && cmd_compare
    ;;
  *)
    echo "Usage: $0 [setup|build-pcc|compile|link|verify|build-stubs|compile-toolbox|link-toolbox|verify-toolbox|compare|all]"
    exit 1
    ;;
esac
