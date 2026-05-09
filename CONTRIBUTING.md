# Contributing to wasm-retro-cc

This is a research-heavy project in early feasibility phase. Before writing any code,
read `README.md` (the PRD) and `LEARNINGS.md` (everything we already know).
Working through unsolved problems twice wastes everyone's time.

---

## Project status

We are in **Phase 0 — Feasibility Spike**. The goal is to answer a small set of concrete
questions before committing to the full implementation. See `README.md` for the phased plan.

The primary output of Phase 0 is: a shell script that compiles `spike/hello.c` to a raw
68k binary using PCC natively (not yet WASM), linked against pre-compiled Retro68 stubs.
If that works, Phase 1 (WASM compilation) is unblocked.

---

## Prerequisites

### For the feasibility spike (Phase 0)

- Docker (to extract Retro68 stubs from the container image)
- PCC source code (`git clone https://github.com/IanHarvey/pcc`)
- Emscripten SDK for WASM experiments
- A basic understanding of m68k assembly (helpful but not required)

```bash
# Pull the Retro68 image and extract pre-compiled stubs
docker pull ghcr.io/autc04/retro68:latest
docker create --name retro68-tmp ghcr.io/autc04/retro68:latest
docker cp retro68-tmp:/Retro68-build/toolchain/m68k-apple-macos/lib/. spike/retro68-stubs/
docker cp retro68-tmp:/Retro68-build/toolchain/m68k-apple-macos/include/. spike/retro68-headers/
docker rm retro68-tmp
```

### For the full WASM build (Phase 1+)

- [Emscripten SDK](https://emscripten.org/docs/getting_started/downloads.html)
- CMake 3.20+
- Python 3.9+ (for header pre-processing scripts)
- Node.js 20+ (for the JS API wrapper tests)

---

## Repository layout

```
wasm-retro-cc/
├── README.md              ← PRD — read this first
├── LEARNINGS.md           ← Technical discoveries — read this second
├── CONTRIBUTING.md        ← You are here
│
├── spike/                 ← Phase 0 feasibility work
│   ├── hello.c            ← Minimal test program (no A-trap in user code)
│   ├── retro68-stubs/     ← Extracted from Docker image (gitignored)
│   ├── retro68-headers/   ← Extracted from Docker image (gitignored)
│   └── run-spike.sh       ← Automates the Phase 0 test
│
├── src/
│   ├── compiler/          ← PCC submodule or vendored copy (Phase 1)
│   ├── linker/            ← m68k linker (Phase 1)
│   ├── macbinary/         ← MacBinary II writer in C (Phase 1)
│   ├── include/           ← Shim headers (extern declarations, no A-trap)
│   │   ├── Types.h
│   │   ├── Quickdraw.h
│   │   ├── Windows.h      ← Plain extern decls — no = { 0xAxx } syntax
│   │   └── ...
│   └── js/
│       ├── retro-cc.ts    ← JS/TS API wrapper (same pattern as wasm-rez)
│       └── retro-cc.test.ts
│
├── docs/
│   ├── architecture.md    ← Detailed component diagram
│   ├── abi.md             ← Mac 68k calling convention notes
│   └── header-strategy.md ← Shim headers vs auto-processed headers
│
└── .github/
    ├── extensions/        ← Copilot CLI agent definitions
    ├── workflows/         ← CI: extract stubs, build WASM, run tests
    └── ISSUE_TEMPLATE/
```

---

## Development workflow

### Phase 0 spike

```bash
# 1. Extract Retro68 stubs (one-time setup)
bash spike/run-spike.sh setup

# 2. Compile the test program natively with PCC
bash spike/run-spike.sh compile

# 3. Check output against Retro68 reference
bash spike/run-spike.sh compare
```

### Writing shim headers

Shim headers live in `src/include/`. They must:
- Use only standard C syntax (no GCC extensions)
- Declare Toolbox functions with the correct signature and `pascal` modifier
  (if PCC supports `pascal`; otherwise use `__attribute__((pascal))` or equivalent)
- Not include any `= { 0xAxx }` A-trap syntax
- Include the correct Mac type definitions from `<Types.h>`

When adding a new header, add a corresponding entry to `docs/header-strategy.md`
noting which functions are included and which were deliberately excluded.

### Testing

We don't have a test suite yet. For Phase 0, "the test" is: does the spike compile
`hello.c` and produce a binary that matches Retro68's output closely enough to boot
in the emulator?

For Phase 1+, tests will be:
1. Unit: does the compiler accept valid C and reject invalid C?
2. Integration: does the MacBinary output boot in the classic-vibe-mac emulator?
3. Regression: does the compiled hello-mac sample app still work after changes?

---

## Key decisions already made

These are settled. Don't re-open them without a very good reason.

| Decision | Rationale |
|---|---|
| PCC as compiler | Only small C compiler with existing m68k backend |
| Pre-compiled stubs (not in-browser compilation of SDK) | A-trap syntax is GCC-only; users never write it |
| Shim headers (Option A before Option B) | Hand-authored extern decls are simpler and faster to ship |
| Same JS API pattern as wasm-rez | Consistency with classic-vibe-mac; proven to work |
| No C++ initially | Adds significant complexity; sample apps are all C |
| 68000 only (no 68020+) | The emulator targets a generic 68k Mac; 68020+ instructions would crash |

---

## Key decisions still open

Document your reasoning when you make these:

- [ ] Which linker to use (GNU ld, ld.lld, or custom)?
- [ ] Can `pascal` calling convention be ignored for user code, or must PCC support it?
- [ ] Empty resource fork vs minimal resource fork (app icon, menu bar)?
- [ ] npm package name and publishing target?

---

## Code conventions

- C code (compiler, linker, MacBinary writer): C99, no VLAs, no `alloca`
  (Emscripten handles these but they complicate stack size budgeting)
- JavaScript/TypeScript: ES2022 modules, no CommonJS
- No dependencies in the JS wrapper beyond what Emscripten generates
- Comments explain *why*, not *what* — the code shows what

---

## Asking for help

Open an issue. Use the templates in `.github/ISSUE_TEMPLATE/`.

If you're stuck on the ABI or Mac Toolbox internals, check:
- Inside Macintosh (available free at [vintageapple.org](http://www.vintageapple.org/inside_r/))
- The Retro68 source (especially `libretro68/` and `CIncludes/`)
- LEARNINGS.md (check if someone already hit the same wall)
