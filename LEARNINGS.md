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

**Status:** Strategy confirmed. Phase 0 spike validates the ABI match.

**Pascal calling convention note:** Our shim headers define `#define pascal` as empty (a no-op macro). This means PCC sees all Toolbox functions as standard C — right-to-left argument push, caller cleans. The Retro68 pre-compiled stubs handle the actual Mac calling convention internally. PCC never needs to understand `pascal` for user code. This must be validated as an explicit Phase 0 exit criterion (not just assumed).

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
- **Correct configure target:** `--target=m68k-unknown-apple` (NOT `m68k-unknown-elf`).
  PCC's `configure.ac` only activates the m68k backend when the OS token is `apple`,
  mapping to `abi=classic68k`. Any other OS token (elf, linux, netbsd without m68k) either
  doesn't set `targmach=m68k` or isn't listed, triggering "not (yet) supported" error.
  The `CLASSIC68K` define that results does NOT appear in the m68k backend source — code
  generation is identical regardless; the define mainly affects the configure-generated
  `config.h` and runtime library selection.
- **Required configure flags:** `--target=m68k-unknown-apple --disable-nativefp`
  - `--disable-nativefp` is essential: default (`nativefp=yes`) adds `-DNATIVE_FLOATING_POINT`
    which hides `union flt` in `mip/manifest.h`, causing `arch/m68k/local.c:ninval()` to fail
    with "flt defined as wrong kind of tag". Without native FP, the softfloat implementation
    compiles correctly (safe for m68k cross-compilation; no behaviour difference for integer code).
  - Note: `local.c:picsymtab()` uses `strlcpy`/`strlcat` without a declaration — these produce
    warnings on Linux but link correctly on Ubuntu 24.04 (glibc 2.39+).
- **Binary naming:** After `make -C cc/ccom`, the compiler proper is at
  `cc/ccom/m68k-unknown-apple-ccom`. Use `find cc/ccom -name '*ccom' -type f` to locate it.

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
- **Resource fork** = ALL executable code (`CODE 0`, `CODE 1`, etc.), `SIZE` resource; code
  lives entirely in the resource fork, not the data fork
- **Data fork** = nearly empty for a pure 68k APPL (Retro68 emits ~20 bytes of CFM stub for
  compatibility; this is NOT the compiled code)
- The `APPL` type and creator code are set by our output writer
- Retro68's `Elf2Mac` (Object.cc) does the MacBinary assembly — we need to replicate its
  logic in C (compiled alongside PCC) or in JS.

Retro68's `Elf2Mac` source is in `Retro68/Elf2Mac/` — study `Object.cc` for the exact format.

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
- **Elf2Mac (Retro68) — preferred:** Retro68 ships `Elf2Mac/` — a GNU ld wrapper that
  generates a Mac-specific linker script and then runs GNU ld, followed by `Object.cc`
  which converts the linked ELF to Mac binary format (CODE/DATA resources, resource fork).
  The ELF→Mac conversion code (`Object.cc`, `Section.cc`, `SegmentMap.cc`, `Reloc.cc`,
  `Symbol.cc`, `Symtab.cc`) is ~5 C++ files with no `fork()`/`exec()`. This is the
  WASM-compilable piece — it reads a linked ELF and emits MacBinary. The GNU ld step
  still needs a real linker (compiled separately or as a WASM module).
  **This is the right approach**: it gives ABI-compatible MacBinary output for free and
  sidesteps the risk of writing incompatible Mac binary assembly.
- **GNU ld** (m68k target) — standard, battle-tested, larger bundle
- **ld.lld** (LLVM) — smaller, WASM-friendly, supports m68k ELF
- **Custom minimal linker** in C — high risk: Mac-specific section handling is non-trivial

**Linker risk is HIGH:** Mac binary format requires specific CODE/DATA resource layout,
A5-world setup, jump tables, and relocation handling that differ from standard ELF.
Getting this wrong produces silently broken binaries that crash or fail to load.
**Decision:** Use Elf2Mac's Object.cc (compiled to WASM) for the ELF→Mac step; use
GNU ld or lld for the linking step. Validate in Phase 0 that Elf2Mac accepts PCC's ELF.

---

## PCC m68k backend — critical findings (researched 2025-05)

