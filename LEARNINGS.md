# LEARNINGS.md — Research findings and technical discoveries

This file is a living record of what we know, what we tried, and what surprised us.
Agents and contributors should read this before starting work and update it when they
discover something non-obvious.

---

## The A-trap problem (and why it's not a blocker for user code)

**What it is:**  
The Retro68 SDK headers declare Mac Toolbox ROM calls using a GCC m68k-exclusive syntax:

```c
/* Inside <Windows.h> */
pascal WindowPtr NewWindow(Rect *boundsRect, ConstStr255Param title,
    Boolean visible, short theProc, WindowPtr behind,
    Boolean goAwayFlag, long refCon)
    = { 0xA913 };
```

The `= { 0xA913 }` tells GCC to generate a TRAP instruction (opcode 0xA913) instead of
a normal function call. This is entirely GCC m68k-specific. No other compiler (Clang,
TCC, PCC, chibicc) can parse or emit it.

**Why it initially seems fatal:**  
Any WASM C compiler that tries to include `<Windows.h>` will hit a parse error on the
`= { 0xA913 }` syntax and fail immediately.

**Why it's actually solvable:**  
User-written Classic Mac C code never contains A-trap syntax. It just calls `NewWindow(...)`.
The A-trap syntax lives only in the SDK headers.

**The solution: pre-compiled stubs + shim headers**  
Retro68 GCC (which does understand A-trap syntax) can pre-compile all Toolbox
entry points into a static library (`libretro68.a`, `crt0.o`, etc.) in CI. The WASM
compiler never sees the headers — it only links against the pre-built archive. We provide
shim headers with plain `extern` declarations:

```c
/* Our shim: retro-cc/include/Windows.h */
extern WindowPtr NewWindow(Rect *boundsRect, ConstStr255Param title,
    Boolean visible, short theProc, WindowPtr behind,
    Boolean goAwayFlag, long refCon);
```

The ABI is identical — calling convention is the same (it's a ROM trap either way,
dispatched through the pre-compiled stub).

**Status:** Strategy confirmed, not yet implemented. Phase 0 validates the ABI match.

---

## Compiler candidates (researched 2025-05)

### PCC (Portable C Compiler) — leading candidate

- **m68k backend:** ✅ Ships `arch/m68k/{code.c, local.c, macdefs.h}` — actively maintained
- **WASM portability:** High — no `fork()`/`exec()` in the compiler proper (only in the
  driver wrapper). The compiler pipeline (preprocessing → parsing → codegen → assembly)
  is a single process.
