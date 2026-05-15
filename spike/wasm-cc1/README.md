# spike/wasm-cc1/ — Phase 2.1 cc1 → WASM port

> **Status (2026-05-14): scaffold landed; first build attempt pending.**
> Tracker: [#11](https://github.com/khawkins98/wasm-retro-cc/issues/11)
> sub-spike 2.1. Phase 2.0 (vendored Retro68 GCC artefact derisk) is
> complete — see [`../README.md`](../README.md).

The goal of this sub-spike is the central engineering bet of the
project: take `m68k-apple-macos-cc1` (the C compiler proper from
Retro68's GCC 12.2.0) and produce a `cc1.wasm` + `cc1.mjs` pair that
loads in a browser tab and compiles a C source string to m68k assembly
via MEMFS.

If this works, Phase 2.2 (`as`) and Phase 2.3 (`ld` + Elf2Mac) are
structurally identical exercises against smaller binaries. If this
fails for fundamental reasons — autoconf can't accept
`wasm32-unknown-emscripten` as a host, GCC's bootstrap can't be
side-stepped — Phase 2 needs a hard rethink.

---

## Strategic context (one paragraph)

Nobody has shipped GCC-to-WASM before. The closest precedent is
[Emception](https://github.com/jprendes/emception), which targets
**Clang**, not GCC, *specifically because* Clang is a library and GCC
is a monolithic driver-spawning process. We're attempting the harder
path because Retro68's m68k backend exists *only* in GCC — there's no
m68k backend for Clang's `m68k-apple-macos` target. So the choice
isn't Clang vs GCC; it's GCC-in-WASM vs no-compiler-in-browser at all.

---

## Architecture — what we're building

```
┌────────────────────────────────────────────────────────────────┐
│  Stage 1 — native build (x86_64-linux-gnu)                     │
│  Standard Retro68 GCC build. Produces:                         │
│    • Native cross-cc1 (for sanity diff)                        │
│    • Generated headers (insn-*.h, tm.h, …)                     │
│    • Build-time tools ($builddir/gcc/build/gen*)               │
│  These feed into stage 2.                                      │
└──────────────────────────┬─────────────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────────────┐
│  Stage 2 — Canadian cross (build=x86_64, host=wasm32-emscr.,   │
│            target=m68k-apple-macos)                            │
│  emconfigure + emmake. --disable-bootstrap. Reuses stage 1's   │
│  generated headers and build-tools via --with-build-time-tools │
│  so configure never tries to run stage 1 binaries under WASM.  │
│  Output: cc1.wasm + cc1.mjs (ES module).                       │
└──────────────────────────┬─────────────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────────────┐
│  Smoke test (Node)                                             │
│    node -e "import('./build/cc1.mjs').then(m => m.default())"  │
│  Phase 2.1 derisk = it loads and runs --version without        │
│  trapping. MEMFS pipe-through is Phase 2.1.x.                  │
└────────────────────────────────────────────────────────────────┘
```

---

## Build it locally

```bash
# Run the full pipeline (stage 1 + stage 2 + smoke test). Pulls
# the pinned Emscripten + Retro68 source images, ~6 GB total.
# Expect 30–90 minutes on first run depending on host hardware.
bash spike/wasm-cc1/build.sh

# Clean both stages
bash spike/wasm-cc1/build.sh clean

# Re-run only stage 2 (stage 1 outputs cached under build/stage1/)
bash spike/wasm-cc1/build.sh stage2
```

Outputs land in `spike/wasm-cc1/build/`:

| File | What it is |
| --- | --- |
| `build/stage1/gcc/cc1` | Native m68k cross-cc1 (for cross-check) |
| `build/stage1/gcc/build/gen*` | Build-time tools fed into stage 2 |
| `build/stage2/gcc/cc1.wasm` | The WASM compiler (this is the thing) |
| `build/stage2/gcc/cc1.mjs` | Emscripten ES module loader |
| `build/stage2/gcc/cc1.sha` | SHA-256 provenance |

---

## Critical design decisions (from research, 2026-05-14)

These were settled by the prior-art research summarised in
[`../../LEARNINGS.md`](../../LEARNINGS.md#phase-21--emscripten-port-of-cc1)
("Phase 2.1 — Emscripten port of cc1, research"). Don't relitigate
without reading that first.

1. **Bypass the GCC driver.** GCC normally spawns `cc1`, `as`, `ld` as
   child processes via `libiberty/pex-unix.c`. Emscripten has no
   `fork`/`exec`. We don't try to fix this. Instead the JS host
   captures the cooked argv (`-quiet -isystem … -O0 input.c -o
   output.s`) by running `gcc -v` against the native driver once, then
   calls `cc1` directly from JS with that argv. The driver, `collect2`,
   and `as`/`ld` are out of scope for Phase 2.1 — they get their own
   sub-spikes.

2. **`--disable-bootstrap`.** Stage-2 builds with the wasm32-host
   compiler from stage 1 only. No stage2/stage3 sanity loop. We accept
   the small correctness risk because the alternative (running stage1
   cc1 inside wasm to build stage2) is impossible without the runtime
   we're trying to build.

3. **Languages = C only.** `--enable-languages=c` (no C++/Fortran/Ada/
   Go/D). Cuts ~60% of GCC's frontend mass. Retro68 targets Classic Mac
   C anyway; C++ is explicitly out of Phase 2 scope.

4. **Disable everything optional.** `--disable-libgcc --disable-libstdcxx
   --disable-libssp --disable-libquadmath --disable-shared
   --disable-threads --disable-nls --disable-multilib
   --disable-checking --without-headers --without-isl --without-cloog`.
   Each of these is either irrelevant (we want cc1 only) or known to
   break under wasm32-emscripten host.

5. **Native wasm setjmp/longjmp.** `-sSUPPORT_LONGJMP=wasm` (not the
   older `=emscripten`). GCC uses sjlj heavily for diagnostics and ICE
   recovery; native EH is smaller and faster.

6. **Memory snapshot reset between invocations.** Borrowed from
   Emception's `EmProcess.mjs`. GCC has tons of global state (GC heap,
   obstacks, `current_function_decl`); the cheapest reset is
   `HEAPU8.set(initialMemorySnapshot)` rather than reinitialising the
   whole `Module`.

---

## What this sub-spike does NOT do

- Build `as` or `ld` (Phase 2.2 / 2.3).
- Wire MEMFS plumbing for real source files (Phase 2.1.x, after first
  smoke test).
- Optimise bundle size (Phase 2.4).
- Package as npm-installable (Phase 2.5).

If you find yourself touching anything in those buckets, stop and open
a new sub-spike.

---

## Known landmines (read before debugging)

These come from the prior-art research and the GCC-build folklore.
Expect to hit them in order:

1. **`AC_CHECK_FUNCS` link tests miscompile under emconfigure.**
   Autoconf compiles tiny probes and links them with `wasm-ld`; some
   of those probes are nonsense in a no-`fork` environment.
   Mitigation: pre-populate `config.cache` with the answers we know
   are correct (`ac_cv_func_fork=no`, `ac_cv_func_kill=no`, etc.).
   See `build.sh:ConfigCache` for the seed list.

2. **`pex_run`/`pexecute` in `libiberty`.** Compiles fine, runs
   never. Since we bypass the driver, cc1 doesn't actually call these
   — but the build may try to test that they link. If link errors
   start mentioning `pex-`, add stubs that return `-1`.

3. **`mmap` under wasm.** GCC's `ggc-page.c` allocates the GC heap via
   `mmap`. Emscripten's anonymous mmap works (backed by malloc) when
   `ALLOW_MEMORY_GROWTH=1`. Watch for the 2 GB wasm32 ceiling on huge
   translation units; we'll cap at `MAXIMUM_MEMORY=1GB` and treat OOM
   as "user submitted too much C."

4. **Generated headers from stage 1 may need version-locking.** Stage
   2 reuses `insn-*.h` from stage 1. If GCC's version macros leak into
   those headers and stage 2 wants a different version, you get
   silent miscompiles. Mitigation: identical source tree between
   stages (same Git SHA, no Retro68-patch drift).

5. **Bundle size.** Target: 3–5 MB brotli after `-Os -flto` +
   `--disable-checking` + single-target. If we land north of 10 MB
   brotli, Phase 2.4 has more work than budgeted.

---

## References

- [Emception](https://github.com/jprendes/emception) — Clang/LLVM →
  WASM. The two-stage build (`build-llvm.sh`) and `EmProcess.mjs`
  invocation pattern are directly portable.
- [Emception's Clang patch](https://github.com/jprendes/emception/blob/master/patches/llvm-project.patch)
  — 2 hunks that force-integrate cc1 into the driver. Our equivalent
  is "don't use the driver at all."
- [racerxdl/riscv-online-asm](https://github.com/racerxdl/riscv-online-asm)
  — GNU `as`/`objdump`/`objcopy` to WASM. Shares libiberty pain with
  GCC; their autoconf patches are directly transferable.
- [pipcet/gcc `asmjs` branch](https://github.com/pipcet/gcc) — old GCC
  wasm *backend* (not host). Build-system patches in
  `gcc/config.guess` and `libiberty/configure.ac` may be cargo-cult
  worthy.
- [Emscripten setjmp/longjmp](https://emscripten.org/docs/porting/setjmp-longjmp.html)
  — `-sSUPPORT_LONGJMP=wasm`. Use this.
- [`../../LEARNINGS.md` "Phase 2.1 — Emscripten port of cc1"](../../LEARNINGS.md)
  — full research notes with concrete commands.
