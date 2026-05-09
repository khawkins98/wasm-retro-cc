# Architecture — wasm-retro-cc

## Overview

wasm-retro-cc compiles user-written C code for the classic Macintosh 68k platform, entirely
in the browser — no server required.

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

### PCC (the compiler, compiled to WASM)

**Source:** https://github.com/IanHarvey/pcc  
**Why PCC:** ~130K LOC, has an existing `arch/m68k/` backend, C90 compliant output.
LLVM was ruled out (12–16 MB gzipped). GCC/Retro68 was ruled out (80–150 MB).

**What PCC does NOT handle:**
- The Retro68 driver (`cc.c`) — uses `fork()`/`execv()`, incompatible with Emscripten
- Assembler — we use the pre-compiled `.o` stubs from Retro68 instead
- Linker — we use a WASM-compiled `ld` (from GNU binutils, minimal build)

**Compilation pipeline inside WASM:**

```
source.c
  └─▶ [PCC frontend + m68k codegen] → assembly text (MEMFS)
        └─▶ [GNU as] → .o file (MEMFS)
              └─▶ [GNU ld + libretro68.a + libc.a] → ELF binary (MEMFS)
                    └─▶ [MacBinary wrapper] → .bin blob → returned to browser
```

### Shim headers (`src/include/`)

Plain C90 `extern` declarations for the Mac Toolbox. These replace Retro68's
A-trap-based SDK headers, which use GCC-specific syntax PCC cannot parse.

See `docs/header-strategy.md` for the detailed design.

### Pre-compiled stubs (`src/stubs/`)

`libretro68.a` and `libc.a` are built by CI using the real Retro68 GCC cross-compiler.
These contain the actual Toolbox trampoline code. They are committed as binary artifacts
and updated only when Retro68 releases a new version.

The stubs are embedded in the WASM bundle via Emscripten's `--preload-file`.

### MacBinary wrapper

After linking produces an ELF binary, a small JavaScript utility wraps the code segment
in a MacBinary II header so the emulator's HFS patcher can inject it into a disk image.

Format reference: see `LEARNINGS.md` → MacBinary II Format section.

## Build phases

| Phase | Goal | Status |
|-------|------|--------|
| 0 | Validate PCC m68k backend against Retro68 stubs natively | Not started |
| 1 | WASM build: PCC alone (no linker), no browser integration | Not started |
| 2 | WASM build: full pipeline (PCC + as + ld + MacBinary wrapper) | Not started |
| 3 | Browser integration with classic-vibe-mac playground | Not started |
| 4 | npm package release as `wasm-retro-cc` | Not started |

## File layout

```
wasm-retro-cc/
├── src/
│   ├── include/        Shim headers (Tier 1 + Tier 2 Mac Toolbox APIs)
│   ├── stubs/          Pre-compiled .a files (built by CI)
│   └── main.c          WASM entry point — JS-callable compile() function
├── spike/
│   ├── hello.c         Phase 0 test program
│   └── run-spike.sh    Phase 0 automation
├── docs/
│   ├── architecture.md (this file)
│   ├── abi.md          m68k calling convention reference
│   └── header-strategy.md  Shim header design decisions
├── .github/
│   ├── extensions/     Copilot CLI agents
│   ├── workflows/      CI (stub extraction, WASM build, tests)
│   └── ISSUE_TEMPLATE/ Bug report, feature request, header request
├── LEARNINGS.md        Research findings and experiment results
├── CONTRIBUTING.md     Setup, workflow, settled decisions
└── README.md           PRD / project overview
```

## JS API (planned)

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
