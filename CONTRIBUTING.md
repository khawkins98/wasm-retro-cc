# Contributing to wasm-retro-cc

This is a research-heavy project. Before writing any code, read
`README.md` (the PRD) and `LEARNINGS.md` (everything we already know).
Working through unsolved problems twice wastes everyone's time.

---

## Project status

See [`README.md`](./README.md) "Phase 2 status" for the canonical
done / in-progress / won't-do breakdown. Short version: Phase 2.0
(Retro68 GCC vendoring derisk) ✅ landed 2026-05-14; Phase 2.1
(`cc1` Emscripten port) is in active scaffolding under
[`spike/wasm-cc1/`](./spike/wasm-cc1/). Tracking issue:
[#11](https://github.com/khawkins98/wasm-retro-cc/issues/11).

Phase 1 (PCC m68k → MacBinary II native pipeline) is archived in
[`spike-pcc/`](./spike-pcc/) with its own
[`ARCHIVE.md`](./spike-pcc/ARCHIVE.md). The `hello*.c` probes there
serve as the **regression corpus** for Phase 2 — they are
compiler-agnostic and the same source files should compile-and-run
under the new GCC → WASM toolchain.

---

## Prerequisites

### Phase 2 (Retro68 GCC → WASM port — in progress)

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
├── spike/                 ← Phase 2 work
│   ├── README.md          Phase 2.0 overview
│   ├── hello_toolbox.c    Derisk source (compiles under Retro68 GCC)
│   ├── build-retro68.sh   Docker-driven Retro68 build (Phase 2.0)
│   └── wasm-cc1/          Phase 2.1 cc1 → WASM port scaffold
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
    ├── workflows/phase2.yml  Manual Retro68 build (Phase 2.0)
    ├── workflows/spike.yml   Manual-only [archived] PCC pipeline
    └── ISSUE_TEMPLATE/
```

---

## Development workflow

```bash
# Phase 2.0 — Retro68 GCC build (Docker, ~5 min on first run)
bash spike/build-retro68.sh

# Phase 2.1 — cc1 → WASM port (Docker, hours; see README for stages)
bash spike/wasm-cc1/build.sh image    # build the toolchain image
bash spike/wasm-cc1/build.sh stage1   # native cross-cc1
bash spike/wasm-cc1/build.sh stage2   # wasm cc1.mjs + cc1.wasm
bash spike/wasm-cc1/build.sh smoke    # Node `--version` smoke test
```

For the Phase 1 archive workflow, see
[`spike-pcc/ARCHIVE.md`](./spike-pcc/ARCHIVE.md).

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

- [ ] Bundle-size budget. Updated target ~3-5 MB brotli for `cc1` alone (smaller than the initial estimate; see `LEARNINGS.md` "Phase 2.1 research"). Stripping unused frontends + treeshaking libs is the main lever.
- [ ] Filesystem strategy: MEMFS vs IDBFS for headers + libraries.
- [ ] How to surface compiler error/warning output to the playground UI.

Decisions already made for Phase 2.1 are captured in
[`spike/wasm-cc1/README.md`](./spike/wasm-cc1/README.md) "Critical
design decisions" — don't relitigate without reading that first.

---

## Code conventions

- C code (compiler, linker, MacBinary writer): C99, no VLAs, no `alloca`.
- JavaScript/TypeScript: ES2022 modules, no CommonJS.
- No dependencies in the JS wrapper beyond what Emscripten generates.
- Comments explain *why*, not *what* — the code shows what.

---

## Commit messages — Conventional Commits

Same convention as the downstream
[classic-vibe-mac](https://github.com/khawkins98/classic-vibe-mac/blob/main/CONTRIBUTING.md#commit-messages--conventional-commits)
repo so cross-repo work reads consistently. Format:

```
<type>(<optional scope>): <short summary>

<optional body>

<optional footer>
```

Common types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`,
`build`. Spike work uses `spike` or `diag(spike)` (research / bisect
probes — see #10 for an example).

Examples:

```
feat(spike): Phase 2.0 — Retro68 GCC builds hello_toolbox cleanly
feat(scripts): show-asm bundle — package cc1 + sysroot for browser consumers
fix(stubs): MoveTo + FlushEvents — handle PCC's 4-byte short-arg slots
chore: pivot to Phase 2 — archive PCC pipeline under spike-pcc/
diag(spike): hello_initgraf_zone — H2 probe (MaxApplZone + MoreMasters)
```

---

## Pull requests

- Open a PR against `main` for any non-trivial change; squash-merge by
  default. Single-commit branches can fast-forward.
- PR body uses `## Summary` + (optional) file table + `## Test plan`
  checklist. The `Test plan` mixes `[x]` (done locally) and `[ ]`
  (post-merge / cross-repo). Look at #14 / #16 for the canonical shape.
- Link the tracking issue (`Refs: #11` for Phase 2 work).
- Cross-repo PRs (the common case for Phase 2.x) reference the
  companion PR in the other repo from both sides.

---

## Distribution bundles (`dist/`)

Downstream consumers (today: `classic-vibe-mac`) vendor wasm artefacts
into their own static-asset trees. We produce one *bundle* per
consumer-facing feature under `dist/<bundle>/`, generated by a script
in `scripts/`:

| Bundle | Script | Purpose |
| --- | --- | --- |
| `dist/show-asm/` | `scripts/build-show-asm-bundle.mjs` | cc1.wasm + minimal sysroot for the cv-mac "Show Assembly" panel (#17) |

Bundles are gitignored — the canonical source is the script + the
underlying `spike/wasm-cc1/build/` output. Consumers re-vendor on
demand; bundle contents are SHA-pinned in their downstream `VENDORED.md`.

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