### CLASSIC68K macro does nothing

`CLASSIC68K` is defined in `config.h` by configure when `target_os=apple`, but there are
**zero `#ifdef CLASSIC68K` guards** anywhere in the m68k backend source files
(`macdefs.h`, `local.c`, `code.c`, `local2.c`, `table.c`, `order.c`).
The classic68k and ELF m68k builds produce byte-for-byte identical output.
The `CLASSIC68K` define only affects `configure.ac` logic (ABI name, runtime lib selection)
and does not change code generation at all.

### PCC emits 68020+ instructions (important caveat)

The m68k backend generates instructions not available on 68000-class CPUs:
- `extb.l` (char→long sign-extend) — 68020+ only (68000 has only `ext.w`/`ext.l`)
- `muls.l`, `divu.l`, `divs.l` (32-bit multiply/divide) — 68020+ only
- `divsl.l`/`divul.l` (64-bit result divide) — 68020+ only
- `link.l` (large stack frames) — 68020+ only
- Float ops (`fmove`, `fdiv`, etc.) require 68881/68882 FPU

**Impact:** Binaries compiled with PCC will not run on Mac 128K/512K/Plus/SE/Classic
(which have a 68000). They will work on Mac II, IIx, IIcx, IIci, SE/30, Quadra, etc.
(68020/030/040). For Phase 0 this is acceptable if classic-vibe-mac emulates 68020+
(BasiliskII emulates 68020 by default). For Phase 1, evaluate GCC or a patched PCC
with `-m68000` if 68000 targets are required.

### PCC output format (section directives)

`code.c:setseg()` and `code.c:defloc()` emit ELF-style section directives:
`.section .text`, `.globl`, `.type foo,@function`. There are no `#ifdef CLASSIC68K`
guards for Mac-specific section names. This is fine — we convert ELF to Mac binary
format via Elf2Mac's Object.cc, so ELF output is exactly what we want.

### PCC A5-world support: none

Classic Mac uses A5 as the global base register. PCC uses absolute addressing for
globals (no A5-relative addressing). This is handled by Retro68's crt0 / Elf2Mac —
the linker and Object.cc build the A5 world from the ELF layout, not the compiler.

### PCC calling convention (compatible with our stub strategy)

PCC m68k uses standard cdecl:
- Right-to-left argument push
- JSR for function calls
- Caller cleans stack (`add.l #N,%sp` after call)
- Return: D0 (int/pointer), FP0 (float)
- Frame pointer: A6; stack pointer: A7

This is compatible with GCC m68k cdecl, so our pre-compiled Retro68 stubs will
work correctly when called from PCC-compiled user code.

### config.sub + apple target (solved)

`config.sub` (2015 version bundled with PCC) treats `apple` as a **vendor alias**,
not an OS token, so it sets `os=""` and the triple becomes `m68k-apple-` with empty OS.
`configure.ac`'s `case "$target_os" in apple)` never matches.

**Fix:** Pre-populate `config.cache` with `ac_cv_target=m68k-unknown-apple` so
`AC_CANONICAL_TARGET` uses the cached value and skips `config.sub` validation.
Confirmed working in CI run 6+ (configure emits `-Dos_apple -Dmach_m68k` in build flags).

### ccconfig.h (solved by building ccom only)

`cc/cc/cc.c` (the driver wrapper) includes `ccconfig.h`, which is not in the PCC repo
and is not generated by `configure`. **Solution:** Build only `cc/ccom/` (the compiler
proper). `ccom` does not include `ccconfig.h`. Invoke `ccom` directly:
1. `gcc -E` to preprocess (feeds shim headers, expands macros)
2. `ccom hello.i hello.s` to compile preprocessed C to m68k assembly
3. `m68k-linux-gnu-as -m68020` to assemble (must use -m68020; PCC emits 68020+ opcodes)
4. `m68k-linux-gnu-ld` to link against Retro68 stubs

### union flt bug in local.c (solved)

`arch/m68k/local.c:ninval()` casts `p->n_dcon` to `(union flt *)`, but `cc/ccom/pass1.h`
declares `struct flt`, not `union flt`. GCC rejects this with "flt defined as wrong kind
of tag". This is a bug in PCC's m68k backend, present regardless of `--disable-nativefp`.

