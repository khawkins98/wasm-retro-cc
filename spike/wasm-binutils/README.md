# spike/wasm-binutils/ — Phase 2.2 (`as`) + 2.3 (`ld`) port

> **Status (2026-05-15): scaffold landing.** Tracker:
> [#11](https://github.com/khawkins98/wasm-retro-cc/issues/11)
> sub-spike 2.2 / 2.3. Phase 2.1 (cc1 port) is complete and
> byte-equivalent to native — see [`../wasm-cc1/`](../wasm-cc1/) and
> [`../../LEARNINGS.md`](../../LEARNINGS.md) "Phase 2.1".

Ports Retro68's binutils — specifically `as` (the assembler) and `ld`
(the linker) — to WebAssembly via the same Canadian-cross-to-
Emscripten pattern that worked for cc1. The 8 landmines from Phase 2.1
transfer directly; this directory exists mostly so binutils' bigger
source tree (separate libbfd, libopcodes, gas/, ld/, gold/, ...) gets
its own build dir without entangling cc1's.

## Two artefacts, one source tree

| Phase | Tool | Output |
| --- | --- | --- |
| 2.2 | `as` (gas) — `m68k-apple-macos-as` | `as.wasm` + `as.mjs` |
| 2.3 | `ld` (binutils) + `Elf2Mac` | `ld.wasm` + `ld.mjs` (+ separate Elf2Mac port) |

Both built from `/Retro68/binutils` in the same Docker image as cc1.
Stage 1 (native) builds everything; stage 2 (wasm canadian cross)
also builds everything but we relink only `as` and `ld` with the
proper wasm flags.

## Build it locally

```bash
bash spike/wasm-binutils/build.sh stage1   # native (~5-15 min)
bash spike/wasm-binutils/build.sh stage2   # wasm canadian cross
bash spike/wasm-binutils/build.sh relink   # wasm flags injection
bash spike/wasm-binutils/build.sh smoke    # as --version, ld --version
```

The image step from Phase 2.1 (`bash spike/wasm-cc1/build.sh image`)
must have run first. We share that image.

## Critical design decisions (inherited from Phase 2.1)

These are settled. Read
[`../wasm-cc1/README.md`](../wasm-cc1/README.md) "Critical design
decisions" for the full rationale; deltas for binutils only here.

1. **Same `CONFIG_SITE` answers** as Phase 2.1 plus binutils-specific
   ones (we'll discover them by iteration — landmine pattern: `error:
   conflicting types for 'X'` → seed `ac_cv_func_X=yes`).
2. **`--disable-gold`** — gold is the C++-written linker; we want
   GNU `ld` only (smaller, fewer dependencies).
3. **`--disable-werror`** — binutils enables -Werror by default,
   which trips on minor warnings in cross-compile.
4. **Target = `m68k-apple-macos`** — same target triplet as cc1.
   Confirms the assembler/linker handle the same dialect.

## What this sub-spike does NOT cover

- **Elf2Mac.** It's a small custom C++ binary outside binutils, in
  `/Retro68/Elf2Mac/`. Will need its own tiny port — but it's much
  smaller and has fewer autoconf pain points. Tracked separately
  under Phase 2.3.
- **MEMFS pipe-through harness for `as`.** That comes in a follow-up
  commit after the binary exists — same pattern as cc1's
  `test/memfs-pipe.mjs`.
- **End-to-end `.c` → MacBinary II.** Phase 2.3+.

## Expected landmines (per Phase 2.1)

1. Bundled `config.sub` rejecting `wasm32-unknown-emscripten` (fix:
   `cp /Retro68/binutils/config.sub` into any subdir that has its
   own — same pattern as cc1's GMP/MPFR/MPC patch).
2. libiberty pulled in transitively → same `psignal` / `wait4` /
   `kill` conflict. Already seeded in `config.site`.
3. Some binutils sub-tools (`gold`, `ld.bfd-test`) needing POSIX
   symbols emscripten lacks → `make -k` and relink only `as`/`ld`.
4. Wasm flags ignored by binutils' makefile → manual relink step
   under our control (mirror cc1's `cmd_relink`).
5. Possibly: `as` needing target-specific data files (m68k opcode
   tables) bundled into MEMFS at runtime.
