# Contributing to wasm-retro-cc

This is a research-heavy project. Before writing any code, read
`README.md` (the PRD) and `LEARNINGS.md` (everything we already know).
Working through unsolved problems twice wastes everyone's time.

---

## Project status

**Phase 2 (current): Retro68 GCC → WASM port.** Tracking issue:
[#11](https://github.com/khawkins98/wasm-retro-cc/issues/11). The plan,
rationale, and starting sub-spikes are in that issue and in
`LEARNINGS.md` under "Phase 2 pivot (2026-05-14)".

**Phase 1 (archived): PCC m68k → MacBinary II native pipeline.** Lives in
[`spike-pcc/`](./spike-pcc/) with its own [`ARCHIVE.md`](./spike-pcc/ARCHIVE.md)
explaining what it did and why we stopped iterating on it. Reproducible
manually via the workflow_dispatch-only **[archived] PCC m68k pipeline**
GitHub Action.

The `hello*.c` probes in `spike-pcc/` serve as the **regression corpus**
for Phase 2 — they are compiler-agnostic and the same source files
should compile-and-run under the new GCC → WASM toolchain.

---

## Prerequisites

### Phase 2 (Retro68 GCC → WASM port — not started)

Expected toolchain:

- [Emscripten SDK](https://emscripten.org/docs/getting_started/downloads.html) (for building GCC/binutils to WASM)
- Docker (for the upstream Retro68 image we vendor stubs and reference binaries from)
- CMake 3.20+
- Python 3.9+
- Node.js 20+

The Phase 2 plan is to Emscripten-port Retro68's `m68k-apple-macos-gcc`,
`m68k-apple-macos-as`, and `Elf2Mac` and expose them through a JS API
mirroring [`wasm-rez`](https://github.com/khawkins98/wasm-rez). See
[issue #11](https://github.com/khawkins98/wasm-retro-cc/issues/11) for
the sub-spike breakdown.

### Phase 1 spike (archived)

```bash
# Manual reproduction — workflow_dispatch only in CI
bash spike-pcc/run-spike.sh setup
bash spike-pcc/run-spike.sh all
```

Requires Docker (for the Retro68 image) and Python 3. See
[`spike-pcc/ARCHIVE.md`](./spike-pcc/ARCHIVE.md) for the full story.

---

## Repository layout

```
wasm-retro-cc/
├── README.md              ← PRD — read this first (Phase 2 framing)
├── LEARNINGS.md           ← Cross-phase technical discoveries
├── CONTRIBUTING.md        ← You are here
│
├── spike/                 ← Phase 2 work lands here (TBD)
│
├── spike-pcc/             ← Phase 1 archive — see ARCHIVE.md
│   ├── ARCHIVE.md
│   ├── include/           Shim headers (mac68k-packed)
│   ├── stubs/             Hand-written A-trap stubs
│   ├── hello*.c           Compiler-agnostic regression corpus
│   ├── run-spike.sh       Manual driver
│   ├── inspect_macbinary.py
│   └── docs/              PCC-era design docs (archived)
│
└── .github/
    ├── workflows/spike.yml  Manual-only [archived] PCC pipeline
    └── ISSUE_TEMPLATE/
```

---

## Development workflow

The Phase 2 build/test scripts are TBD. Expect them to live under
`spike/` once the first sub-spike (Phase 2.0: verify a vendored Retro68
GCC binary actually boots) lands.

For the Phase 1 archive workflow, see `spike-pcc/ARCHIVE.md`.

---

## Key decisions already made

These are settled.

| Decision | Rationale |
|---|---|
| **Compiler: Retro68 GCC** (Phase 2) | Phase 1 with PCC produced binaries that crashed on any Toolbox call after three real bugs fixed and a sustained debugging session. Retro68 GCC has known-good output (every Retro68 sample app boots in the same emulator). See `LEARNINGS.md` "Phase 2 pivot". |
| **Target: BasiliskII (System 7.5.5)** | Same emulator as classic-vibe-mac. Retro68 + BasiliskII is the most-trodden path. SheepShaver/PowerPC remains a long-term aspiration but is not Phase 2 scope. |
| **Distribution: WASM module, JS API parity with `wasm-rez`** | Same loader pattern as the existing classic-vibe-mac integration; minimal surface change downstream. |
| **Don't iterate on the PCC path** | The remaining bug is "any Toolbox call crashes". With no clear bisect, the EV of more PCC debugging is below the EV of porting a known-working compiler. |

---

## Key decisions still open (Phase 2)

- [ ] Emscripten build configuration for `m68k-apple-macos-gcc` — vendor an Emception-style fork or upstream-clean port?
- [ ] Bundle-size budget. Initial target ~25–40 MB gzipped (lazy-loaded). Stripping unused frontends + treeshaking libs is the main lever.
- [ ] Filesystem strategy: MEMFS vs IDBFS for headers + libraries.
- [ ] How to surface compiler error/warning output to the playground UI.

---

## Code conventions

- C code (compiler, linker, MacBinary writer): C99, no VLAs, no `alloca`.
- JavaScript/TypeScript: ES2022 modules, no CommonJS.
- No dependencies in the JS wrapper beyond what Emscripten generates.
- Comments explain *why*, not *what* — the code shows what.

---

## Asking for help

Open an issue. Use the templates in `.github/ISSUE_TEMPLATE/`.

Useful references:

- [Issue #11 — Phase 2 pivot](https://github.com/khawkins98/wasm-retro-cc/issues/11) — the master tracker.
- [classic-vibe-mac #64](https://github.com/khawkins98/classic-vibe-mac/issues/64) — cross-repo roadmap.
- Retro68 source — especially `Elf2Mac/`, `libretro/`, `CIncludes/`.
- Emception — closest precedent for a full C/C++ toolchain compiled to WASM.
- Inside Macintosh ([vintageapple.org](http://www.vintageapple.org/inside_r/)) — Toolbox reference.
- `LEARNINGS.md` — both phases' findings.
