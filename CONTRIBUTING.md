# Contributing to wasm-retro-cc

This is a research-heavy project. Before writing any code,
read `README.md` (the PRD) and `LEARNINGS.md` (everything we already know).
Working through unsolved problems twice wastes everyone's time.

---

## Project status

Current state:

- ✅ Native spike pipeline complete through Phase 2 (`spike/run-spike.sh`)
- ✅ CI (`.github/workflows/spike.yml`) green for phase0/phase1/phase2
- ❌ Browser WASM module (`retro-cc.wasm`) not started yet

See `README.md` for the latest phased plan and scope.

---

## Prerequisites

### For the implemented spike pipeline

- Docker (to extract Retro68 stubs from the container image)
- Python 3 (used by verify scripts in `run-spike.sh`)
- A basic understanding of m68k assembly (helpful but not required)

```bash
# Setup + full spike run (native)
bash spike/run-spike.sh setup
bash spike/run-spike.sh build-pcc
bash spike/run-spike.sh compile
bash spike/run-spike.sh link
bash spike/run-spike.sh verify
bash spike/run-spike.sh build-stubs
bash spike/run-spike.sh compile-toolbox
bash spike/run-spike.sh link-toolbox
bash spike/run-spike.sh verify-toolbox
```

### For future WASM work (not started)

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
├── spike/                 ← Native spike pipeline work
│   ├── hello.c            ← Minimal test program (no A-trap in user code)
│   ├── hello_toolbox.c    ← Toolbox test program
│   ├── mac.ld             ← Linker script
│   └── run-spike.sh       ← Automates phase0/phase1/phase2
│
├── src/
│   ├── include/           ← Shim headers (extern declarations, no A-trap)
│   │   ├── Types.h
│   │   ├── Quickdraw.h
│   │   ├── Windows.h      ← Plain extern decls — no = { 0xAxx } syntax
│   │   └── ...
│   └── stubs/
│       └── libtoolbox-stubs.s
│
├── docs/
│   ├── architecture.md    ← Detailed component diagram
│   ├── abi.md             ← Mac 68k calling convention notes
│   └── header-strategy.md ← Shim headers vs auto-processed headers
│
└── .github/
    ├── extensions/        ← Copilot CLI agent definitions
    ├── workflows/         ← CI: spike phase0/phase1/phase2
    └── ISSUE_TEMPLATE/
```

---

## Development workflow

### Spike pipeline

```bash
# 1. Extract Retro68 stubs (one-time setup)
bash spike/run-spike.sh setup

# 2. Compile and link base hello
bash spike/run-spike.sh compile
bash spike/run-spike.sh link
bash spike/run-spike.sh verify

# 3. Build toolbox stubs and toolbox hello
bash spike/run-spike.sh build-stubs
bash spike/run-spike.sh compile-toolbox
bash spike/run-spike.sh link-toolbox
bash spike/run-spike.sh verify-toolbox
```

### Writing shim headers

Shim headers live in `src/include/`. They must:
- Use only standard C syntax (no GCC extensions)
- Declare Toolbox functions with correct signatures compatible with the stubs
- Not include any `= { 0xAxx }` A-trap syntax
- Include the correct Mac type definitions from `<Types.h>`

When adding a new header, add a corresponding entry to `docs/header-strategy.md`
noting which functions are included and which were deliberately excluded.

### Testing

Current test strategy:
1. `spike.yml` CI phases run end-to-end compile/link/verify commands
2. `verify` / `verify-toolbox` enforce MacBinary APPL + non-empty resource fork
3. Manual browser boot remains a human validation step (not CI-automated yet)

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
| 68020+ output accepted | PCC emits 68020+ instructions; BasiliskII target class supports this |

---

## Key decisions still open

Document your reasoning when you make these:

- [ ] Which linker strategy to use in-browser (reuse Retro68 linker path vs custom)?
- [ ] Final JS/WASM API shape and packaging target
- [ ] Empty resource fork vs minimal resource fork (app icon, menu bar)?

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