**Fix:** Patch `local.c` after clone (in `cmd_build_pcc`):
```bash
sed -i 's/(union flt \*)/(struct flt *)/g' arch/m68k/local.c
```

### --disable-nativefp (still needed, different reason)

Even after fixing `union flt`, `--disable-nativefp` is the correct flag for cross-compilation.
It prevents PCC from using host-native floating point for m68k targets.
Without it, PCC embeds host FP constants directly, which produces incorrect cross-compiled code.

### softfloat.c — USE_IEEEFP_* missing from m68k macdefs.h (solved)

`common/softfloat.c` requires `USE_IEEEFP_32`, `USE_IEEEFP_64`, and `USE_IEEEFP_X80` to
compile. These macros tell softfloat what IEEE float formats the target uses and must be
defined in each arch's `macdefs.h`. The i386 and amd64 backends define all three; the m68k
backend never did — a clear omission.

**Fix:** Append the three defines to `arch/m68k/macdefs.h` before building:
```bash
printf '\n/* floating point definitions (required by softfloat.c) */\n#define USE_IEEEFP_32\n#define USE_IEEEFP_64\n#define USE_IEEEFP_X80\n' >> arch/m68k/macdefs.h
```

Classic Mac float/double map to IEEE 32/64; long double to Apple SANE 80-bit extended
(USE_IEEEFP_X80 is the closest match — Intel x80, same bit count, slightly different
96-bit storage on m68k). Phase 0 code uses no floating point; the exact semantics don't
matter as long as softfloat.c compiles.

### GCC 10+ -fno-common: lineno multiple definition (solved)

PCC's `scan.l` (line 204) and `mip/common.c` (line 76) both declare `int lineno;` as a
tentative global. Under GCC < 10 (which defaulted to `-fcommon`), these merged into a
single COMMON symbol. GCC 10+ defaults to `-fno-common`, treating both as strong
definitions — causing a multiple-definition linker error.

**Fix:** After configure generates `cc/ccom/Makefile`, patch CFLAGS to add `-fcommon`:
```bash
sed -i 's/^CFLAGS = /CFLAGS = -fcommon /' cc/ccom/Makefile
```
This only affects the PCC vendor build, not any code compiled by PCC.

---

### Retro68 lib directory — actual contents (verified 2025-05)

The Docker image's `m68k-apple-macos/lib/` contains:
- `libretrocrt.a` — C runtime (24K): `_start`, `qd`, malloc, syscalls, relocations
- `libc.a` (5.2MB), `libg.a` (5.2MB) — standard C library
- `libm.a` — math library
- `libInterface.a` → symlink to `toolchain/multiversal/lib68k/libInterface.a`
- `libRetroConsole.a`, `libstdc++.a`, `libsupc++.a`
- `ldscripts/` — GNU ld scripts for m68k ELF targets

**Critical: there is NO `crt0.o` or `libretro68.a`** — earlier scripts referenced these
incorrectly. The startup object is inside `libretrocrt.a`.

### libInterface.a — does NOT contain Toolbox function stubs

`libInterface.a` (20K) contains only a handful of OS-level stubs with UPPERCASE names:
`GESTALT`, `REPLACEGESTALT`, `MAXMEM`, `DELAY`, `DATETOSECONDS`, etc.

It does **NOT** contain stubs for QuickDraw, Window Manager, Font Manager, or other
high-level Toolbox managers (InitGraf, Button, NewWindow, etc.).

In Retro68, those Toolbox functions are emitted as inline A-trap instructions by the
compiler when using Retro68's own `ONEWORDINLINE(0xTRAP)` header macros.

**Implication for wasm-retro-cc:** Our shim headers declare these as `extern C` functions.
We need a `libtoolbox-stubs.a` providing each function as a small assembly stub.

