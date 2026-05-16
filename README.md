# wasm-retro-cc

A WebAssembly build of the [Retro68](https://github.com/autc04/Retro68)
toolchain. Compiles C source into a real classic Macintosh 68k app —
in a browser tab, no install required. The four wasm tools
(`cc1`, GNU `as`, GNU `ld`, `Elf2Mac`) total ~3.9 MB brotli.

## Live demo

**[khawkins98.github.io/wasm-retro-cc](https://khawkins98.github.io/wasm-retro-cc/)**
— edit a tiny Toolbox `hello.c`, click Compile, see the m68k assembly
and a hex dump of the resulting MacBinary II, download the `.bin`,
or hand it to classic-vibe-mac for an in-tab System 7 boot.

For the full editor experience (System 7.5.5 boots in the tab, your
build hot-loads, 21 sample apps you can edit, multi-file projects,
optimisation levels), open the sibling
[**classic-vibe-mac**](https://khawkins98.github.io/classic-vibe-mac/)
playground.

## Status

Phase 2 shipped 2026-05-15. The compiler chain runs end-to-end in
production: click Build & Run in the cv-mac playground; a `.c` file
goes through `cc1` → `as` → `ld` → `Elf2Mac` → MacBinary II in your
browser, gets hot-loaded into BasiliskII, and the app launches and
draws to the screen. First time anyone has compiled classic Mac C
in a browser tab and watched it boot.

The four WASM binaries are byte-identical-or-equivalent to native.
Raw / brotli sizes:

- `cc1.wasm` — 12.6 MB raw, 3.27 MB brotli (the C compiler from GCC)
- `as.wasm` — 782 KB raw, 270 KB brotli (the assembler from GNU binutils)
- `ld.wasm` — 1.0 MB raw, 304 KB brotli (the linker from GNU binutils)
- `Elf2Mac.wasm` — 285 KB raw, 80 KB brotli (Retro68's ELF→MacBinary converter)

Browsers fetch the brotli-compressed versions on the wire, decompress
to raw at instantiation time. Total over the wire: ~3.9 MB.

Vendored into classic-vibe-mac as `sysroot-libs.bin` plus the four
`.wasm`/`.mjs` pairs under `src/web/public/wasm-cc1/`. Phase 2 sub-spike
tracker [#11](https://github.com/khawkins98/wasm-retro-cc/issues/11)
is closed. Phase 1 (PCC native pipeline) is archived in
[`spike-pcc/`](./spike-pcc/).

What comes next for the in-browser compile path is tracked in
[classic-vibe-mac #100](https://github.com/khawkins98/classic-vibe-mac/issues/100)
(multi-file C, mixed C + `.r`, backend abstraction).

---

## Phase 2 details

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

## Two-repo project

This repo is **toolchain-only** (plus the minimal `web-demo/` proof of
life). The interactive playground that consumes it — editor,
in-browser emulator, demo apps, hot-load flow — lives in
**[`classic-vibe-mac`](https://github.com/khawkins98/classic-vibe-mac)**.

If you found this repo *via* `classic-vibe-mac`, the toolchain you
care about is the four `.wasm`/`.mjs` files under `dist/show-asm/`
plus the bundle script that packages them with the Retro68 sysroot.

If you found this repo on its own, **it's reusable** — but the
distribution model is "vendor the artifacts," not "npm install."
This package is not currently published to npm; the manifest
deliberately doesn't have a `main` entry point. The way to
consume the toolchain in your own project is to copy the four
`.wasm` + `.mjs` pairs (plus `sysroot.bin` / `sysroot.index.json`
and the libs blob) out of `dist/show-asm/`, host them yourself,
and drive them from a small driver script.

For a reference driver in ~200 lines, see
[`web-demo/compile.mjs`](./web-demo/compile.mjs) — it loads the
four wasm tools end-to-end, mounts the sysroot blobs into each
Emscripten module's MEMFS, and returns a MacBinary II byte array
from a C source string. The classic-vibe-mac side does the same
in [`src/web/src/playground/cc1.ts`](https://github.com/khawkins98/classic-vibe-mac/blob/main/src/web/src/playground/cc1.ts)
with multi-file C and per-stage diagnostics added on.

Or skip the browser and drive the pipeline straight from Node:

```sh
npm run bundle                    # builds dist/show-asm/ (one-time, slow)
npm run compile-c -- hello.c -o hello.bin
```

[`scripts/compile-c-cli.mjs`](./scripts/compile-c-cli.mjs) runs
the same cc1 → as → ld → Elf2Mac pipeline, reading the wasm
modules + sysroot blobs from disk. Useful for CI smoke tests or
shell-script integrations that don't want a headless browser in
the loop. (The Musashi 68k harness for actually *running* the
resulting binary headless is tracked in
[classic-vibe-mac #89](https://github.com/khawkins98/classic-vibe-mac/issues/89).)

Plausible non-cv-mac uses:

- A retro-Mac-C tutorial site that compiles user code in-browser
  as a teaching tool.
- A static-site IDE for hobbyist classic Mac apps with no server.
- A retro-Mac-code-golf scoreboard that builds + runs submissions
  client-side.
- A Mac-in-the-browser project that wants to ship "edit and
  rebuild" for its own bundled apps.

We use it for `classic-vibe-mac`, but if you find another use,
file an issue with what would have made the artifact-vendoring
path easier and we'll consider abstracting it.

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
