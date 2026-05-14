# Architecture — wasm-retro-cc (PCC pipeline, ARCHIVED)

> **Archived 2026-05-14.** This document describes the Phase 1 PCC
> pipeline as it stood when development paused. We pivoted to
> Retro68 GCC → WASM — see [`../ARCHIVE.md`](../ARCHIVE.md) and the
> repo root [`README.md`](../../README.md). The "planned WASM
> pipeline" section below was the Phase 1 target and does **not**
> describe Phase 2.

## Overview

This document covers both:
1. the **implemented native spike pipeline** (Phase 1, archived), and
2. the **then-planned browser WASM pipeline** (Phase 1 target, superseded).

The Phase 1 implementation was CI-driven and native-hosted
(`../run-spike.sh`), not yet browser WASM when archived.

```
┌────────────────────────────────────────────────────────┐
│  Browser (classic-vibe-mac playground)                 │
│                                                        │
│  ┌──────────────┐   source.c   ┌──────────────────┐   │
│  │  editor.ts   │ ────────────▶│  retro-cc.wasm   │   │
│  │  (CodeMirror)│              │  (PCC compiled   │   │
│  └──────────────┘              │   via Emscripten)│   │
│         ▲                      └────────┬─────────┘   │
│         │                               │             │
│         │      MacBinary (.bin)         │             │
│         └───────────────────────────────┘             │
│                                                        │
│  ┌────────────────────────────────────────────────┐   │
│  │  HFS volume (via hfsutils / wasm-hfs)          │   │
│  │  MacBinary patched into volume image           │   │
│  │  Emulator boots from volume                    │   │
│  └────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────┘
```

## Components

### PCC (current: native spike; target: compiled to WASM)

**Source:** https://github.com/IanHarvey/pcc  
**Why PCC:** ~130K LOC, has an existing `arch/m68k/` backend, C90 compliant output.
LLVM was ruled out (12–16 MB gzipped). GCC/Retro68 was ruled out (80–150 MB).

**What PCC does NOT handle directly:**
- The Retro68 driver (`cc.c`) — uses `fork()`/`execv()`, incompatible with Emscripten
- Assembler syntax in SDK headers — handled via shim headers + hand-written stubs
- Final Mac app packaging — handled via Retro68 `Elf2Mac`

**Compilation pipeline currently implemented (native spike):**

```
source.c
  └─▶ [PCC ccom] → .s
        └─▶ [m68k-linux-gnu-as] → .o
              └─▶ [Retro68 ld wrapper via Elf2Mac] + archives → ELF/MacBinary
                    └─▶ [verify scripts] → validated .bin artifact
```

> **Note (Phase 0 finding):** PCC's m68k backend emits 68020+ instructions (`extb.l`,
> `muls.l`, `divu.l`). This is accepted: the classic-vibe-mac emulator (BasiliskII)
> emulates a 68020 by default. Phase 0 binaries target Mac II / SE/30 / Quadra class;
> 68000-only Macs (128K, Plus, Classic) are out of scope.

### Shim headers (`../include/`)

Plain C90 `extern` declarations for the Mac Toolbox. These replace Retro68's
A-trap-based SDK headers, which use GCC-specific syntax PCC cannot parse.

See `docs/header-strategy.md` for the detailed design.

### Pre-compiled stubs (`../stubs/`)

Extracted from `ghcr.io/autc04/retro68:latest` in CI. Key libraries:

- **`libretrocrt.a`** — startup (`_start`), relocator, `malloc`, QuickDraw globals
- **`libc.a`** — standard C library
- **`libInterface.a`** — ~30 uppercase OS-level stubs only (GESTALT, DELAY, etc.)
- **`libtoolbox-stubs.a`** — hand-assembled stubs for QuickDraw,
  Window Manager, Event Manager, etc. (libInterface.a does NOT include these). Implemented in `../stubs/libtoolbox-stubs.s`.

In the current spike, stubs are assembled in CI/local spike runs and linked natively.

> **Important:** `libInterface.a` symlinks to Retro68's multiversal/lib68k tree. Use
> `tar -h` when extracting to dereference the symlink.

### MacBinary wrapper

After linking produces an ELF binary, a small JavaScript utility wraps the code segment
in a MacBinary II header so the emulator's HFS patcher can inject it into a disk image.

Format reference: see `LEARNINGS.md` → MacBinary II Format section.

## Build phases

| Stage | Goal | Status |
|-------|------|--------|
| Spike phase0 | PCC build + compile + ELF validation | **Complete** |
| Spike phase1 | ELF → MacBinary via Elf2Mac + header checks | **Complete** |
| Spike phase2 | Toolbox stubs + toolbox hello MacBinary + validation | **Complete** |
| WASM phase1 | Build `retro-cc.wasm` + JS API | Not started |
| WASM phase2 | Browser integration + packaging | Not started |

## File layout

```
wasm-retro-cc/
└── spike-pcc/             ← (this directory) archived PCC pipeline
    ├── include/           Shim headers (mac68k-packed Toolbox APIs)
    ├── stubs/             Hand-written A-trap bridge stubs (`libtoolbox-stubs.s`)
    ├── hello.c            Phase 0 probe (no Toolbox)
    ├── hello_toolbox.c    Phase 2 probe (full Toolbox init)
    ├── hello_initgraf*.c  Bisect probes (InitGraf, H1, H2)
    ├── mac.ld             Linker script for Phase 0 bare-metal ELF
    ├── crt0_minimal.s     Phase 0 _start stub
    ├── pcc.patch          Patches to PCC m68k backend
    ├── inspect_macbinary.py  Structural validator
    ├── run-spike.sh       Phase 0/1/2 driver
    ├── ARCHIVE.md         Why this is archived
    └── docs/
        ├── architecture-pcc.md  (this file)
        ├── abi.md              m68k calling convention reference
        └── header-strategy.md  Shim header design decisions
```

Repo top-level (Phase 2, current):

```
wasm-retro-cc/
├── README.md           Project overview (Phase 2 = Retro68 GCC → WASM)
├── LEARNINGS.md        Research findings across both phases
├── CONTRIBUTING.md     Setup, workflow, settled decisions
└── .github/workflows/spike.yml  Manual workflow that exercises this archive
```

## JS API (planned, not implemented)

```ts
import createRetroCC from "./retro-cc.js";

const module = await createRetroCC();

const result = await module.compile({
  files: { "main.c": sourceText },
  entryPoint: "main.c",
});

if (result.ok) {
  // result.binary: Uint8Array — MacBinary II
  // result.warnings: string[]
} else {
  // result.errors: Array<{ file, line, col, message }>
}
```

## Consumption by classic-vibe-mac

Same lazy-load pattern as `wasm-rez`:
1. `retro-cc.js` and `retro-cc.wasm` served as static assets
2. `<script>` tag injected into the page only when user triggers "Compile & Run"
3. MEMFS provides file I/O; no network calls during compilation