**IMPORTANT (corrected 2025-05):** InitGraf is a **stack-based Pascal** trap (NOT register-based).
The ROM reads the argument from the stack and cleans it itself (callee-clean Pascal convention).
A correct stub must bridge C cdecl (caller-clean) to Pascal (callee-clean) to avoid double-clean:
```asm
.globl InitGraf
InitGraf:
    /* C cdecl: SP → [ret_to_PCC] [thePort (4B)] */
    move.l (sp)+, a0       /* pop ret addr; SP → [thePort] */
    .word 0xA86E            /* ROM reads thePort, cleans 4 bytes from stack */
    subq.l #4, sp           /* restore 4 bytes so PCC's addq.l #4,sp balances */
    jmp (a0)
```
See `src/stubs/libtoolbox-stubs.s` for all 12 trap stubs.
This stub library is a Phase 1 deliverable, assembled once with `m68k-linux-gnu-as` and
bundled with the WASM module.

### libretrocrt.a — startup requires many linker-defined symbols

`start.c.obj` references `Retro68Relocate` → pulls in `relocate.c.obj`, which requires:
- `__CTOR_LIST__`, `__CTOR_END__`, `__DTOR_LIST__`, `__DTOR_END__` (constructor/destructor tables)
- `__EH_FRAME_BEGIN__` (exception handling frame pointer)
- `__init_section`, `__init_section_end`, `__fini_section`, `__fini_section_end`
- `_etext`, `_edata`, `_sbss`, `_ebss` (section boundary addresses)

These must be provided by the linker script. `mac.ld` now includes all of them via `PROVIDE`
so linking with `libretrocrt.a` will work in Phase 1.

### Phase 0 linking: crt0_minimal.s

For Phase 0, we avoid linking `libretrocrt.a` to eliminate the above complexity.
Instead, `spike/crt0_minimal.s` provides a trivial `_start`:
```asm
_start:
    jsr  main
    .word 0xA9F4    /* ExitToShell A-trap */
```
This proves PCC compilation + assembly without depending on the full Retro68 CRT.
Phase 1 will switch to `libretrocrt.a + libc.a + libInterface.a + libtoolbox-stubs.a`.

---

## Classic Mac execution model — key facts (researched 2025-05)

### The classic-vibe-mac pipeline

`classic-vibe-mac` does NOT load MacBinary directly. The full pipeline is:

```
MacBinary (.bin)   ← output of wasm-retro-cc / Retro68
    ↓  hfs-patcher.ts
    Injects MacBinary into pre-formatted empty HFS volume (empty-secondary.dsk)
    ↓
HFS disk image (.dsk)
    ↓  BasiliskII (WASM)
    Mac System software loads app normally (as if from a real disk)
    ↓
Running app
```

**Implication:** `retro-cc.wasm` only needs to return `{ ok, macBinary: Uint8Array }`.
The HFS patching lives in `classic-vibe-mac` JS code, not in this project.

### MacBinary format — precise layout (authoritative from build.ts)

```
[Header — 128 bytes, CRC16-CCITT over first 124 bytes]
  +0:   uint8  = 0 (version)
  +1:   uint8  filename length
  +2:   char[63] filename
  +65:  OSType file type ('APPL')
  +69:  OSType creator
  +73:  uint8  Finder flags high byte
  +74:  uint8  = 0
  +83:  uint32 data fork length (big-endian)
  +87:  uint32 resource fork length (big-endian)
  +91:  uint32 creation date (Mac epoch = Unix + 2082844800 seconds)
  +95:  uint32 modification date
  +122: uint8  = 0x81 (MB II uploader version)
  +123: uint8  = 0x81 (min MB II version)
  +124: uint16 CRC16-CCITT of first 124 bytes

[Data fork — padded to 128-byte boundary]
[Resource fork — padded to 128-byte boundary]
```

CRC polynomial: 0x1021, init 0x0000, no reflection.

### Resource fork layout — precise offsets (from build.ts)

- Resource data area starts at absolute offset 256 within resource fork
- Each resource = uint32 size prefix + raw bytes
- Map header at `dataAreaLen + 256`:
  - Bytes 22–23: attrs (u16, = 0)
  - Bytes 24–25: type list offset from map start (= 28, always)
  - Bytes 26–27: name list offset from map start
- Type list (at map+28): u16 count−1, then per type: OSType(4) + u16 ref-count−1 + u16 refListOffset
- Ref list entries (12 bytes): i16 id + u16 nameOffset (0xFFFF=none) + u8 attrs + u24 dataOffset + u32 reserved
- **Ref list offset is relative to the start of the type list** (not absolute)

Source: `khawkins98/classic-vibe-mac:src/web/src/playground/build.ts`

