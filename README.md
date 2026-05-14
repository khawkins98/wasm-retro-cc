# wasm-retro-cc

> **Status (May 2026): Phase 2 — porting Retro68 GCC to WebAssembly.**
> Phase 2.0 (vendored Retro68 GCC artefact derisk) ✅ landed 2026-05-14.
> Phase 2.1 (`cc1` Emscripten port) in progress — see
> [`spike/wasm-cc1/`](./spike/wasm-cc1/).
> Phase 1 (PCC native pipeline) is archived in [`spike-pcc/`](./spike-pcc/).
> Tracking: [issue #11](https://github.com/khawkins98/wasm-retro-cc/issues/11),
> cross-repo roadmap in [classic-vibe-mac #64](https://github.com/khawkins98/classic-vibe-mac/issues/64).

A WebAssembly C compiler targeting the classic Macintosh 68k, designed
for use inside browser-based emulators like
[classic-vibe-mac](https://github.com/khawkins98/classic-vibe-mac).

---

## What this is

The goal is a self-contained WASM module — `retro-cc.wasm` +
`retro-cc.js` — that compiles C source code targeting
`m68k-apple-macos` entirely in a browser tab, returning a valid
MacBinary II that a BasiliskII WASM emulator can hot-load. No backend,
no GitHub Actions detour, no local toolchain install.

JS API parity with [`wasm-rez`](https://github.com/khawkins98/wasm-rez)
so the downstream integration in classic-vibe-mac is minimally invasive.

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
