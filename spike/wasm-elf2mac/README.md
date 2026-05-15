# spike/wasm-elf2mac/ — Phase 2.3 Elf2Mac port

> **Status (2026-05-15): scaffold landing.** Tracker:
> [#11](https://github.com/khawkins98/wasm-retro-cc/issues/11) sub-spike 2.3.

Ports Retro68's `Elf2Mac` tool — converts m68k ELF executables (output
of `ld`) into MacBinary II APPL bundles. The last conversion step in
the Phase 2 toolchain: with cc1.wasm + as.wasm + ld.wasm + Elf2Mac.wasm
all functional, we have `.c` source → `.bin` MacBinary in-browser.

## Why a separate sub-spike

Elf2Mac is **not** part of binutils. It's a small custom C++ tool
(~10 source files, ~2 K LOC) living in `/Retro68/Elf2Mac/` that knows
about Mac-specific CODE/DATA/RELA resource fork shape and the A5 world
layout. binutils ld emits plain m68k ELF; Elf2Mac wraps it into the
shape the Process Manager wants. Phase 1's PCC pipeline used the same
tool (via Retro68's pinned image); we're WASM-porting it now so the
in-browser path doesn't need a Docker call-out.

Dependencies:
- **Boost** (header-only — `algorithm/string/predicate`,
  `algorithm/string/replace`). Available via `libboost-all-dev` in
  the Phase 2.1 builder image.
- **ResourceFiles** library — Retro68's own resource-fork helper,
  `/Retro68/ResourceFiles/`. Pure C++, no external deps.
- **elf.h** — kernel ELF struct definitions. Built into Linux libc
  (and emscripten's sysroot via musl).

## Build it locally

```bash
bash spike/wasm-elf2mac/build.sh stage1   # native
bash spike/wasm-elf2mac/build.sh stage2   # wasm via emcmake
bash spike/wasm-elf2mac/build.sh relink   # if needed (wasm flags)
bash spike/wasm-elf2mac/build.sh smoke    # node -e ... Elf2Mac --help
```

The image step (`bash spike/wasm-cc1/build.sh image`) must have run
first.

## Critical design decisions

Same as cc1/binutils: CONFIG_SITE answers, -Os -g0, MODULARIZE+EXPORT_ES6
for the relink. Specifically for Elf2Mac:

1. **CMake instead of autoconf.** Elf2Mac uses CMake. The
   Canadian-cross is `emcmake cmake -DCMAKE_TOOLCHAIN_FILE=…` with
   Emscripten's bundled toolchain file. Simpler than binutils.
2. **Boost is header-only here** — no Emscripten Boost port needed.
   `find_package(Boost REQUIRED)` finds the host install at
   `/usr/include/boost/`, headers are arch-independent so they work
   for wasm32 too.
3. **No `-elf2mac` ld emulation patches needed.** We use Retro68's
   approach: ld produces plain ELF, Elf2Mac converts. Keeps binutils
   stock + adds a small (~100 KB?) Elf2Mac.wasm rather than patching
   binutils' ld for a Mac-specific emulation.

## What "Phase 2.3 done" looks like

End-to-end: feed our Phase 2.2 `hello_toolbox.o` to wasm `ld`,
produce a plain m68k ELF, feed to wasm `Elf2Mac`, get a complete
MacBinary II that `spike-pcc/inspect_macbinary.py` validates and that
boots in the classic-vibe-mac playground via the existing vendoring
flow. Diff against the Phase 2.0 reference `hello-toolbox-retro68.bin`
— if equivalent (or nearly so), the in-browser toolchain is proven
end-to-end.