- **Bundle size estimate:** 1.5–3 MB gzipped (small codebase, ~130K LOC)
- **License:** BSD
- **A-trap syntax:** Not needed (user code doesn't contain it)
- **Risk:** PCC's m68k backend targets generic System V m68k ABI, not Mac-specific.
  Calling conventions, stack layout, and function entry/exit may differ from what Retro68's
  GCC emits. Phase 0 must validate this against known-good Retro68 output.
- **Source:** `arch/m68k/` in the PCC repo. Key files: `code.c` (instruction emission),
  `local.c` (register allocation, ABI), `macdefs.h` (machine constants).

### GCC (Retro68) — ruled out

- Perfect ABI match, A-trap support built in
- **But:** GCC compiled to WASM would be 80–150 MB (cc1 alone is 25 MB stripped)
- No known working example of GCC compiled to WASM exists
- Ruled out permanently unless WASM runtimes get dramatically faster at streaming

### LLVM/Clang M68k — ruled out

- M68k backend mainlined since LLVM 14 (experimental, ~90% test pass rate)
- Outputs ELF only — needs ELF→MacBinary conversion (doable but more work)
- **No A-trap syntax support** (and LLVM team has stated they won't implement it)
- Bundle would be 12–16 MB gzipped (Clang front end + M68k backend)
- Ruled out on bundle size alone. Revisit if LLVM M68k matures and bundle shrinks.

### TinyCC — ruled out (for now)

- No m68k backend (backends: i386, x86_64, ARM, ARM64, RISC-V)
- Would need a full 68k backend written from scratch (4–12 months)
- Very small, very WASM-friendly otherwise
- Keep in mind for the long term if someone wants to write the backend

### chibicc, lacc, cproc — ruled out

- None have a 68k backend
- Would need full backend work
- Not worth pursuing before validating PCC

---

## Emscripten notes

- Emscripten compiles C/C++ to WASM using LLVM as the backend
- Key flags for a compiler-in-WASM build:
  - `-sMEMORY64=0` — keep 32-bit addressing (68k output is 32-bit)
  - `-sALLOW_MEMORY_GROWTH=1` — source files can be large
  - `-sINITIAL_MEMORY=32MB` — PCC needs stack + heap for compilation
  - `-sFILESYSTEM=1` — PCC uses POSIX file I/O; Emscripten's MEMFS provides it
  - `-sEXPORTED_RUNTIME_METHODS=['FS','callMain']` — expose FS for file injection
- The wasm-rez project (see classic-vibe-mac) proves this exact pattern works:
  a C compiler (Rez) compiled via Emscripten with MEMFS, files injected, output read back
- **Watch out:** PCC's driver (`cc.c`) uses `fork()`/`execv()` to run preprocessor, compiler,
  assembler, linker as separate processes. Emscripten doesn't support `fork()`. We must
  link PCC's pipeline stages directly rather than through the driver.

---

## Mac Toolbox ABI basics (what PCC needs to get right)

Classic Mac 68k calling convention (Retro68 target):

- Parameters pushed right-to-left on stack (standard C)
- Pascal-style routines (`pascal` keyword): parameters pushed left-to-right
- Return values: 16-bit in D0, 32-bit in D0, larger values via pointer in A0
- A5 is the global data pointer (world register) — must be preserved across calls
- A7 is the stack pointer
- Registers A0, A1, D0, D1 are caller-saved; rest are callee-saved

**A-trap dispatch (how ROM calls work):**  
When user code calls `NewWindow(...)`, the pre-compiled stub:
1. Pushes parameters per the pascal calling convention
2. Executes `TRAP #1` with trap word 0xA913
3. The ROM interrupt handler dispatches to the Toolbox routine
4. Returns result in D0 or via stack

PCC must generate code compatible with this calling convention, especially for
`pascal`-declared functions (if we support the `pascal` keyword at all — Phase 0 will
determine if we need it or can ignore it for user code).

---

## wasm-rez pattern (our reference implementation)

This is what we're replicating. In classic-vibe-mac:

```
/public/wasm-rez/wasm-rez.js    ← Emscripten-generated JS loader
/public/wasm-rez/wasm-rez.wasm  ← the compiled Rez binary
```

Loaded lazily in `rez.ts`:
```ts
// Inject a <script> tag that loads wasm-rez.js
// wasm-rez.js's module init sets Module.FS (MEMFS)
// Write source to MEMFS, call Module.callMain(), read output from MEMFS
```

Our JS API (`retro-cc.ts` in classic-vibe-mac) will follow the identical pattern:
- `loadModule(baseUrl)` — lazy `<script>` injection, waits for `Module` to be ready
- `compile(files, appName)` — writes to MEMFS, calls compiler, reads `.bin` output
- Returns `{ ok, macBinary, diagnostics }`

---

## MacBinary format (what we need to output)

MacBinary II is the file format that packages Classic Mac files for transfer.
Structure (128-byte header + data fork + resource fork):

```
Offset  Size  Description
0       1     Zero (must be 0)
1       1     Filename length (1–63)
2       63    Filename (Pascal string)
65      4     File type (e.g., 'APPL' for application)
69      4     File creator (4-char code)
73      1     Finder flags (high byte)
74      1     Zero
75      2     Vertical position in folder
77      2     Horizontal position in folder
79      2     Folder ID
81      1     Protected flag
82      1     Zero
83      4     Data fork length
87      4     Resource fork length
...
```

For a minimal compiled app:
- **Data fork** = the compiled code (from the linker)
- **Resource fork** = can be empty initially (app runs but has no icon/menu)
- The `APPL` type and creator code are set by our output writer
- Retro68's `MakeAPPL` tool does the MacBinary assembly — we need to replicate its logic
  in C (compiled alongside PCC) or in JS.

Retro68's `MakeAPPL` source is in `Retro68/MakeAPPL/` — study this for the exact format.

---

## Headers we need to support (priority order)

Based on the classic-vibe-mac sample apps (hello-mac, pixel-pad, etc.):

**Tier 1 — needed for any windowed app:**
- `<Types.h>` — basic Mac types (Rect, Point, OSErr, etc.)
- `<Quickdraw.h>` — drawing primitives (MoveTo, DrawString, etc.)
- `<Windows.h>` — window management (NewWindow, SetPort, etc.)
- `<Events.h>` — event loop (WaitNextEvent, Button, etc.)
- `<Fonts.h>` — InitFonts, TextSize, etc.
- `<Memory.h>` — NewHandle, DisposeHandle, etc.

**Tier 2 — needed for menus and dialogs:**
- `<Menus.h>`, `<Dialogs.h>`, `<Controls.h>`

**Tier 3 — nice to have:**
- `<TextEdit.h>`, `<Files.h>`, `<OSUtils.h>`, `<Gestalt.h>`

**Not initially needed:**
- `<Sound.h>`, `<Serial.h>`, `<AppleTalk.h>`, network headers

The shim header strategy (Option A in README) means we hand-author these.
Start with Tier 1 — it covers ~80% of what the sample apps use.

---

## Linker requirements

The linker must:
1. Take one or more m68k ELF `.o` files (PCC output) + `libretro68.a` (archive)
2. Resolve symbols (user code calling Toolbox stubs in the archive)
3. Output a flat binary (code segment) ready for MacBinary assembly

Options:
- **Retro68's own linker** (via Emscripten) — the most compatible choice but adds bundle size
- **GNU ld** (m68k target) — standard but large
- **ld.lld** (LLVM) — smaller, WASM-friendly, supports m68k ELF
- **Custom minimal linker** in C — for Phase 0 spike, a simple relocating linker that
  handles the specific output of PCC + libretro68.a may be 500–1000 lines

Decision deferred to Phase 0. Start with: can GNU ld (m68k) be compiled via Emscripten?

---

## Questions still open

- [ ] Does PCC's m68k backend emit 68000-compatible code (no 68020+ instructions)?
- [ ] Does PCC support the `pascal` calling convention modifier? (may need to add it)
- [ ] Can we extract `libretro68.a`, `crt0.o` from `ghcr.io/autc04/retro68:latest`
      without rebuilding the whole toolchain? (likely yes, it's just `docker run` + `docker cp`)
- [ ] Does Retro68's `crt0.o` have any GCC-specific relocations that another linker can't process?
- [ ] What is the minimum set of Toolbox functions needed for a "Hello World" windowed app?
      (Target: write the Tier 1 shim headers with exactly those functions.)
- [ ] Can the resource fork be completely empty and still produce a bootable app?
      (Classic Mac Finder requires 'BNDL' and 'FREF' resources for the icon, but apps can
      run without them — they just show a generic icon.)