### CODE resource layout (from System7 SegmentLoader)

**CODE 0** (16-byte header, then jump table entries at byte 16):
```
+0:  uint32  above-A5 size (jump table overhead + entries)
+4:  uint32  below-A5 size (application globals + QD globals ~750 bytes)
+8:  uint32  jump table size in bytes (= 8 × entry_count)
+12: uint32  A5-relative offset to jump table start (= 0x20)
+16: entries (8 bytes each)
```

**CODE N** (segments 1..N):
```
+0: uint16  entry offset from code body start
+2: uint16  flags/version (= 0)
+4: actual m68k code bytes
```

**Jump table entries** (8 bytes each):
- Unloaded: `3F3C NNNN A9F0 xxxx` (MOVE.W #segID, -(SP); _LoadSeg trap; 2 pad bytes)
- Loaded: `4EF9 AAAAAAAA xxxx` (JMP.L absolute; 2 pad bytes)

### Toolbox initialisation order (authoritative)

From shipping Mac application code (scripting/frontier):
```c
MaxApplZone();
MoreMasters(); MoreMasters(); MoreMasters();  // optional but recommended
InitGraf(&qd.thePort);   // MUST be first Toolbox call
InitFonts();
FlushEvents(everyEvent, 0);
InitWindows();
InitMenus();
TEInit();
InitDialogs(0L);
InitCursor();
```

`spike/hello.c` omits `MaxApplZone()` and `MoreMasters()`. These are safe to omit for a
minimal test (ROM sets up a default heap), but should be included in crt0's entry stub for
production use. `FlushEvents` placement (before vs. after `InitDialogs`) is functionally
equivalent.

### Minimum resources for a bootable app

- **CODE 0** — jump table (required by Mac OS loader)
- **CODE 1** — main code segment (required)
- **SIZE -1** — memory requirements (required; Finder won't launch without it)
- BNDL, FREF, ICN# — optional; omitting them shows a generic icon but app still runs

---

## Elf2Mac pipeline — how Retro68 converts ELF to Mac binary (researched 2025-05)

Retro68's `Elf2Mac` is a GNU ld wrapper that:
1. Generates a custom linker script for the Mac memory layout
2. Invokes the real `m68k-apple-macos-ld` (binutils)
3. Reads the resulting ELF via libelf
4. Emits a MacBinary file (resource fork) containing CODE/DATA/RELA/SIZE resources

The ELF→Mac conversion is in `Object.cc`, `Section.cc`, `SegmentMap.cc`, `Reloc.cc`,
`Symbol.cc`, `Symtab.cc` — ~5 C++ files with no `fork()`/`exec()`. These are WASM-compilable.

`crt0.o` (Retro68's `start.c`/`relocate.c`) performs PC-relative self-relocation at startup
before any globals can be accessed. This is what enables position-independent loading.

All Toolbox calls in Retro68-compiled code are either:
- Inlined 16-bit A-trap opcodes (via the `= { 0xA913 }` GCC syntax)
- Register-parameter wrappers generated by the Multiversal Interfaces

**Key insight:** When we use PCC + our shim stubs, the stubs handle the A-trap dispatch.
PCC never needs to generate A-trap opcodes — it just calls the stubs normally.

### CRITICAL: How to invoke Elf2Mac correctly (researched 2025-05)

**`m68k-apple-macos-gcc` has `--mac-flat` baked into its GCC specs at toolchain build time.**
Calling `m68k-apple-macos-gcc` with .o files produces a flat `.code.bin` code resource,
NOT a bootable MacBinary APPL. For a bootable MacBinary, you must call Elf2Mac DIRECTLY:

```bash
# Elf2Mac is at: /Retro68-build/toolchain/bin/Elf2Mac  (NOT m68k-apple-macos-ld)
RETRO68_REAL_LD=/Retro68-build/toolchain/bin/m68k-apple-macos-ld.real \
  /Retro68-build/toolchain/bin/Elf2Mac \
  --mac-single \
  -o hello.bin \
  hello.o \
  -L/Retro68-build/toolchain/m68k-apple-macos/lib \
  -lretrocrt -lc -lInterface -lgcc -lretrocrt
```

**Full library order explained:**
- `-lretrocrt`: CRT startup (`_start`, relocator, `_exit` → `ExitToShell`, malloc)
- `-lc`: newlib libc (exit, atexit, string functions); references back into retrocrt
- `-lInterface`: ALL Mac Toolbox A-trap stubs; needed by libretrocrt's syscalls.c
- `-lgcc`: soft-math helpers (`__mulsi3`, `__udivsi3`); needed by libretrocrt's malloc
- `-lretrocrt` (again): resolve circular libc ↔ retrocrt deps (libc needs `_exit`/malloc)

**`--mac-single` vs `--mac-flat`:**
- `--mac-single`: produces a complete MacBinary APPL (CODE 0 + CODE 1 resources). No SIZE resource.
- `--mac-flat`:   produces a flat binary code resource (not bootable as an app).
- `m68k-apple-macos-gcc` forces `--mac-flat` in its specs — never use it for building an app binary.

**`-lgcc` IS required** even when using PCC: `libretrocrt.a` was compiled by GCC targeting 68000,
so it emits calls to soft-math helpers (`__mulsi3`, `__udivsi3`). These live in `libgcc.a`.
PCC-compiled code itself doesn't need them, but Retro68's CRT does.

**`-lInterface` IS required**: `libretrocrt.a(syscalls.c.obj)` calls Mac File Manager and volume
traps (`FSWRITE`, `FSREAD`, `FSCLOSE`, `FLUSHVOL`, etc.) that are provided by `libInterface.a`.
This is Retro68's pre-built stub library for ALL Mac Toolbox calls. It must come after `-lc`.
For Phase 2 builds with custom stubs (`libtoolbox-stubs.a`): list our stubs before `-lInterface`
so our 12 functions shadow the Interface versions; Interface still provides everything else.

**Elf2Mac is a linker wrapper, not a converter:** It generates its own linker script and calls
the real ld. You CANNOT feed it a pre-linked ELF. Feed it object files + library flags.

---

## Questions still open

- [x] Does PCC's m68k backend emit 68000-compatible code? **NO** — emits 68020+ instructions
      (`extb.l`, `muls.l`, etc.). Acceptable for Phase 0 if classic-vibe-mac emulates 68020+.
- [x] What goes in data fork vs resource fork? **RESOURCE fork has ALL code.** Data fork ≈ 20 bytes.
- [x] What is `MoreMasters()`? Added to `Memory.h`. Allocates master pointer block.
- [x] Does `classic-vibe-mac` load MacBinary directly? **NO** — HFS patcher → disk image → BasiliskII.
- [x] Does PCC's `local.c` compile? Fixed by patching `union flt` → `struct flt`.
- [x] Does `crt0.o` exist in Retro68 lib dir? **NO** — startup is in `libretrocrt.a` (`_start` symbol).
- [x] Are Toolbox stubs in `libInterface.a`? **NO** — inline A-traps in Retro68 headers; we need our own stubs.
- [x] Does PCC `ccom` compile our preprocessed hello.i without crashing? **YES** — Phase 0 CI passing as of run 13.
- [x] Does PCC build on Ubuntu 24.04 with GCC 13? **YES** with three patches: `union flt → struct flt`,
      `USE_IEEEFP_32/64/X80` in m68k macdefs.h, and `-fcommon` in CFLAGS (all applied in `run-spike.sh`).
- [x] What are the exact calling conventions for Toolbox A-traps? **RESEARCHED (2025-05)** — see
      complete trap table below. Key: most are stack-based Pascal (callee-clean), FlushEvents is
      register-based (D0-packed), NewWindow is complex (8 args, Phase 2 TODO).
- [ ] Does Elf2Mac's --mac-single produce MacBinary that boots in classic-vibe-mac? (Phase 1 gate)
- [ ] Does the resulting MacBinary actually boot in classic-vibe-mac? (Phase 1 gate)
- [ ] Does classic-vibe-mac (BasiliskII) emulate 68000 or 68020+? (affects 68020-instruction concern)

---

## Mac Toolbox A-trap calling conventions (researched 2025-05)

**Stack-based Pascal calling convention (majority of traps):**
- Args pushed LEFT-TO-RIGHT by caller (first arg = deepest, last arg at top)
- ROM/callee cleans the stack after returning
- C cdecl pushes right-to-left; ROM expects left-to-right → bridge stubs required
- After ROM returns, SP is back at pre-push value; PCC's caller also adds back → DOUBLE CLEAN
- Fix: pop ret addr, fire trap, push N bytes back as padding, jmp to ret addr

| Function | Trap | Convention | Notes |
|---|---|---|---|
| `InitGraf` | `0xA86E` | Stack Pascal | SP+0 = GrafPtr* (4B); corrected — NOT register-based |
| `InitFonts` | `0xA8FE` | Stack Pascal | No args; trivial rts stub |
| `InitWindows` | `0xA912` | Stack Pascal | No args; trivial rts stub |
| `InitMenus` | `0xA930` | Stack Pascal | No args; trivial rts stub |
| `TEInit` | `0xA9CC` | Stack Pascal | No args; trivial rts stub |
| `InitDialogs` | `0xA97B` | Stack Pascal | SP+0 = ProcPtr (4B) |
| `SetPort` | `0xA873` | Stack Pascal | SP+0 = GrafPtr (4B) |
| `DrawString` | `0xA884` | Stack Pascal | SP+0 = Pascal str ptr (4B) |
| `MoveTo` | `0xA893` | Stack Pascal | SP+0=h (2B), SP+2=v (2B); C and Pascal layouts match |
| `Button` | `0xA974` | Stack Pascal | No args; returns Boolean in D0 |
| `NewWindow` | `0xA913` | Stack Pascal | 8 args, 26 bytes total; Phase 2 TODO |
| **`FlushEvents`** | **`0xA032`** | **Register (D0)** | D0[31:16]=stopmask, D0[15:0]=evmask; use SWAP |

**FlushEvents D0 packing (register-based):**
```asm
FlushEvents:  /* C: void FlushEvents(short evmask, short stopmask) */
    move.l (sp)+, a0         /* pop ret addr */
    move.l (sp), d0          /* D0[31:16]=evmask, D0[15:0]=stopmask (C stack order) */
    swap d0                  /* D0[31:16]=stopmask, D0[15:0]=evmask (ROM order) */
    .word 0xA032             /* ROM reads D0; no stack delta */
    subq.l #4, sp            /* restore 4 bytes for PCC cleanup */
    jmp (a0)
```

---

## Docker: extracting Retro68 stubs (solved, 2025-05)

**What we needed:** Extract `libretrocrt.a`, `libInterface.a`, `libc.a`, and `ldscripts/` from
`ghcr.io/autc04/retro68:latest` to link against in CI without rebuilding Retro68.

**What went wrong (three iterations):**

1. **`docker cp` fails on relative symlinks.** `libInterface.a` in the image's `lib/`
   directory is a relative symlink pointing to `../../multiversal/lib68k/libInterface.a`,
   which is outside the copied directory. `docker cp` exits non-zero on this.

2. **`docker run IMAGE tar -hcf -` is intercepted by ENTRYPOINT.** The Retro68 image
   sets `ENTRYPOINT ["/Retro68-build/bin/docker-entrypoint.sh"]`. Running
   `docker run retro68 tar -hcf - ...` actually executes
   `/Retro68-build/bin/docker-entrypoint.sh tar -hcf - ...` — the entrypoint receives
   `tar` as its `$1` argument, does its initialization, then `exec`s it. BUT the
   entrypoint prints `"Using multiversal interfaces\n"` to **stdout** before `exec`ing,
   which corrupts the tar stream piped to the host.

3. **Fix: `--entrypoint /bin/bash`** to bypass the Retro68 entrypoint entirely:
   ```bash
   docker run --rm --entrypoint /bin/bash "${RETRO68_IMAGE}" \
     -c 'tar -hcf - -C /Retro68-build/toolchain/m68k-apple-macos lib' \
     | tar -xf - --strip-components=1 -C "${STUBS_DIR}"
   ```
   `tar -h` dereferences symlinks (replaces each symlink with the file it points to),
   solving the `libInterface.a` problem. `--entrypoint /bin/bash` bypasses the
   initialization banner. Both are required.

**Toolchain path inside the image:** `/Retro68-build/toolchain/m68k-apple-macos/`
(lib/ and include/ subdirectories).
