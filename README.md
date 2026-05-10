# wasm-retro-cc

> **Status: Native spike pipeline complete through `spike-phase2` (CI green). Browser WASM module — issue #1's "Phase 3" — not started; planning in #3.**
> A WASM C compiler targeting the classic Macintosh 68k, designed for use in browser-based playground environments.

---

## Current state (May 2026)

What is implemented today:

- ✅ `spike/run-spike.sh` builds PCC, compiles C, links via Retro68 `Elf2Mac`, and validates MacBinary output
- ✅ CI workflow `.github/workflows/spike.yml` runs **phase0 / phase1 / phase2** and uploads artifacts
- ✅ `src/stubs/libtoolbox-stubs.s` provides hand-written Toolbox trap bridge stubs (GNU AS MIT syntax)
- ✅ `src/include/*.h` shim headers cover the current spike program surface
- ✅ Phase 2 output (`hello_toolbox.bin`) has been structurally validated and round-tripped through classic-vibe-mac's HFS patcher path

What is **not** implemented yet:

- ❌ `retro-cc.wasm` / `retro-cc.js` browser module
- ❌ In-browser compile API and runtime integration

---

## Product Requirements Document

### Problem

Browser-based classic Mac emulators (e.g. [classic-vibe-mac](https://github.com/khawkins98/classic-vibe-mac)) let users view and edit Mac application source code, but cannot complete the development loop: the GCC-based Retro68 toolchain cannot run without a native host, making in-browser compilation impossible.

The only current workarounds are:

1. **Dedicated compile server** (Docker + Retro68) — requires maintained backend infrastructure.
2. **GitHub Actions** triggered from the browser — requires users to configure personal access tokens.
3. **Local toolchain** — requires installing Retro68 locally.

None of these support a zero-config, zero-server, instant **edit → compile → run** loop inside the emulator.

### Goal

Produce a single self-contained WASM module — `retro-cc.wasm` + `retro-cc.js` — that can compile C source code targeting `m68k-apple-macos` entirely in a browser tab, returning a valid MacBinary that an emulator can hot-load.

### Non-goals

- C++ support (initially)
- 100% GCC compatibility
- Optimisation passes beyond `-O0` / basic `-O1`
- FPU instructions or extended 68040 instruction set
- Compiling the Retro68 SDK headers themselves — those are pre-compiled in CI

---

## Background: Why this is hard

The Retro68 toolchain uses GCC with a custom `m68k-apple-macos` target. Mac Toolbox headers use a GCC-exclusive extension to declare ROM traps:

```c
/* Inside <Windows.h> */
pascal WindowPtr NewWindow(...)
    = { 0xA913 };   /* ← GCC m68k A-trap opcode syntax */
```

This opcode syntax is implemented only in GCC's m68k backend. No other compiler (Clang, TCC, PCC, chibicc) parses it.

**The key insight:** user-written C code never contains this syntax — it's hidden inside SDK headers. If we pre-compile the entire Retro68 runtime (CRT, libretro68, Toolbox stubs) into a static library archive using real Retro68 GCC (in CI), user code can be compiled by any C compiler that:

1. Produces valid m68k object code
2. Can link against the pre-built archive
3. Can output (or be post-processed into) MacBinary format

User code just calls `NewWindow(...)` like a normal function. The trap dispatch is inside the pre-compiled library. The WASM compiler never sees A-trap syntax.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  CI (classic-vibe-mac or this repo)                 │
│  Retro68 GCC → pre-compiled SDK archive             │
│  • libretrocrt.a, libInterface.a, libm.a, libc.a   │
│  • Pre-processed headers (A-trap syntax stripped,   │
│    function signatures preserved as extern decls)   │
│  → bundled into retro-cc.wasm at build time         │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│  retro-cc.wasm  (runs in browser)                   │
│                                                     │
│  1. C compiler (PCC m68k backend) → .o file         │
│  2. m68k linker (GNU ld or lld) → linked ELF        │
│  3. Elf2Mac converter → MacBinary (.bin)            │
│                                                     │
│  In-memory filesystem (Emscripten MEMFS)            │
│  Input:  user .c / .h files                         │
│  Output: MacBinary blob                             │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│  Browser playground                                 │
│  MacBinary → HFS patcher → running emulator         │
└─────────────────────────────────────────────────────┘
```

---

## Compiler choice: PCC

**PCC (Portable C Compiler)** is the leading candidate:

| Property | Value |
|---|---|
| m68k backend | ✅ Ships `arch/m68k/` (code.c, local.c, macdefs.h) |
| Codebase size | ~130K LOC (vs GCC's ~15M) |
| WASM portability | High — minimal OS dependencies, POSIX file I/O only |
| Bundle size estimate | 1–4 MB gzipped (similar to wasm-rez's profile) |
| A-trap syntax | ❌ Not needed (user code doesn't contain it) |
| License | BSD |

**Why not others:**

| Compiler | m68k backend | WASM viable | Verdict |
|---|---|---|---|
| GCC (Retro68) | ✅ | ❌ 80–150 MB bundle | Too large |
| LLVM/Clang | ✅ (experimental) | ❌ 12–16 MB bundle | Too large |
| TinyCC | ❌ None | ✅ | No backend |
| chibicc | ❌ None | ✅ | No backend |
| **PCC** | ✅ | ✅ | **Leading candidate** |

---

## Phased delivery plan

> **A note on phase numbering.** This project has two parallel phase tracks
> and the names have collided in earlier docs. The current convention is:
>
> - **`spike-phase0/1/2`** — the native, CI-driven pipeline (PCC + Docker
>   Elf2Mac → MacBinary). All three are complete and green.
> - **`wasm-phase1/2`** — the browser-native compiler module. Not started.
>   This is what handoff issue #1 refers to as "Phase 3".
> - **Polish** — formerly labelled "Phase 3" in this document; reserved for
>   `-O1`, more SDK headers, source maps, etc., once the WASM module ships.
>
> See `docs/architecture.md` for the same split applied to the build phases
> table.

### `spike-phase0` — Feasibility spike (2–4 weeks)

**Goal:** Answer the key unknowns before committing to full implementation.

Questions to answer:
1. Can PCC be compiled via Emscripten today? (check file I/O, `fork()`/`exec()` usage)
2. Does PCC's m68k backend produce correct 68000 output for simple programs?
3. Can a simple m68k relocatable object be linked against pre-built Retro68 stubs?
4. What subset of Classic Mac headers can be pre-processed without A-trap syntax?
5. **Does PCC's output satisfy the Mac Toolbox calling-convention contract?** Our shim headers define `#define pascal` (empty), so PCC generates standard m68k C calls. The Retro68 stubs are compiled with real GCC to handle convention internally. This must be validated — not assumed.
6. **Can the Retro68 Elf2Mac tool process PCC's linked ELF?** Retro68's linker pipeline (GNU ld + Elf2Mac ELF→Mac converter) must accept PCC-generated object files without modification. This is an explicit Phase 0 gate.

**`spike-phase0/1` exit criteria and results (actual):**
- [x] PCC compiles `hello.c` to m68k assembly without errors ✅
- [x] Assembly links against Retro68 stubs (`nm` shows no undefined symbols) ✅
- [x] **Scope decision:** 68020+ output accepted. PCC emits `extb.l`, `muls.l`, etc.; BasiliskII emulates 68020 by default, so Mac II / SE30 / Quadra class is the target. 68000-only Macs (128K, Plus, Classic) are out of scope. See `CONTRIBUTING.md` Key decisions.
- [x] Retro68 Elf2Mac produces a MacBinary from the linked ELF ✅
- [x] MacBinary passes structural and patcher validation (type APPL, non-empty resource fork, HFS round-trip) ✅
- [ ] Full manual browser boot verification in BasiliskII — the *real* exit gate, still pending. Tracked as part of issue #3.

Deliverable: a shell script (`spike/run-spike.sh`) that compiles `hello.c` through the complete PCC → ELF → MacBinary pipeline, using pre-compiled Retro68 stubs. Failure is a valuable result — it identifies which risk row materialised.

### `wasm-phase1` — Core WASM module (not started)

> Issue #1 refers to this as "Phase 3 browser-native compiler/linker integration."
> Issue #3 tracks the sub-spikes (ccom→Emscripten, decoupling Object.cc from
> the Elf2Mac/ld wrapper, m68k linker → WASM strategy) that need to land before
> this phase can be costed.

- PCC compiled to WASM via Emscripten
- Emscripten MEMFS for source file I/O
- Pre-processed System 7 headers bundled in MEMFS
- Pre-compiled Retro68 CRT + libretro68 linked at build time
- **m68k linker:** GNU ld (`m68k-linux-gnu-ld`) or lld compiled to WASM — links user `.o` against pre-compiled stubs to produce a linked ELF
- **Elf2Mac converter:** Retro68's `Elf2Mac/Object.cc` (ELF→Mac binary format) compiled to WASM alongside PCC — this is ~4 C++ files with no `fork()`/`exec()`, gives ABI-compatible MacBinary output for free
- MacBinary output writer (produces `.bin` with both code + resource forks)
- JS wrapper API (see below)

### `wasm-phase2` — Integration + hardening (not started)

- Structured diagnostic output (file, line, column, severity) — same shape as the `Diagnostic` type in classic-vibe-mac
- Bundle size optimisation (strip PCC, tree-shake headers)
- npm package published to GitHub Packages
- Integration with classic-vibe-mac playground (lazy-loaded, same pattern as `wasm-rez`)
- End-to-end test: compile the Hello Mac sample project in-browser, verify it boots in the emulator

### Polish (after `wasm-phase2` ships)

- Basic `-O1` optimisation
- C99 support validation
- More SDK headers (QuickDraw, Dialogs, TextEdit)
- Source maps / better error messages

(This was previously labelled "Phase 3" — renamed to avoid colliding with
issue #1's "Phase 3 = browser-native compiler" usage.)

---

## JS API (target)

Designed to mirror `wasm-rez`'s API for easy integration:

```ts
// Lazy-load (first call fetches ~3 MB, subsequent calls reuse module)
const cc = await loadRetroCC(baseUrl);

const result = await cc.compile({
  files: [
    { name: "main.c", content: "#include <Windows.h>\n..." },
    { name: "utils.h", content: "..." },
  ],
  appName: "HelloMac",
});

if (result.ok) {
  result.macBinary; // Uint8Array — ready for HFS patcher
} else {
  result.diagnostics; // { file, line, column, message, severity }[]
}
```

---

## Pre-processed headers strategy

The Retro68 SDK headers use A-trap syntax that PCC cannot parse. Two approaches:

**Option A — Extern shim headers (preferred for Phase 1):**
Write a minimal set of hand-authored `extern` declarations covering the most-used ~50 Toolbox calls (NewWindow, DisposeWindow, DrawString, MoveTo, etc.), usable with any standard C compiler. These are ~5 KB total and avoid needing the full SDK.

**Option B — Automated header pre-processing:**
A build step (Python script, runs in CI) strips A-trap declarations from Retro68 headers, replacing:
```c
pascal WindowPtr NewWindow(Rect *boundsRect, ...) = { 0xA913 };
```
with:
```c
extern WindowPtr NewWindow(Rect *boundsRect, ...);
```
This enables the full SDK surface but requires careful testing — some headers use `__attribute__` and inline asm that also need stripping.

Start with Option A, graduate to Option B as the surface area needed grows.

---

## Bundle size budget

| Component | Estimated size (gzip) |
|---|---|
| PCC compiler (Emscripten) | 1.5–3 MB |
| Pre-processed headers | 50–200 KB |
| Pre-compiled Retro68 stubs (libretrocrt.a, libtoolbox-stubs.a) | 100–300 KB |
| m68k linker (GNU ld or lld compiled to WASM) | 200–500 KB |
| Elf2Mac converter (Object.cc + deps compiled to WASM) | 50–100 KB |
| **Total** | **~2–4 MB** |

Acceptable: the classic-vibe-mac emulator itself is ~1.7 MB. A 3 MB lazy-loaded WASM module (only fetched when the user clicks Compile) is reasonable.

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **m68k linker** — producing a correct Mac binary requires Mac-specific section handling (CODE/DATA resources, A5 world, jump tables). Writing a compatible linker from scratch is substantial; using the wrong linker silently produces broken binaries. | **High** | **High** | Use Retro68's existing Elf2Mac converter (Object.cc, ~4 files, no fork/exec) compiled to WASM. Phase 0 validates Elf2Mac accepts PCC's output before Phase 1 investment. |
| PCC's m68k backend has bugs for the code patterns Toolbox uses | Medium | High | Phase 0 exit criteria require linking and booting — not just compiling |
| Pascal calling convention mismatch — shim headers define `pascal` as empty, PCC generates standard C calls. If Retro68 stubs expect a different call frame, programs will crash silently. | Medium | High | Explicit Phase 0 exit criterion: boot-test the MacBinary in the emulator |
| `fork()`/`exec()` in PCC driver blocks Emscripten | Medium | Medium | PCC's compiler proper (`ccom`) avoids fork — link directly, bypass the `pcc` driver |
| Bundle > 6 MB after optimisation | Low | Low | PCC is small; fall back to lazy-load with progress indicator |
| Pre-processed headers miss important Toolbox calls | High (initially) | Low | Ship with explicit "supported calls" list, expand iteratively |

---

## Relationship to classic-vibe-mac

This repo produces a standalone npm-publishable WASM artifact. `classic-vibe-mac` consumes it identically to how it consumes `wasm-rez`:

```ts
// In classic-vibe-mac's playground/retro-cc.ts
const module = await loadModule(`${baseUrl}retro-cc/retro-cc.js`);
```

The WASM file is fetched at runtime (not bundled into the main JS chunk), so it doesn't affect initial page load. The Compile & Run button is disabled until the module loads.

When this project reaches browser-ready integration, the compile-server path in `classic-vibe-mac` can be replaced or supplemented: users without a compile server configured get the WASM path instead.

---

## Open questions (remaining)

- [x] Does PCC's m68k output pass through Retro68's Elf2Mac without modification? → Yes, in the native spike pipeline
- [ ] Does the resulting MacBinary fully boot in classic-vibe-mac via manual browser verification? (human test step)
- [ ] What is the minimal set of Toolbox calls needed for a useful playground (target: 80% of what classic-vibe-mac's sample apps use)?
- [ ] Should the resource fork be minimal/empty or should we ship a basic Rez pipeline alongside?
- [x] Can Retro68 stubs be extracted from `ghcr.io/autc04/retro68:latest` in CI without building from source? → Yes, via `docker run --entrypoint /bin/bash | tar -h`
- [x] Does PCC build from source on Ubuntu 24.04 (GCC 13)? → Yes, with three patches. See `LEARNINGS.md` and `spike/run-spike.sh`.
- [x] Does `libInterface.a` from Retro68 contain high-level Toolbox stubs? → No. Only ~30 uppercase OS-level stubs (GESTALT, DELAY, etc.). `libtoolbox-stubs.a` is required and now implemented for the current spike surface.

---

## References

- [PCC source](https://github.com/IanHarvey/pcc) — m68k backend in `arch/m68k/`
- [Retro68](https://github.com/autc04/Retro68) — GCC-based Mac 68k toolchain
- [classic-vibe-mac wasm-rez tool](https://github.com/khawkins98/classic-vibe-mac/tree/main/tools/wasm-rez) — companion Rez compiler compiled to WASM (existing proof-of-concept for this architecture)
- [classic-vibe-mac issue #60](https://github.com/khawkins98/classic-vibe-mac/issues/60) — compile server (interim approach this project supersedes)
- [classic-vibe-mac issue #57](https://github.com/khawkins98/classic-vibe-mac/issues/57) — original in-browser C compilation tracking issue
- [Emception](https://github.com/nicowillis/emception) — reference for compiling Clang to WASM (bundle size data)
