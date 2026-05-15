# wasm-retro-cc

> **Status (May 2026): Phase 2 SHIPPED.** End-to-end Build & Run
> works in the [classic-vibe-mac](https://github.com/khawkins98/classic-vibe-mac)
> playground as of 2026-05-15. Click Build & Run on
> [`wasm-hello/hello.c`](https://github.com/khawkins98/classic-vibe-mac/tree/main/src/app/wasm-hello)
> in the browser; this toolchain produces a MacBinary II APPL from C
> source and it boots cleanly in BasiliskII — "Hello, World!"
> rendered via `DrawString`. First time anyone has compiled classic
> Mac C in a tab and watched it launch.
>
> All four WASM binaries are byte-identical-or-equivalent to native:
> `cc1.wasm` (3.27 MB brotli), `as.wasm` (270 KB brotli),
> `ld.wasm` (304 KB brotli), `Elf2Mac.wasm` (80 KB brotli) — total
> **~3.9 MB brotli** in-browser toolchain, comfortably under the
> 6-8 MB target. Vendored into classic-vibe-mac as
> `sysroot-libs.bin` + the four `.wasm`/`.mjs` files under
> `public/wasm-cc1/`.
>
> Phase 1 (PCC native pipeline) archived in [`spike-pcc/`](./spike-pcc/).
> Phase 2 sub-spike tracker [#11](https://github.com/khawkins98/wasm-retro-cc/issues/11)
> closed. What's next for the playground's in-browser C path tracked in
> [classic-vibe-mac #100](https://github.com/khawkins98/classic-vibe-mac/issues/100)
> (multi-file C, mixed C+.r, backend abstraction).

A WebAssembly C compiler targeting the classic Macintosh 68k, designed
for use inside browser-based emulators like
[classic-vibe-mac](https://github.com/khawkins98/classic-vibe-mac).

---

## Phase 2 status — shipped 2026-05-15

All Phase 2 sub-spikes complete. The compiler chain runs end-to-end
in production: a user clicks Build & Run in the cv-mac playground, a
`.c` source file is compiled in-browser through cc1 → as → ld →
Elf2Mac → MacBinary II, hot-loaded into BasiliskII, and the app
launches and draws to the screen. See cv-mac PR
[#97](https://github.com/khawkins98/classic-vibe-mac/pull/97) for the
final fix (the missing `--emit-relocs` ld flag — found in 45 minutes
by diff-ing our ld invocation against the canonical Retro68 docker
build; see LEARNINGS for the meta-lesson).

| Sub-spike | What it produced | Status |
| --- | --- | --- |
| Phase 2.0 — Retro68 GCC vendoring derisk | Reference binary built from `hello_toolbox.c` boots end-to-end on deployed playground (PRs #13, cv-mac#78) | ✅ shipped |
| Phase 2.1 — `cc1.wasm` | 12 MB raw / 3.3 MB brotli. Compiles `.c` → m68k `.s`, byte-identical to native. See [`spike/wasm-cc1/`](./spike/wasm-cc1/) | ✅ shipped |
| Phase 2.2 — `as.wasm` | 782 KB raw / 270 KB brotli. Assembles `.s` → ELF32 `.o`, byte-identical to native. See [`spike/wasm-binutils/`](./spike/wasm-binutils/) | ✅ shipped |
| Phase 2.3a — `ld.wasm` | 1.0 MB raw / 304 KB brotli. m68k ELF linker. | ✅ shipped |
| Phase 2.3b/c — `Elf2Mac.wasm` | 285 KB raw / 80 KB brotli. ELF → MacBinary II. Hand-rolled `MinimalElf` (240 LOC C++) replaces libelf. See [`spike/wasm-elf2mac/`](./spike/wasm-elf2mac/) | ✅ shipped |
| Phase 2.3d — End-to-end glue | sysroot-libs.bin bundle (libretrocrt, libInterface, libc, libm, libgcc + Retro68 universal headers + the multi-seg ld script), packaged via [`scripts/build-show-asm-bundle.mjs`](./scripts/build-show-asm-bundle.mjs); vendored into cv-mac as `public/wasm-cc1/` | ✅ shipped |
| Phase 2.4 — Bundle-size optimisation | ~3.9 MB brotli total (`-Os -g0` applied during 2.1-2.3). Comfortably under the 6-8 MB target. | ✅ shipped |
| Phase 2.5 — packaging | Vendored directly into cv-mac as artifact files rather than npm — same outcome, lower coupling. The `build-show-asm-bundle.mjs` script generates the bundle that cv-mac consumes. | ✅ shipped (different shape than originally planned) |

### Out of scope (explicit non-goals from Phase 2)

These are deliberately not in this toolchain:

- **C++ support.** Phase 2 was C-only (`--enable-languages=c`). Cuts ~60% of GCC's frontend mass; Classic Mac C is the user-visible target.
- **GCC's full bootstrap.** `--disable-bootstrap`. Stage 2 builds with host gcc only.
- **Driver / `collect2` / link-stage runner.** Emscripten has no `fork`/`exec`. JS host orchestrates the four wasm tools with cooked argv. The classic-vibe-mac side's `compileToBin` is the orchestration layer; see [LEARNINGS Key Story #5](https://github.com/khawkins98/classic-vibe-mac/blob/main/LEARNINGS.md) for why this bypass of the GCC driver is the largest source of subtle bug-class differences vs canonical Retro68 builds.
- **PowerPC / CFM / Mac OS 8 / SheepShaver.** Long-term aspiration, separate stack. Tracked in [classic-vibe-mac #98](https://github.com/khawkins98/classic-vibe-mac/issues/98).
- **In-browser compilation of the Retro68 SDK headers themselves.** Headers are pre-built; only user code goes through wasm cc1.

### What's next

Forward-looking work moved to the cv-mac repo, where the toolchain is
consumed:

- [classic-vibe-mac #100](https://github.com/khawkins98/classic-vibe-mac/issues/100) — Multi-file C support, mixed C + `.r` projects, backend abstraction layer that future PowerPC / other-target ports can slot into without re-plumbing.
- [classic-vibe-mac #98](https://github.com/khawkins98/classic-vibe-mac/issues/98) — PowerPC investigation (long-term).
- [classic-vibe-mac #89](https://github.com/khawkins98/classic-vibe-mac/issues/89) — Musashi 68k harness opportunistic expansion.

Phase 1 (PCC m68k → MacBinary II native pipeline) is archived in
[`spike-pcc/`](./spike-pcc/). Three real bugs fixed during that
investigation, but the remaining crash-on-any-Toolbox-call defied
nine hours of bisect work — the trigger for the Phase 2 pivot.
Full retrospective in [`spike-pcc/ARCHIVE.md`](./spike-pcc/ARCHIVE.md).

---

## What this is

A WebAssembly build of Retro68's classic-Mac 68k C toolchain — `cc1`,
GNU `as`, GNU `ld`, and `Elf2Mac` — packaged so a JavaScript host
can compile C source code targeting `m68k-apple-macos` entirely in a
browser tab, returning a valid MacBinary II APPL. No backend, no
GitHub Actions detour, no local toolchain install.

## Two-repo project

This repo is **toolchain-only**. The interactive playground that
consumes it — editor, in-browser emulator, demo apps, hot-load flow —
lives in **[`classic-vibe-mac`](https://github.com/khawkins98/classic-vibe-mac)**.

If you found this repo *via* `classic-vibe-mac`, the toolchain you
care about is the four `.wasm`/`.mjs` files under `dist/show-asm/`
plus the bundle script that packages them with the Retro68 sysroot.

If you found this repo on its own, **it's reusable.** Nothing here
is `classic-vibe-mac`-specific — the JS API takes source files and
returns a MacBinary, and the consumer decides what to do with it.
Plausible other uses:

- A retro-Mac-C tutorial site that compiles user code in-browser as
  a teaching tool.
- A static-site IDE for hobbyist classic Mac apps with no server.
- A retro-Mac-code-golf scoreboard that builds + runs submissions
  client-side.
- A Mac-in-the-browser project that wants to ship "edit and rebuild"
  for its own bundled apps.

We use it for `classic-vibe-mac`, but if you find another use, the
public surface area is just the four wasm modules + the sysroot
bundle. PRs welcome if your use case surfaces something that needs
abstracting.

---

## How we got here

This project ran two phases. The pivot history matters because it
shapes the codebase you see:

### Phase 1 (archived) — PCC m68k → MacBinary II

We picked PCC (Portable C Compiler) because it's small (~3 MB
gzipped), BSD-licensed, and ships an m68k backend. The Phase 1 pipeline
worked structurally: `inspect_macbinary.py` validation passed, output
shape matched Retro68 reference binaries (CODE 0 + CODE 1..N + DATA +
RELA, `below_a5 > 0`), and three real bugs were found and fixed:

| # | Bug | Fix |
| --- | --- | --- |
| 1 | `Elf2Mac --mac-single` produced `below_a5=0`, no DATA, no RELA | PR #5: use `m68k-apple-macos-ld -elf2mac` multi-segment mode |
| 2 | PCC default struct alignment put `qd.thePort` at offset 204; libretrocrt expected 202 | PR #6: `#pragma pack(2)` on `QDGlobals` |
| 3 | `MoveTo` / `FlushEvents` stubs read 2-byte short args from PCC's 4-byte slots | PR #7: read low word of each 4-byte slot |

After all three fixes the binary still crashed on **any** Toolbox call
(type-3, CHK, or type-10 depending on heap state). Bisect probes
narrowed it to "any single Toolbox call destabilises the system" — not
specific to one call. With no clear next bisect step and the structural
argument against PCC's rarely-used m68k backend (the population of
remaining bugs is unknown and unbounded), we paused.

The full investigation lives in [`LEARNINGS.md`](./LEARNINGS.md) under
"Boot test (2026-05-14)". The PCC pipeline is preserved verbatim in
[`spike-pcc/`](./spike-pcc/) with its own
[`ARCHIVE.md`](./spike-pcc/ARCHIVE.md) and runs manually via the
`[archived] PCC m68k pipeline` GitHub Action.

### Phase 2 (current) — Retro68 GCC → WASM

The pivot rationale, in one line: **swap unbounded compiler-bug
debugging for a known-bounded compiler-porting problem.**

Retro68 GCC produces binaries that are proven to run on this exact
emulator — every Retro68 sample app boots. The risk is the toolchain
size (~25–40 MB gzipped after stripping) and the engineering work to
get GCC + binutils + Elf2Mac through Emscripten. That's known-bounded;
[Emception](https://github.com/jprendes/emception) (Clang + LLVM →
WASM) is the closest precedent.

See [issue #11](https://github.com/khawkins98/wasm-retro-cc/issues/11)
for the Phase 2 sub-spike breakdown.

---

## Architecture (Phase 2 target)

```
┌─────────────────────────────────────────────────────┐
│  Retro68 build (CI or Docker)                       │
│  • m68k-apple-macos-gcc, -as, -ld, Elf2Mac          │
│  • libretrocrt.a, libInterface.a, libc.a, libm.a    │
│  • CIncludes/ (Apple A-trap headers verbatim)       │
│  → Emscripten-cross-compiled to WASM                │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│  retro-cc.wasm  (runs in browser)                   │
│                                                     │
│  Pipeline (in-memory, MEMFS):                       │
│    .c → cc1 → .s → as → .o → ld → ELF → Elf2Mac    │
│    → .bin (MacBinary II)                            │
│                                                     │
│  JS API mirrors wasm-rez:                           │
│    compile(sources, options) → { bin, log }         │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│  classic-vibe-mac playground                        │
│  HFS-patches the .bin into the BasiliskII boot disk │
└─────────────────────────────────────────────────────┘
```

Unlike Phase 1, **user code goes through Retro68's own headers**.
Apple's A-trap syntax (`= { 0xA913 }`) is parsed by Retro68 GCC natively,
so the hand-written shim layer from Phase 1 (`spike-pcc/include/`,
`spike-pcc/stubs/libtoolbox-stubs.s`) is no longer required.

---

## Non-goals

- C++ support (initially).
- 100% GCC feature compatibility — `-O0` / basic `-O1` is enough.
- Compiling the Retro68 SDK headers themselves in-browser — those are
  pre-built and shipped inside the WASM.
- Targeting Mac 128K/Plus/SE (68000-only). 68020+ is fine; BasiliskII
  Quadra-650 runs 68040.
- PowerPC / Mac OS 8 / SheepShaver. Long-term aspiration, not Phase 2 scope.

---

## Project layout

```
wasm-retro-cc/
├── README.md                ← this file
├── LEARNINGS.md             ← cross-phase technical findings
├── CONTRIBUTING.md          ← setup, workflow, settled decisions
│
├── spike/                   ← Phase 2 work
│   ├── README.md            ← Phase 2.0 overview
│   ├── hello_toolbox.c      ← derisk source (2.0)
│   ├── build-retro68.sh     ← Docker-driven Retro68 GCC build (2.0)
│   └── wasm-cc1/            ← Phase 2.1 cc1 → WASM port
│       ├── README.md        ← architecture, landmines, recipe
│       ├── Dockerfile       ← Emscripten + Retro68 sources
│       └── build.sh         ← stage1 native + stage2 wasm
│
├── spike-pcc/               ← Phase 1 archive — ARCHIVE.md inside
│
└── .github/workflows/
    ├── phase2.yml           ← manual Retro68 build (Phase 2.0)
    └── spike.yml            ← manual-only [archived] PCC pipeline
```

### Phase 2 progress

| Sub-spike | Status | Tracker |
| --- | --- | --- |
| 2.0 — Retro68 binary vendoring derisk | ✅ landed 2026-05-14 | #11, #13, cv-mac#78 |
| 2.1 — Emscripten port of `cc1` | 🚧 scaffold landed; first build pending | #11 |
| 2.2 — Emscripten port of `as` | not started | #11 |
| 2.3 — Wire `ld` + Elf2Mac into WASM pipeline | not started | #11 |
| 2.4 — Bundle-size optimisation | not started | #11 |
| 2.5 — npm packaging (mirror `wasm-rez` API) | not started | #11 |

---

## Getting involved

- **Phase 2 master tracker:** [#11](https://github.com/khawkins98/wasm-retro-cc/issues/11)
- **Cross-repo roadmap:** [classic-vibe-mac #64](https://github.com/khawkins98/classic-vibe-mac/issues/64)
- **Contributing guide:** [`CONTRIBUTING.md`](./CONTRIBUTING.md)
- **Open questions:** see the "Key decisions still open" section in CONTRIBUTING.

---

## License

This repository does not yet have a top-level `LICENSE` file — that's
on the punch list for Phase 2 packaging. Upstream licenses for vendored
components: PCC (BSD-style), Retro68 / Elf2Mac (GPLv2). Provenance is
tracked in `LEARNINGS.md` and `spike-pcc/ARCHIVE.md`; consult upstream
sources before redistribution.
