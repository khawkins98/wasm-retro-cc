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
(68020/030/040).

**Verified 2026-05-14:** classic-vibe-mac runs **BasiliskII** with the
**Quadra-650 ROM** (68040 CPU, System 7.5.5; infinite-mac-derived port).
PCC's 68020+ output is fully supported by this CPU. An earlier draft of
this section incorrectly inferred "Mini vMac (68000)" from a disk-volume
label in a boot-test screenshot — see the "Boot test (2026-05-14)"
section below for the corrected story.

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
GCC_LIBDIR=$(find /Retro68-build/toolchain/lib/gcc/m68k-apple-macos -name libgcc.a | head -1 | xargs dirname)
RETRO68_REAL_LD=/Retro68-build/toolchain/bin/m68k-apple-macos-ld.real \
  /Retro68-build/toolchain/bin/Elf2Mac \
  --mac-single \
  -o hello.bin \
  hello.o \
  -L/Retro68-build/toolchain/m68k-apple-macos/lib \
  -L"${GCC_LIBDIR}" \
  --start-group -lretrocrt -lc -lInterface -lgcc --end-group
```

**Full library set explained:**
- `-lretrocrt`: CRT startup (`_start`, relocator, `_exit` → `ExitToShell`, malloc)
- `-lc`: newlib libc (exit, atexit, string functions); references back into retrocrt
- `-lInterface`: ALL Mac Toolbox A-trap stubs; needed by libretrocrt's syscalls.c
- `-lgcc`: soft-math helpers (`__mulsi3`, `__udivsi3`); needed by libretrocrt's malloc

**CRITICAL: Use `--start-group`/`--end-group`** (NOT `-lretrocrt` twice). The circular dep chain
is: `_start` → `exit()` [libc] → `_exit` [syscalls.c.obj from retrocrt] → `FSWRITE/FSREAD`
[Interface] + `__mulsi3` [libgcc]. Without a group, ld scans archives left-to-right only once;
`syscalls.c.obj` is extracted during a second retrocrt pass, AFTER Interface and libgcc have
already been processed. The `--start-group`/`--end-group` pair causes ld to rescan all archives
in the group repeatedly until no new symbols are resolved, correctly handling this late extraction.
Elf2Mac passes all unrecognized flags through to the real ld, so `--start-group`/`--end-group`
reach `m68k-apple-macos-ld.real` without any special handling needed.

**`--mac-single` vs `--mac-flat`:**
- `--mac-single`: produces a complete MacBinary APPL (CODE 0 + CODE 1 resources). No SIZE resource.
- `--mac-flat`:   produces a flat binary code resource (not bootable as an app).
- `m68k-apple-macos-gcc` forces `--mac-flat` in its specs — never use it for building an app binary.

**`-lgcc` IS required** even when using PCC: `libretrocrt.a` was compiled by GCC targeting 68000,
so it emits calls to soft-math helpers (`__mulsi3`, `__udivsi3`). These live in `libgcc.a`.
PCC-compiled code itself doesn't need them, but Retro68's CRT does.
**IMPORTANT:** `libgcc.a` is NOT in the standard lib dir (`m68k-apple-macos/lib/`).
It lives in GCC's private directory: `lib/gcc/m68k-apple-macos/<version>/libgcc.a`.
You must add a second `-L` pointing to that directory, found dynamically with `find`.

**`-lInterface` IS required**: `libretrocrt.a(syscalls.c.obj)` calls Mac File Manager traps
(`FSWRITE`, `FSREAD`, `FSCLOSE`, `FLUSHVOL`, etc.; uppercase because GCC mangles Pascal calling
convention names to uppercase in ELF symbol tables). These are provided by `libInterface.a`.
This is Retro68's pre-built stub library for ALL Mac Toolbox calls.
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
- [x] Does `classic-vibe-mac` load MacBinary directly? **NO** — HFS patcher → disk image → BasiliskII (Quadra-650 ROM, System 7.5.5).
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
- [x] Does classic-vibe-mac emulate 68000 or 68020+? **BasiliskII, Quadra-650 ROM, 68040 CPU, System 7.5.5** (verified 2026-05-14 by reading `src/web/public/emulator/` + `src/web/src/emulator-worker.ts:368`). An earlier draft of this entry misread a boot-test screenshot and recorded "Mini vMac, 68000"; that was wrong. See "Boot test (2026-05-14)" section.

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
    /* %sp -> [ret] [evmask (2B)] [stopmask (2B)] */
    movl %sp@(4), %d0        /* D0[31:16]=evmask, D0[15:0]=stopmask (C stack order) */
    swap %d0                 /* D0[31:16]=stopmask, D0[15:0]=evmask (ROM order) */
    .word 0xA032             /* ROM reads D0; no stack delta */
    rts                      /* PCC cleans 4 bytes of stack args */
```
Note: this is GNU AS MIT syntax (m68k-linux-gnu-as default). See "m68k assembly syntax" section.

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

---

## m68k assembly syntax: use GNU AS MIT style (not Motorola)

`m68k-linux-gnu-as` on Ubuntu defaults to **MIT/AT&T syntax**, NOT Motorola syntax.
This affects all hand-written `.s` files (PCC's generated assembly happens to work
because PCC targets this assembler, but our stub files broke).

**MIT syntax rules for m68k:**
- Register prefix: `%d0`, `%a0`, `%sp` (NOT `d0`, `a0`, `sp`)
- Indirect: `%a0@` (NOT `(a0)`)
- Post-increment: `%sp@+` (NOT `(sp)+`)
- Displacement: `%sp@(4)` (NOT `4(sp)`)
- Size in opcode, not suffix: `movl`, `movw`, `subql`, `subal` (NOT `move.l`, `move.w`, etc.)
- SWAP: `swap %d0` (NOT `swap d0`)

**Working example (FlushEvents stub):**
```asm
FlushEvents:
	movl	%sp@(4), %d0	/* D0[31:16]=evmask, D0[15:0]=stopmask */
	swap	%d0		/* D0[31:16]=stopmask, D0[15:0]=evmask (ROM order) */
	.word	0xA032
	rts
```

**Memory-to-memory MOVE:** Avoid it. Even though 68k hardware supports it, some
assembler configurations reject it. Use a register as intermediate:
```asm
movw %sp@, %d0       | save word
movw %sp@(2), %d1    | save other word
movw %d1, %sp@       | write back
movw %d0, %sp@(2)    | write back
```

**Why some Motorola mnemonics partially work:** Gas loosely accepts some unambiguous
Motorola mnemonics (`subq.l`, `jmp`) but rejects others that conflict with MIT parsing
(`swap d0`, `suba.l a0,a0`, displacement addressing like `4(sp)` vs `%sp@(4)`).
Do not rely on this — always write full MIT syntax for hand-written stubs.


---

## MacBinary format and HFS patcher round-trip validation

### MacBinary II header layout (relevant fields)

| Offset | Length | Field |
|--------|--------|-------|
| 0      | 1      | version (0x00 for old/MacBinary II compat) |
| 1      | 64     | Pascal filename (byte 1 = length, then chars) |
| 65     | 4      | File type OSType (e.g. `APPL` = 0x4150504C) |
| 69     | 4      | Creator OSType |
| 83     | 4      | Data fork length (big-endian uint32) |
| 87     | 4      | Resource fork length (big-endian uint32) |

After the 128-byte header, the data fork follows (padded to 128-byte blocks),
then the resource fork (also padded).

### Resource fork structure (Inside Macintosh)

The resource fork starts with a 16-byte header:
- Bytes 0-3: offset to data section (within rsrc fork)
- Bytes 4-7: offset to map section (within rsrc fork)
- Bytes 8-11: data section length
- Bytes 12-15: map section length

The map section contains:
- Bytes 24-25: offset to type list (within map section)
- Bytes 26-27: offset to name list (within map section)
- Type list: 2-byte count, then 8-byte entries: (4 type, 2 count-1, 2 ref-off)
  - ref-off is the offset from the TYPE LIST START (including count word) to the ref list
- Ref list: 12-byte entries: (2 ID, 2 name-off, 4 attr+data-offset, 4 handle)
  - attr+data-offset: high byte = attributes, low 3 bytes = offset into data section

### hello.bin resource structure (Phase 1 spike output)

```
CODE id=0  (24 bytes) — jump table resource
  0000 0028   above_a5 = 40 bytes (A5 world size above A5)
  0000 0000   below_a5 = 0
  0000 0008   jump table length = 8 bytes = 1 entry
  0000 0020   jump table offset from A5 = 32 (0x20)
  003f 3c00 01a9f0  JT entry: MOVE.W #1, -(SP); A9F0 (LoadSeg trap → segment 1)

CODE id=1  (10,638 bytes) — main code segment
  Starts with valid m68k instructions (NOP, RTS, etc.)
  Contains __start, main, and all linked C library code
```

### HFS patcher round-trip test (validates loadability)

The `classic-vibe-mac` project contains `src/web/src/playground/hfs-patcher.ts`
which can patch a MacBinary file into a 1.44 MB HFS disk image template.
We verified that `hello.bin` passes this test:

```js
// Transpile hfs-patcher.ts → ESM, then:
const parsed = parseMacBinary(helloBin);
// parsed.type === 0x4150504C (APPL) ✓
// parsed.rsrcLen === 10988 ✓

const patched = patchEmptyVolumeWithBinary({
  templateBytes: template,     // src/web/public/playground/empty-secondary.dsk
  macBinary: helloBin,
  filename: "hello",
});
// patched.length === 1474560 (1.44 MB) ✓
```

With hfsutils installed, `hls -la` on the patched disk shows:
```
f  APPL/????     10988        20 May  9 15:16 hello
```

This confirms hello.bin is structurally valid and can be loaded by the classic-vibe-mac
emulator. Full boot verification (the emulator actually running the app) requires a
browser with `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy`
headers for SharedArrayBuffer support — this is a manual test step.

### CI verification commands

In `spike/run-spike.sh`, both `verify` and `verify-toolbox` now check:
1. File size ≥ 128 bytes
2. Type field = `APPL` (0x4150504C)
3. Resource fork length > 0 (ensures CODE resources exist)

The resource fork check uses Python's `struct.unpack('>I', ...)` to read the
big-endian uint32 at offset 87 in the MacBinary header.

---

## Boot test (2026-05-14) — wrong link mode, not wrong emulator

### What happened

Live boot test of `hello_toolbox.bin` in classic-vibe-mac's deployed playground
(https://khawkins98.github.io/classic-vibe-mac/, post-PR-#62) produced:

```
The application "hello_toolbox" has unexpectedly quit, because an error
of type 3 occurred.    [OK]
```

The disk mounted, the Finder saw the `hello_toolbox` icon and launched
it, then the app crashed with type 3 (`dsIllInstErr` — illegal instruction).

### A misdiagnosis (and how it was caught)

An initial diagnosis read the disk-volume label **"Mini vMac Boot v2"**
visible on the emulated desktop in the boot-test screenshot and inferred
the emulator was **Mini vMac (68000 Mac Plus)** — which would mean PCC's
68020+ output was illegal on the CPU, explaining the type 3.

That inference was wrong. classic-vibe-mac contains
`src/web/public/emulator/BasiliskII.{js,wasm}` + `Quadra-650.rom`, and
`src/web/src/emulator-worker.ts:368` reads:
> `// Quadra 650 = 68040 (cpu 4)`.

The emulator is **BasiliskII** with a **Quadra-650 ROM (68040 CPU, System
7.5.5)**, sourced from the `infinite-mac` project. "Mini vMac Boot v2" is
just a volume label on a system disk — not the emulator's identity. The
project documents this configuration in
`src/web/src/emulator-config.ts`.

The lesson: a screenshot can identify *what's on the screen*, not *what's
running underneath*. Always check the integration source, not the desktop.

### The real diagnosis

With the 68040 cleared, the type 3 had to be elsewhere. Comparing
`hello_toolbox.bin` against a known-working binary on the same playground
(`macweather.code.bin`, built by Retro68's `add_application` CMake macro)
surfaced the actual mismatch:

| Property | `hello_toolbox.bin` (broken) | `macweather.code.bin` (works) |
|---|---|---|
| CODE segments | 1 (10810 B) | 8 (4452 + 6×80 + 13120 B) |
| DATA resource | **none** | 1 (1888 B) |
| RELA resources | **none** | 9 (one per CODE segment) |
| CODE 0 `above_a5` | 40 | 136 |
| CODE 0 `below_a5` | **0** | **10424** |
| CODE 0 jump-table entries | 1 (LoadSeg trap → seg 1) | 13 |
| CODE 1 first 16 bytes | identical to macweather | identical |

CODE 1's first 16 bytes are byte-identical — both binaries go through the
same `libretrocrt` `_start` → `Retro68Relocate` → `main` path. The
difference is the *envelope*.

The spike's `cmd_link*` was invoking `Elf2Mac --mac-single`. That mode
emits a minimal single-CODE-segment MacBinary with `below_a5=0` and no
DATA / RELA resources. It's intended for trivial programs that don't link
`libretrocrt`. We do link `libretrocrt`; its `Retro68Relocate` checks the
linker-defined `_MULTISEG_APP` symbol and, in the non-multiseg path,
**never calls `SetCurrentA5()`**. With `below_a5=0` the Process Manager
allocates no space below A5, so libretrocrt's `qd` (QuickDraw globals)
and other below-A5 statics land in unallocated memory; the first Toolbox
call after `InitGraf` walks A5-relative pointers into invalid addresses
and traps.

Verified against Retro68 source (paths inside the
`ghcr.io/autc04/retro68` image and on github.com/autc04/Retro68):

- `Elf2Mac/Elf2Mac.cc:101` — default `segments = true`.
- `Elf2Mac/Object.cc:201-206` — `SingleSegmentApp` hardcodes
  `above_a5=0x28`, `below_a5=0`, one JT entry. Matches our broken header.
- `libretro/relocate.c:233-308` — branches on `_MULTISEG_APP`; only the
  multi-segment path calls `SetCurrentA5()`.
- `gcc/config/m68k/m68k-macos.h` `LINK_SPEC` — GCC's default invocation
  of Elf2Mac passes only `-elf2mac` (no `--mac-*`), i.e. multi-segment
  mode. This is what produces `macweather.code.bin` and friends.

### The fix

Drop `--mac-single` from both `cmd_link` and `cmd_link_toolbox` in
`spike/run-spike.sh`. With no `--mac-*` flag, Elf2Mac defaults to
multi-segment mode and emits CODE 0/1..N + DATA + RELA + a properly-sized
A5 world. This is the same mode `add_application` (the Retro68 CMake
macro that produced the working `macweather.code.bin`) uses.

A new structural check — `spike/inspect_macbinary.py` — parses CODE 0
and asserts `below_a5 > 0` + DATA + RELA presence. `cmd_verify` and
`cmd_verify_toolbox` invoke it. This would have caught the
`--mac-single` regression in CI before the manual boot test was even
attempted.

### What the test *did* prove (don't lose this)

The failure happened after the Finder had successfully launched the app,
which rules out two previously-flagged risks regardless of the fix:

- **MacBinary structure** is consumable by the System 7.5.5 Resource
  Manager.
- **`SIZE -1` resource is *not* required** for Finder launch on Quadra
  650 / System 7.5.5. Earlier notes (line 569) had listed it as
  "required." Empirically not so for hot-loaded apps in this playground.

The libtoolbox-stubs framework remains untested in practice — the app
never executed any of those stubs before crashing. Validation of the
calling-convention bridges has to wait for a binary that boots.

### Caveats / open follow-ups

- **PCC reloc-format compatibility:** Elf2Mac's `Reloc.cc` parses the
  `R_68K_*` relocations emitted by the assembler. PCC + `m68k-linux-gnu-as`
  should emit the standard set, but if the post-fix artifact lands with
  empty RELA resources, that's the next thing to chase (suspect:
  unsupported relocation types being silently skipped). Verifiable with
  `readelf -r hello_toolbox.o` and by inspecting the RELA n contents.
- **`add_application` does more than just call Elf2Mac.** It also runs
  `Rez` to add SIZE / BNDL / vers / icon resources. Our binary won't get
  those without a similar step — likely harmless for the hot-load path,
  may matter later for Finder UX.
- **`NewWindow` stub** is still NULL-returning; revealed by inspection,
  not by this test.

### What this means for the repos

- **wasm-retro-cc**: one-flag fix in the spike's link step + a stronger
  CI verifier. No architectural change.
- **classic-vibe-mac**: no change needed. The emulator is already exactly
  what we wanted. Once the wasm-retro-cc fix lands, re-vendor
  `src/web/public/precompiled/hello-toolbox.bin` from the new CI artifact
  and re-run the manual boot test.
- **No emulator pivot**, no PowerPC pivot, no repo split. The earlier
  "BasiliskII swap" / "Mini vMac→BasiliskII" / "Quadra ROM choice"
  framings in this section's earlier draft were all artifacts of the
  misdiagnosis.

### Process notes

Three lessons from the misdiagnosis, recorded so this doesn't happen
again:

1. **Compare artifacts side-by-side against a known-working reference.**
   This single comparison surfaced the real bug in five minutes; it
   should have been the first diagnostic step, not the recovery move
   after a wrong pivot.
2. **CI verification should fail on the same property the runtime fails
   on.** "type=APPL, rsrc>0" was too weak — both broken and working
   binaries pass. The new structural check asserts `below_a5 > 0` + DATA
   + RELA, which actually differentiates.
3. **Don't infer infrastructure from screenshots.** Read the integration
   source instead.

---

## PCC m68k argument-passing convention (verified 2026-05-14)

PCC's m68k codegen **pushes every argument as a 4-byte longword on
the stack**, regardless of the declared C type.  This includes
`short` / `int16_t` arguments — they're zero-extended (or
sign-extended) to 4 bytes when pushed.

Empirical proof from `hello_toolbox.s` (PCC output for `MoveTo(100, 100)`):

```asm
move.l #100,-(%sp)      ; v=100 pushed as 4 bytes
move.l #100,-(%sp)      ; h=100 pushed as 4 bytes
jsr 0+MoveTo
add.l #8,%sp            ; cleanup: 2 args × 4 bytes
```

If you write a Toolbox stub that READS a `short` arg from the wrong
offset (treating the arg slot as 2 bytes instead of 4), you get the
HIGH zero half of the longword (or whatever was promoted from the
caller's value) rather than the actual value.  The stack arithmetic
ends up balanced by accident, so the bug is silent unless you observe
the actual values delivered to ROM.

### Implication for `src/stubs/libtoolbox-stubs.s`

- **Stubs taking 4-byte pointer args** (InitGraf, InitDialogs, SetPort,
  DrawString, etc.) are fine — pointer size matches the 4-byte slot.
- **Stubs taking 16-bit short args** (MoveTo, FlushEvents at minimum)
  must read the real value from the LOW word of each 4-byte slot:
  `movw %sp@(2), %d0` instead of `movw %sp@, %d0` for a "first 16-bit
  arg at sp+0".  Stack arithmetic doesn't change; only the read offsets.

### Open question

The Pascal calling convention spec says Pascal callers push 2-byte
shorts as 2-byte words.  PCC is not following Pascal here — it's
using C cdecl with 4-byte promotion.  The libtoolbox-stubs bridge has
to handle the mismatch.  This is fine for our use case but is a thing
to watch when adding new stubs.  If a future stub for a Toolbox call
that takes `short` args is added, mirror the MoveTo/FlushEvents
pattern.

### Worth noting

PCC's `-msoft-float` and other config knobs may change calling
convention.  We use default config.  The Retro68 GCC for comparison
DOES push shorts as 2-byte words when `-mshort` is in effect, but its
struct layout is mac68k-packed.  These two conventions are
*independent* — our PCC + pack(2) shim combination is its own ABI
blend.


---

## Phase 2 pivot (2026-05-14)

### Summary

After three real bugs found and fixed in the Phase 1 PCC pipeline
(`Elf2Mac --mac-single`, `pack(2)` mismatch, 4-byte short-arg slots)
the remaining failure mode is **"any single Toolbox call from a
PCC + libretrocrt + libtoolbox-stubs binary destabilises the running
system."** Same boot session, SimpleText also crashed type-3 alongside
our app — strong evidence the bug is something earlier (libretrocrt
startup, A5-world setup, or trap dispatch) that corrupts shared state
for any subsequent app launch.

We have no clear next bisect step. The Phase 1 work is therefore
archived in [`spike-pcc/`](./spike-pcc/) and we pivoted to porting
Retro68 GCC to WebAssembly.

### Why PCC was attractive in the first place

- ~3 MB gzipped, BSD-licensed.
- Existing m68k backend.
- Toolbox A-trap syntax confined to SDK headers — user code never
  sees it. So in principle, if pre-compiled toolchain stubs handle the
  A-traps, any C compiler can produce m68k user code that links
  against them.

### Why we left PCC

Three structural reasons, beyond the immediate unsolved bug:

1. **Unknown-unknowns surface.** PCC's m68k backend is rare in
   production use. The population of remaining bugs is unbounded and
   we have no way to estimate progress.
2. **Each fix only changed the failure mode, not the outcome.** Three
   fixes in, the binary still crashes on entry to any Toolbox trap.
   The pattern (each bug found cost a sustained debugging session;
   none flipped silent-exit → working) suggests several more bugs of
   the same class remain.
3. **System-wide destabilisation, not localised crash.** SimpleText
   crashing in the same boot session points at something corrupting
   the global system state — not a specific call's argument layout.
   That's a hard target to bisect inside an emulator we can't
   single-step easily.

### Why Retro68 GCC → WASM

- **Known-good output.** Every Retro68 sample app boots on the same
  BasiliskII Quadra-650 we're targeting. We've already confirmed
  `macweather.code.bin` (built by Retro68) round-trips through
  classic-vibe-mac's HFS patcher and runs cleanly. The compiler-to-
  emulator path is de-risked end-to-end.
- **The Apple A-trap syntax problem disappears.** GCC parses
  `= { 0xA913 }` natively, so the hand-written shim layer (and the
  4-byte-vs-2-byte short-arg argument-slot bug, and the `pack(2)`
  mismatch) all stop existing.
- **Known-bounded effort.** [Emception](https://github.com/jprendes/emception)
  ported Clang + LLVM to WASM and ships a working in-browser C/C++
  compiler. Retro68 GCC is smaller than Clang/LLVM and we don't need
  C++ initially. The work is portability + build-system grinding, not
  bug-hunting against an unknown compiler.

### Trade-off accepted

The cost is bundle size: Retro68 GCC after Emscripten + stripping is
estimated at **25–40 MB gzipped** vs PCC's ~3 MB. We lazy-load on the
playground's Build button so first-page-load is unaffected; users who
never compile never pay the download. classic-vibe-mac's
in-browser-only architecture has no fallback to "just call the
backend," so the bundle is non-negotiable — but lazy loading makes it
acceptable.

PowerPC / Mac OS 8 / SheepShaver remains a longer-term aspiration; not
Phase 2 scope.

### What carries over from Phase 1

These were the genuinely-useful artefacts of the PCC spike. They are
compiler-agnostic and reusable for Phase 2:

- **LEARNINGS.md itself** (every entry above is compiler-agnostic —
  MacBinary II structure, A-trap semantics, mac68k packing, multi-
  segment loader behaviour, infinite-mac integration).
- **`spike-pcc/inspect_macbinary.py`** — structural validator (CODE
  0+1, DATA + RELA, `below_a5 > 0`). Will catch Phase 2 regressions
  the same way it caught the `--mac-single` regression.
- **`spike-pcc/hello*.c`** — regression corpus. Same source files
  compile under both pipelines; Phase 2.0 vendors a Retro68 build of
  these and confirms they boot.
- **classic-vibe-mac integration** (`hfs-patcher.ts`,
  `prebuilt-demo-boot.spec.ts`, the e2e test harness) — entirely
  compiler-agnostic. Phase 2 binaries plug into the same plumbing.
- **CI infrastructure** (pinned Retro68 image, GitHub Actions, artifact
  retention). The Phase 1 workflow becomes manual-only; Phase 2 builds
  on the same foundation.

### What was archived

Files in `spike-pcc/` are preserved verbatim with an `ARCHIVE.md` and
banner notices on the moved design docs. The `[archived] PCC m68k
pipeline` workflow is `workflow_dispatch`-only — it no longer auto-runs
on push/PR. See [`spike-pcc/ARCHIVE.md`](./spike-pcc/ARCHIVE.md).

### Process notes — for the next pivot

- **Bisect probes paid for themselves.** `hello-bare`,
  `hello-initgraf`, `hello-initgraf-local`, `hello-initgraf-zone` each
  cost an hour to build but each ruled out an entire hypothesis. The
  decision to pivot is well-evidenced because we *know* H1 (qd-pointer)
  and H2 (heap init) are dead, not "we gave up."
- **Diagnostic infrastructure matters more than fixes.** The
  classic-vibe-mac SHA-log + info.txt-on-disk + Playwright harness +
  CI readelf dumps were the only thing that let us run any iteration
  loop at all. Build these first for Phase 2.
- **Boot-test misdiagnosis trap.** Once during the investigation a
  screenshot of a disk's volume label ("Mini vMac Boot v2") was
  almost-read as the emulator's identity. The repo runs BasiliskII
  Quadra-650, not Mini vMac. Always cross-reference what the
  *emulator* is (read `emulator-worker.ts`, not the disk label).


---

## Phase 2.0 — Retro68 GCC vendoring derisk passed (2026-05-14)

Smallest possible derisk before any Emscripten work began: compile the
same `hello_toolbox.c` we used as the Phase 1 PCC bisect probe with the
pinned Retro68 GCC image (`ghcr.io/autc04/retro68@sha256:e8b6cc8…`),
vendor the result into classic-vibe-mac, and watch it run on the
deployed playground BasiliskII.

**Result: clean pass.** Structural inspection matches the reference
shape (`APPL` + `CODE 0` + 8× `CODE` + `DATA` + 9× `RELA` + `SIZE`,
`above_a5=56 below_a5=1428 jt_size=24 jt_entries=3`). The cv-mac HFS
patcher accepted the binary without errors. End-to-end test on
deployed Pages: app launched, `DrawString` rendered "Hello, World!" at
(100, 100) on the screen port. This is the exact operation the Phase 1
PCC binary crashed on across nine hours of bisect work.

**What this rules out:** the hypothesis "Retro68's MacBinary output
might have some structural property our patcher/emulator/Mac OS won't
accept." It doesn't. The remaining Phase 2 risk is purely the
(known-bounded) Emscripten port of GCC + binutils + Elf2Mac.

**Implementation notes (worth keeping):**

- `add_application(name … files)` produces *two* outputs:
  `name.code.bin` (partial — the linker emits this as the executable's
  `OUTPUT_NAME`) and `name.bin` (complete APPL — emitted by a separate
  `name_APPL` CMake target that runs Rez over `name.code.bin` with
  `Retro68APPL.r`). **`cmake --build . --target name` only builds the
  partial.** You have to build the ALL target (no `--target`) or
  `name_APPL` explicitly to get the complete MacBinary II.
- Retro68's pure-m68k binaries have a **0-byte data fork** — the
  20-byte CFM stub our PCC pipeline produced is *not present* and not
  needed. (Initial worry: would the cv-mac patcher choke on
  `dataLen=0`? Answer: no, it's handled.)
- The downstream filename mismatch is fine. MacBinary header carries
  one name (`HelloToolboxRetro68` from the CMake target), but
  cv-mac's `PrebuiltDemo.filename` *overrides* it when writing the
  HFS catalog entry. The Finder shows whatever cv-mac asks for.
- Local-preview test harness has a permanent quirk: the bundled
  `system755-vibe.dsk` doesn't apply `NO_STARTUP_ITEMS=1`, so
  MacWeather auto-launches and visually masks the Apps disk icon
  region. Deployed Pages env applies it. Don't waste time debugging
  "Apps disk missing" against local preview — test on Pages.

Cross-repo PRs: wasm-retro-cc#13, classic-vibe-mac#78.


---

## Phase 2.1 — Emscripten port of cc1, research (2026-05-14)

Distilled from a focused research pass on prior art before any code
goes in. The full discussion is preserved in `spike/wasm-cc1/README.md`
("Critical design decisions" + "Known landmines" sections); this is
the long-term reference layer.

### The strategic problem

Retro68's m68k backend exists *only in GCC*. Clang has no
`m68k-apple-macos` target. So the GCC-to-WASM port is non-negotiable
for this project — we cannot follow Emception's "pick Clang because
it's a library" path because Clang doesn't have the backend we need.

### Closest prior art

- **[Emception](https://github.com/jprendes/emception)** (Jorge Prendes)
  — Clang + LLVM compiled to WASM via Emscripten. The two-stage build
  in `build-llvm.sh` is the canonical pattern: native stage 1
  produces table-gen / build tools, wasm stage 2 reuses them via
  `-DLLVM_TABLEGEN=$STAGE1/llvm-tblgen`. Bundle ends up ~10–12 MB
  brotli for the full toolchain.
- **The 2-hunk LLVM patch** at `patches/llvm-project.patch` is the
  load-bearing magic: forces Clang's driver to call `cc1` in-process
  (no `fork`/`exec`). For GCC's monolithic driver-spawning model the
  equivalent is "don't use the driver at all — call `cc1` directly
  from JS with cooked argv."
- **[racerxdl/riscv-online-asm](https://github.com/racerxdl/riscv-online-asm)**
  — GNU `as` / `objdump` / `objcopy` to WASM. Shares libiberty +
  autoconf pain with GCC; their `config.cache` seeding and stub
  layer for `pex-unix.c` are directly transferable.
- **[pipcet/gcc `asmjs` branch](https://github.com/pipcet/gcc)** —
  old (~2018) GCC wasm *backend*, never merged. Build-system
  patches in `config.guess`, `config.sub`, `libiberty/configure.ac`
  are cargo-cult worthy for our host-side use.
- **No prior art** for full GCC-as-host (wasm32) cross-compiling to
  any target. We're first.

### Canadian cross — concrete recipe

```
stage1: build=host=x86_64-linux-gnu, target=m68k-apple-macos
        (just produces gen* tools + generated headers for stage 2)

stage2: build=x86_64-linux-gnu, host=wasm32-unknown-emscripten,
        target=m68k-apple-macos
        emconfigure + emmake all-gcc
        --disable-bootstrap (cannot run wasm cc1 to bootstrap stage 2)
        --enable-languages=c (no C++/Fortran/Ada → ~60% mass cut)
        --with-build-time-tools=$stage1/gcc/build (reuse, never re-run)
```

### Pre-seeded `config.cache` (dodges autoconf misfires)

```
ac_cv_func_fork=no
ac_cv_func_vfork=no
ac_cv_func_kill=no
ac_cv_func_pipe=no
ac_cv_func_sigaction=no
ac_cv_func_sigsetmask=no
ac_cv_func_mmap=yes
ac_cv_func_setjmp=yes
ac_cv_func_longjmp=yes
ac_cv_func_dup2=yes
```

Reason: `AC_CHECK_FUNCS` compiles tiny probes and links them with
`wasm-ld`. Some probes link successfully because Emscripten provides
ENOSYS-returning stubs, leading autoconf to assume the function works.
We pre-answer to match reality (the stubs exist but the calls do
nothing at runtime).

### Emscripten link flags that matter

| Flag | Why |
| --- | --- |
| `-sALLOW_MEMORY_GROWTH=1` | GCC's GC heap is unpredictable |
| `-sMAXIMUM_MEMORY=1GB` | Cap below wasm32's 2 GB ceiling |
| `-sSUPPORT_LONGJMP=wasm` | Native EH; smaller + faster than `=emscripten`. GCC uses sjlj heavily |
| `-sMODULARIZE=1 -sEXPORT_ES6=1` | ES module loader for JS host |
| `-sEXPORTED_FUNCTIONS=_main,_malloc,_free` | JS needs to call `main` + manage strings |
| `-sEXPORTED_RUNTIME_METHODS=FS,allocateUTF8,callMain` | MEMFS + argv + invoke |

### Memory-snapshot reset between invocations (Emception trick)

GCC has tons of global state: GC heap (`ggc-page.c`), obstacks
(`obstack.h` users), `current_function_decl`, the entire
`global_options` flags struct, identifier table, line maps. Easiest
reset is `HEAPU8.set(initialMemorySnapshot)` — capture the linear
memory right after `Module()` initialises, then memcpy it back before
every `callMain`. Cheaper than `Module()` re-instantiation by ~100×.

### Realistic bundle-size target

Retro68's `m68k-apple-macos-cc1` on disk is ~40–50 MB unstripped,
~15–20 MB stripped (native ELF). With `--enable-languages=c` +
`--disable-checking` + single-target backend + `-Os -flto` +
`--disable-nls`, expect:

- Raw wasm: ~12–18 MB
- gzip:     ~4–6 MB
- brotli:   ~3–5 MB

Compare Emception's full clang+lld+5 LLVM tools at ~10–12 MB brotli.
GCC ends up smaller per-language because we cut every backend except
m68k. If we land north of 10 MB brotli, Phase 2.4 has more work than
estimated in tracker #11.

### Known landmines (expect in order)

1. **`AC_CHECK_FUNCS` link tests miscompile.** Pre-seed config.cache
   per above. If a new check breaks the build, add the answer.
2. **`libiberty/pex-*.c` references `fork`/`exec`.** Emscripten links
   ENOSYS stubs. We never call them (we bypass the driver), but the
   *build* may try to test linkage. Replace with no-op stubs if so.
3. **`mmap` for GC heap.** Works under Emscripten's anonymous mmap
   when `ALLOW_MEMORY_GROWTH=1`. Cap at 1 GB to keep below the wasm32
   2 GB ceiling and treat OOM as "user submitted too much C."
4. **Generated headers must match between stages.** Stage 2 reuses
   `insn-*.h` from stage 1. Build both stages from the *identical
   commit* of the GCC tree — any version-macro drift causes silent
   miscompiles. We pin a single `RETRO68_COMMIT` in the Dockerfile.
5. **Computed gotos.** GCC's `genrecog.c`-generated `insn-recog.c`
   uses `&&label` heavily. Emscripten/LLVM lowers these fine via
   `br_table`/relooper — confirmed working in Emception's LLVM build,
   which uses the same pattern. Not expected to be a blocker, but if
   the build dies on `insn-recog.c` start here.

### What this sub-spike does NOT cover

- Building `as` / `ld` / Elf2Mac to WASM (Phase 2.2 / 2.3 — separate
  sub-spikes, smaller binaries, same patterns).
- MEMFS plumbing for real source files (Phase 2.1.x — after first
  smoke test).
- Bundle-size optimisation pass (Phase 2.4).
- npm packaging mirroring wasm-rez (Phase 2.5).

### What "Phase 2.1 done" looks like

`cc1.wasm` loads from Node, `callMain(['--version'])` exits 0 and
prints the version string. Then we know the binary is real and can
move to the MEMFS pipe-through sub-spike, where we feed it a real
`.c` source and check that it emits real `.s` output.

If the first smoke test fails, the failure mode tells us which
landmine bit us, and the build script has hooks for each one.


---

## Phase 2.1 — Emception build mechanics, deltas (2026-05-14)

Outside research read jprendes/emception's actual source after our
scaffold landed. Captures things our initial planning missed.

### Stage 2 link flags — what we initially missed

| Flag we added | Why | Where Emception uses it |
| --- | --- | --- |
| `-sLLD_REPORT_UNDEFINED=1` | Default wasm-ld swallows undefined symbols and produces a wasm with dangling imports that traps at instantiation. With this flag, link fails loudly. | `build-llvm.sh:51` |
| `ERRNO_CODES` in `EXPORTED_RUNTIME_METHODS` | `EmProcess.mjs:60-84` wraps `FS.ErrnoError` so errors print as `ENOENT` instead of `28`. Without this, every MEMFS bug is a numeric goose chase. | `build-llvm.sh:56` |
| `CXXFLAGS=-Dwait4=__syscall_wait4` (+ `ac_cv_func_wait4=no` in cache) | Emsdk dropped the `wait4` export at 2.0.32; GCC's `libiberty/pex-unix.c` references it. Belt-and-braces — cache prevents detection, define repaints direct refs. | `build-llvm.sh:51` (set as `CXXFLAGS`) |

### Build triple via `config.guess`, not hard-coded

Hard-coding `--build=x86_64-linux-gnu` breaks on Apple Silicon hosts
(Docker maps to `linux/aarch64`). Emception's `build-cpython.sh:73`
uses `--build=$($CPYTHON_SRC/config.guess)`. We adopted the same.

### Prerequisites must be in-tree for stage 2

Stage 1 (native) finds GMP/MPFR/MPC via Ubuntu's `libgmp-dev` host
packages. Stage 2 (host=wasm32-emscripten) can't reuse those —
`emcc` has its own sysroot and the host libs are wrong-arch. GCC's
`contrib/download_prerequisites` drops the source tarballs into the
source tree where stage 2's configure picks them up automatically.
First stage-2 build failed at "Building GCC requires GMP 4.2+,
MPFR 3.1.0+ and MPC 0.8.0+" exactly because of this.

### Snapshot reset — exact sequence (Emception `EmProcess.mjs`)

Init (runs once):
1. `this._module = await Module({ noInitialRun: true, noExitRuntime: true, … })`
2. Immediately after resolve: `this._memory = this._module.HEAPU8.slice()`
   — full linear-memory snapshot. After `__wasm_call_ctors` + `preRun`
   but before any `main` ran.

Per-invocation `exec()`:
1. `HEAPU8.fill(0)` — zero pages that may have grown since snapshot.
2. `HEAPU8.set(this._memory)` — restore snapshot.
3. Allocate argv with `_malloc` + `allocateUTF8` per arg.
4. `_main(argc, argv)`.
5. `_free` everything on `finally`.

**Order matters: fill before set.** `ALLOW_MEMORY_GROWTH=1` may have
grown linear memory between calls; the tail past the snapshot length
must be zeroed or you leak prior-invocation state.

**Open risk: wasm globals not in HEAPU8.** Emption's own code has a
TODO at `EmProcess.mjs:99` flagging this. For Clang they get away
with it. For GCC, most state is in linear memory (real C globals),
so probably fine — but `errno`/TLS-style state could live in wasm
globals depending on Emscripten version. **Investigate after the
first ICE.** Symptom: deterministic miscompile on the Nth call to
`cc1` but correct on the (N-1)th.

### PROXYFS / `fsroot.js` — defer to Phase 2.2

Multiple Emscripten modules can share one MEMFS via a custom JS
library (`emlib/fsroot.js`) injected at link time with
`--js-library`. **The `--js-library=fsroot.js -lproxyfs.js` flags
must be present on every wasm binary that participates in the
shared FS, from day one.** Retrofitting means re-linking every
`.wasm`. For our Phase 2.1 cc1-only build, we *don't* need PROXYFS
yet (single process), but worth wiring the flags in pre-emptively
so Phase 2.2 (`as`) doesn't force a full re-link. **Decision: skip
for now to keep stage 2 simple — re-link cost is one CI run, not
worth pre-paying complexity for.**

### Failure modes that haunt Emception's tracker

- **Emsdk version drift** (their #2). Pin a specific tag — never
  `latest`. We pin 3.1.61; mirror their discipline. If we bump,
  expect at least one undefined-symbol storm.
- **Stale rebuilds because re-run gates on file existence**
  (their #8/#10/#11). Our `build.sh` does the same: `if [ ! -f
  Makefile ]`. Acceptable for now — when re-running matters, blow
  away `spike/wasm-cc1/build/stage2/` explicitly.
- **OOM during link** (their #8). LLVM CXX compile needed 32 GB; GCC
  stage 2 will be comparable or worse. Local Docker on a 16 GB Mac
  may hit this in the link phase.
- **Patch context drift** (their #24): hard-coded patches stop
  applying after upstream moves. We pin Retro68 by SHA in the
  Dockerfile to avoid this.

### Sources

- jprendes/emception `build-llvm.sh`, `build-cpython.sh`,
  `src/EmProcess.mjs`, `src/FileSystem.mjs`, `emlib/fsroot.js`,
  `patches/llvm-project.patch`
- Issues #2, #8, #10, #11, #20, #24, #27, #33
- Our scaffold: `spike/wasm-cc1/{Dockerfile,build.sh,README.md}`

---

## Phase 2.1 — `--cache-file` doesn't propagate; use `CONFIG_SITE` (2026-05-14)

**Verified surprise.** GCC's top-level `configure` accepts `--cache-file=FILE`
and reads our seeded answers, but the sub-configures triggered inside
`make all-gcc` (`libiberty/configure`, `libcpp/configure`, `gcc/configure`,
`zlib/configure`, ...) do NOT reliably inherit it. They run in their own
build directories and consult `./config.cache` or no cache at all.

Symptom: stage 2 attempt 3 had `ac_cv_func_psignal=yes` in our config.cache,
top-level configure honoured it, libiberty's sub-configure didn't, and the
same `strsignal.c:554 conflicting types for 'psignal'` error returned. Same
build dir, same source tree, same script — identical second failure.

**Fix that works: `CONFIG_SITE`.** Autoconf reads `$CONFIG_SITE` (or
`$prefix/share/config.site` + `$prefix/etc/config.site` as fallbacks)
*before every configure invocation*, regardless of nesting. Set it once,
export it, every sub-configure picks it up.

```bash
cat > /spike/build/stage2/config.site <<'SITE'
ac_cv_func_psignal=yes
ac_cv_have_decl_psignal=yes
# ...etc
SITE
CONFIG_SITE=/spike/build/stage2/config.site \
emconfigure /Retro68/gcc/configure ...
# AND export it for the make step so sub-configures triggered by make see it:
export CONFIG_SITE=/spike/build/stage2/config.site
emmake make all-gcc
```

**Pattern recap (why this matters):** Emscripten's sysroot headers declare
many POSIX functions (`psignal`, `wait4`, `kill`, ...) but the libc doesn't
link them. Autoconf's link-test probe says "function not present"; libiberty
then defines its own replacement; compile-time both declarations are
visible; signature mismatch → error. Seeding `ac_cv_func_X=yes` tells
libiberty to skip its replacement.

**Open**: expect to seed more functions as the build progresses past
libiberty. The configure scan shows: `feof_unlocked`, `fputs_unlocked`,
`setproctitle`, `setenv`, `memchr` — most are genuinely missing on
emscripten so libiberty's replacements are correct. The ones to watch for
are those emscripten *declares* but doesn't *link* — that's the
conflict-on-compile failure mode. Look for the error pattern `conflicting
types for 'X'` and add `ac_cv_func_X=yes` to config.site, not all "no"
answers from configure.


---

## Phase 2.1 — cc1.wasm produced and smoke-tested (2026-05-14, complete)

**Status: derisk passed.** `cc1.wasm` (12 MB raw, 3.3 MB brotli) +
`cc1.mjs` (142 KB ES module loader) loads in Node, instantiates the
runtime, and `callMain(['--help'])` prints full GCC option help with
language-specific sections for C, C++, Ada, D — proof that GCC's
option machinery is structurally intact in the wasm port.

### The full iteration trail (8 rounds)

| # | Failure | Fix |
| --- | --- | --- |
| 1 | Image build: `git checkout v2024.10.1` — tag doesn't exist | Pin Retro68 by master SHA (`83b9c8d2`) |
| 2 | Stage 2 configure: "Building GCC requires GMP/MPFR/MPC" | Run `contrib/download_prerequisites` in build.sh |
| 3 | libiberty/strsignal.c: "conflicting types for 'psignal'" | Seed `ac_cv_func_psignal=yes` in config.cache |
| 4 | Same psignal error returns | `--cache-file` doesn't propagate to sub-configures; switch to `CONFIG_SITE` env var |
| 5 | mpfr/config.sub: "wasm32-unknown-emscripten not recognized" | Copy GCC tree's newer config.sub/config.guess over GMP/MPFR/MPC/ISL bundled copies |
| 6 | `make -C gcc cc1` fails — gcc subdir Makefile doesn't exist yet | Use `make all-gcc -k` (parent makefile generates child) |
| 7 | cc1.wasm built (58 MB) but `wasm-emscripten-finalize` SIGKILL'd | Docker has 7.75 GB; finalize on huge wasm needs 10+ GB; compile with `-Os -g0` for smaller artifacts |
| 8 | cc1.wasm built (12 MB) but loaded with `Aborted(OOM)` — GCC makefile bypasses our LDFLAGS | Add `cmd_relink` step: re-link the existing .o files with proper `-sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=128MB -sMODULARIZE=1 -sEXPORT_ES6=1` flags, output to `cc1.mjs` |

### Final artefacts

- `spike/wasm-cc1/build/stage2/gcc/cc1.wasm` — 12,029,672 bytes
  - SHA-256: `39ad0f27aa171f3fd627eded7df1387974c97570356f360271bebd2ce67b7603`
  - brotli (`-k`): 3.3 MB — squarely in the predicted target band (3-5 MB)
- `spike/wasm-cc1/build/stage2/gcc/cc1.mjs` — 142 KB
  - ES module, factory function default-exported as `createCC1`

### What this means for the rest of Phase 2

The central GCC-to-WASM bet **works**. Remaining sub-spikes are smaller,
not fundamentally riskier:

- **Phase 2.1.x — MEMFS pipe-through.** Real `.c` source in via MEMFS,
  invoke `cc1 -quiet -O0 input.c -o output.s` from JS, fetch `output.s`
  out of MEMFS. The infrastructure (`FS` runtime method, `allocateUTF8`,
  `callMain`) is already wired in via the relink step. Estimated effort:
  a few hours of plumbing + tests.
- **Phase 2.2 — `as` (binutils assembler).** Smaller binary, same
  pattern. Most of the autoconf/landmine knowledge from this phase
  transfers directly. Some new ones likely (binutils has more BFD/IO
  surface than cc1).
- **Phase 2.3 — `ld` + Elf2Mac.** Same pattern again. Elf2Mac is
  small, custom C++ — likely to need less autoconf shenanigans than
  binutils proper.

### Lessons that generalise beyond GCC

1. **`CONFIG_SITE`, not `--cache-file`.** This is the autoconf-blessed
   way to inject answers across recursive builds. The pattern recurs in
   any project that has sub-configures (libtool, m4, libiberty).
2. **`-Os -g0` at link time has memory implications.** A factor-of-5
   wasm size reduction made the difference between OOM and success on
   `wasm-emscripten-finalize`. Bigger Emscripten projects should plan
   for this.
3. **GCC's makefile ignores `LDFLAGS` for its own targets.** It uses
   `LINKER` / `LINK_OPTS` / various internal vars. The cleanest pattern
   is to (a) let GCC build the .o files with whatever flags it wants,
   then (b) manually re-link with the wasm flags we control. The relink
   step in `build.sh` codifies this.
4. **Pre-built downstream tools (`gcov-tool`, `collect2`, `lto-wrapper`)
   pull in POSIX symbols emscripten lacks.** Use `make -k` so their
   failure doesn't stop `cc1`'s link.
5. **Build-from-scratch iteration is too slow.** Each `rm -rf stage2`
   meant ~15 min of recompile. Future Phase 2.x work should preserve
   `.o` files across iterations and only rebuild what changed.

### Files

- `spike/wasm-cc1/build.sh` — the orchestrator with all 8 iterations
  baked in (image / stage1 / stage2 / relink / smoke)
- `spike/wasm-cc1/Dockerfile` — pinned Emscripten 3.1.61 +
  Retro68 master commit `83b9c8d2` + Ubuntu 22.04 build deps
- `spike/wasm-cc1/README.md` — the design-decisions-and-landmines
  document. Phase 2.1 entries here are now history, but the
  document's structure (decisions / landmines / file index) is
  the template for Phase 2.2 and beyond.


---

## Phase 2.1.x — MEMFS pipe-through, byte-equivalent codegen (2026-05-14, pass)

**Status: derisk passed in one shot.** The wasm cc1 compiles real C
source to real m68k assembly via MEMFS, byte-identical to what the
native `m68k-apple-macos-cc1` emits for the same input.

### What the harness proves

`spike/wasm-cc1/test/memfs-pipe.mjs`:

1. Imports `cc1.mjs` (the ES module from Phase 2.1's relink).
2. Writes `int add(int a, int b) { return a + b; }` to `/tmp/test.c`
   in MEMFS.
3. Calls `Module.callMain(["-quiet", "-mcpu=68020", "/tmp/test.c", "-o", "/tmp/test.s"])`.
4. Reads `/tmp/test.s` back out.
5. Sanity-checks the assembly contains `link.w`, `move.l`, `add.l`,
   `unlk`, `rts` — the expected m68k function prologue/epilogue +
   add instruction.

All pass. Exit code 0. Output (258 bytes):
```
add:
        link.w %fp,#0
        move.l 8(%fp),%d0
        add.l 12(%fp),%d0
        unlk %fp
        rts
# macsbug symbol
        .byte 131
        .ascii "add"
        ...
        .ident "GCC: (GNU) 12.2.0"
```

This matches the native build's output for the same source verbatim.

### How the cc1 argv was derived

Ran the stage 1 native cross-gcc with `-v` and grepped the cc1 line:

```bash
docker run --rm -v /tmp:/host wasm-retro-cc/phase2-1-builder:latest \
  /spike/build/stage1/gcc/xgcc -B/spike/build/stage1/gcc/ \
  -v -S /host/test.c -o /host/test.s
```

The grepped invocation:
```
cc1 -quiet -v -iprefix .../m68k-apple-macos/12.2.0/ \
    -isystem .../include -isystem .../include-fixed \
    -Wno-trigraphs /tmp/test.c -quiet \
    -dumpdir /tmp/ -dumpbase test.c -dumpbase-ext .c \
    -mcpu=68020 -version -o /tmp/test.s
```

For our header-free test source we dropped `-iprefix` /
`-isystem` / `-dumpdir` / `-dumpbase*` / `-version`. They become
required as soon as the source `#include`s anything (covered by the
next sub-spike, sysroot vendoring).

### Key wiring details (from the harness)

```javascript
const mod = await import("./cc1.mjs");
const Module = await mod.default({
  noInitialRun: true,                       // don't auto-run main
  print:    (s) => stdout.push(s),
  printErr: (s) => stderr.push(s),
});
Module.FS.writeFile("/tmp/test.c", source); // emscripten MEMFS
const rc = Module.callMain([...]);          // throws ExitStatus on exit
const asm = new TextDecoder().decode(
  Module.FS.readFile("/tmp/test.s")
);
```

`callMain` throws an `ExitStatus` exception on `exit()` rather than
returning. Catch and read `.status`. `Module.FS` is the
`EXPORTED_RUNTIME_METHOD` we put in LDFLAGS at relink time.

### What this rules out

The hypothesis "cc1.wasm loads but its m68k backend / option handling
/ MEMFS interaction will reveal differences from the native build."
It doesn't — the output is byte-identical. The remaining Phase 2.1
sub-spikes are:

- **2.1.y — sysroot vendoring.** Bake Retro68's CIncludes + Universal
  Headers into MEMFS so cc1 can resolve `<Quickdraw.h>` etc. Strategy
  TBD: Emscripten `--preload-file` at link time, or a tarball
  unpacked into MEMFS at runtime by the JS harness.
- **End-to-end test against `spike/hello_toolbox.c`.** Compile the
  Phase 2.0 derisk source via the wasm cc1 and diff against the
  native build. If equivalent, Phase 2.1 (the *whole* sub-spike, not
  just the load test) is done.


---

## Phase 2.1 — end-to-end: byte-identical compilation of hello_toolbox.c (2026-05-15, done)

**Status: full Phase 2.1 sub-spike complete.** The wasm cc1 compiles
`spike/hello_toolbox.c` (the same C source the Phase 2.0 binary
booted from) via the Retro68 SDK sysroot mounted into MEMFS, and the
output is **byte-for-byte identical** to what the native
`m68k-apple-macos-cc1` produces for the same input.

```
diff hello_toolbox_native.s hello_toolbox_wasm.s
(exit 0 — no differences)
```

Same 694 bytes of m68k assembly. Same A-trap opcodes. Same MacsBug
symbol. Same `qd+202` offset for `&qd.thePort` (confirming Retro68's
mac68k struct packing). Same everything.

### What the harness does

`spike/wasm-cc1/test/compile-hello-toolbox.mjs`:

1. Loads `cc1.mjs` (the ES module from relink).
2. Mounts the host sysroot at `/sysroot/` inside cc1's MEMFS via
   Emscripten's **NODEFS** (linked in via `-lnodefs.js` + exported
   via `EXPORTED_RUNTIME_METHODS=NODEFS`).
3. Writes `hello_toolbox.c` to `/tmp/` in MEMFS.
4. Invokes `cc1` with `-isystem /sysroot/gcc-include -isystem /sysroot/include -mcpu=68020`.
5. Reads `/tmp/hello_toolbox.s` back out.
6. Sanity-checks the A-trap opcodes and Pascal string content.

### Sysroot construction

Combined two sources:

1. **Retro68's CIncludes + Universal Headers** — 109 files / 15 MB.
   Pulled from the pre-built `ghcr.io/autc04/retro68@sha256:e8b6cc8…`
   image's `/Retro68-build/toolchain/m68k-apple-macos/include/`. Use
   `cp -L` to resolve symlinks; many of the headers are symlinks into
   `multiverse/CIncludes/`.
2. **GCC's builtin headers** — `stddef.h`, `stdbool.h`, etc., from
   our own stage 1 build's `gcc/include/`. Without these, Retro68's
   `Multiverse.h` fails to find `<stdbool.h>`.

Sysroot lives at `spike/wasm-cc1/build/sysroot/`:

```
sysroot/
├── gcc-include/         # GCC builtins (stdbool, stddef, ...)
└── include/             # Retro68 CIncludes (Quickdraw, Windows, ...)
```

cc1 needs **both** `-isystem` paths. Order matters less than
having both present.

### A-trap inlining proof

The Retro68 SDK headers declare Toolbox calls with `= { 0xAxxx }`
GCC extension. That's NOT an extern function — GCC inlines the trap
opcode directly at the call site. So in our wasm cc1's output for
`InitGraf(&qd.thePort)`:

```asm
pea qd+202        ; push &qd.thePort
.short 0xa86e     ; the InitGraf A-trap word, emitted as inline
                  ; 16-bit data — that IS the function call
```

No `InitGraf` symbol in the output. No call to an extern. This is
fundamentally why the Phase 1 PCC pipeline needed a hand-written
stub layer (`libtoolbox-stubs.a`) — PCC can't parse `= { 0xAxxx }`.
Phase 2's GCC pipeline doesn't need stubs because it parses and
inlines the syntax natively.

### NODEFS wiring lessons

- `Module.NODEFS` is undefined unless added to
  `EXPORTED_RUNTIME_METHODS` at link time AND `-lnodefs.js` is in
  the link line. Both are needed; first attempt with only the export
  threw "Cannot read properties of undefined (reading 'mount')".
- NODEFS is a Node-only convenience. For the browser deployment of
  cc1 we'll need a different strategy: either Emscripten's
  `--preload-file` at link time (bakes the sysroot into the .wasm
  asset bundle, ~3 MB extra brotli) or a fetched tarball unpacked at
  runtime via a tar parser in JS. Both deferred to packaging
  (Phase 2.5).
- Use the same wiring pattern for any Phase 2.x test that needs the
  sysroot — define `mountSysroot(Module, hostPath)` once, reuse.

### What this sub-spike rules out for the rest of Phase 2

The wasm cc1 is a faithful port of the native one — same backend,
same option handling, same emission. There is no remaining "but
will it behave differently from native?" risk for cc1. Phase 2.2
(`as`) and 2.3 (`ld`+Elf2Mac) are the same shape — Canadian cross
to wasm32-emscripten — and the lessons (`CONFIG_SITE`, `-Os -g0` to
dodge finalize OOM, manual relink for wasm flags, etc.) all transfer.

### Files

- `spike/wasm-cc1/test/memfs-pipe.mjs` — trivial pipe-through harness
- `spike/wasm-cc1/test/compile-hello-toolbox.mjs` — end-to-end harness
- `spike/wasm-cc1/build/sysroot/` — vendored Retro68 SDK + GCC builtins
- `spike/wasm-cc1/build/test/hello_toolbox_wasm.s` — wasm cc1 output
- `spike/wasm-cc1/build/test/hello_toolbox_native.s` — native cc1 output


---

## Phase 2.2 — `as` ported in one shot, byte-identical (2026-05-15, done)

**Status: one-shot success.** The Phase 2.1 lessons transferred so
cleanly that the binutils stage 2 build succeeded **first try** with
no iteration — same `CONFIG_SITE` answers, same `-Os -g0`, same
`make -k`, same manual-relink-for-wasm-flags pattern.

### Sizes

| Artefact | Raw wasm | Brotli |
| --- | --- | --- |
| `as.wasm` | 764 KB | 270 KB |
| `as.mjs`  | 81 KB | — |
| `ld.wasm` | 1.0 MB | 304 KB |
| `ld.mjs`  | 80 KB | — |

Phase 2.2 + 2.3 combined = ~574 KB brotli. Plus cc1's 3.3 MB brotli =
~3.9 MB brotli for the **whole** C → MacBinary toolchain. Comfortably
under the original 6-8 MB target.

### End-to-end: byte-identical to native `as`

`spike/wasm-binutils/test/assemble.mjs` feeds the Phase 2.1 wasm-cc1
output (`hello_toolbox_wasm.s`) through the wasm `as`:

```
as.wasm: -march=68020 hello_toolbox.s -o hello_toolbox.o
→ 856 bytes, m68k ELF32 big-endian, InitGraf trap (0xa86e) preserved
```

Diffed against `stage1/gas/as-new` (native cross-as) on identical
input:
```
shasum -a 256 hello_native.o hello_toolbox.o
a7a22b56…  hello_native.o
a7a22b56…  hello_toolbox.o    <-- IDENTICAL
```

Same as cc1 in Phase 2.1: the wasm port is byte-equivalent to the
native cross-tool. No surprises.

### Relink "lesson" — let make tell us the link command

First relink attempt had hardcoded .o file lists I'd guessed by
eyeballing Makefile.am. They drifted from reality (`as-new.o` doesn't
exist; the makefile uses `as.o`, `app.o`, `flonum-*.o`, etc. in a
different order with different libraries). Fix: invoke
`emmake make V=1 as-new`, grep the `libtool: link:` line, sed
`-o as-new` → `-o as.mjs`, eval with extra wasm LDFLAGS appended.

Pattern generalizes: **never hardcode .o lists when the makefile
knows them.** Capture the link command, mutate the output flag,
re-execute. Works for any autoconf/libtool project where the build
system knows the canonical link line.

### What Phase 2.2 reveals about Phase 2.3 (ld)

`ld.wasm` (1.0 MB) and `ld.mjs` (80 KB) **also built in the same
stage 2 run**. Smoke-tested: `ld --version` prints "GNU ld (GNU
Binutils) 2.39". The hard part of Phase 2.3 will be:

1. Getting Retro68's `-elf2mac` mode wired in (binutils builds m68k
   `ld` with extra emulations; `eelf32m68k.o` is the standard m68k
   emulation, `eelf_m68k_mac.o` would be the Retro68 mac-specific
   variant — verify present).
2. Vendoring `libretrocrt.a` + `libInterface.a` + `libc.a` into the
   sysroot so ld has libs to link against.
3. Possibly: a separate small `Elf2Mac` port (custom C++ binary
   outside binutils, in `/Retro68/Elf2Mac/`).

But all the **Canadian-cross machinery is solved.** No new build-
system iterations expected.


---

## Phase 2.3 — ld done, Elf2Mac partial (2026-05-15, paused)

### What landed

- **`ld.wasm` (1.0 MB) + `ld.mjs` (80 KB)** — built alongside `as`
  in the Phase 2.2 stage 2 run. Smoke passes (`--version`,
  `--help`). Supports `elf32-m68k` target with `m68kelf` emulation.
- **Native `Elf2Mac` (240 KB Linux ELF)** — Phase 2.3 stage 1 builds
  cleanly via cmake with three patches applied to Retro68's source
  (`spike/wasm-elf2mac/build.sh` `prepare_resourcefiles`):
  1. `boost::filesystem` → `std::filesystem` (avoids needing wasm-
     compiled Boost.Filesystem, which Emscripten doesn't ship).
  2. Add missing transitive standard includes (`<vector>`,
     `<functional>`, `<algorithm>`) that `<boost/filesystem.hpp>`
     was pulling in implicitly.
  3. Strip `ResInfo` executable target (depends on
     Boost.program_options, not needed for Elf2Mac).
- **HFS stub** (`spike/wasm-elf2mac/hfs-stub.{c,h}`) — Retro68's
  ResourceFile.cc has one method that writes `.dsk` HFS volumes via
  libhfs. Elf2Mac never calls that method; the stub satisfies the
  compile-time include + link-time symbol resolution with no-ops.

### What blocks the wasm port

`Elf2Mac` depends on **libelf** (`gelf.h`, `elf_nextscn`,
`gelf_getshdr`, `elf_strptr`, `gelf_getsym`, …) for ELF parsing.
Available on the host via `libelf-dev` (Ubuntu), but:

- Emscripten doesn't ship a port for libelf (their catalog has boost,
  sdl, freetype, etc. — not libelf).
- Host's `libelf.so` / `libelf.a` is aarch64-native; can't link
  against wasm32 objects.
- No `--use-port=libelf` available.

### Path forward (Phase 2.3.x — next session)

Three viable approaches; updated preference after a libelf-for-wasm
attempt:

**(a) Build libelf for wasm via elfutils — attempted, hit secondary
walls.** Scaffolding shipped (`spike/wasm-elf2mac/build.sh libelf` +
`build-libelf-inner.sh`, elfutils 0.190 source pinned). Progress:

- ✅ Heredoc-via-separate-script pattern dodges the bash-quote-escape
  rabbit hole that bit our first try at embedding configure inline.
- ✅ `-sUSE_ZLIB=1` in CFLAGS satisfies elfutils' `gzdirect` link
  probe (Emscripten's bundled zlib port).
- ✅ `bash $(find -name config.guess)` finds the script in elfutils'
  source layout (config/config.guess, not top-level).
- ❌ Configure fails at "failed to find argp_parse". `argp_parse` is
  glibc-specific (GNU argument-parsing library, no portable POSIX
  equivalent). Emscripten's musl-derived libc doesn't provide it.

Next move for (a): vendor a portable `argp-standalone` library and
either point `--with-argp-standalone` at it (if elfutils' configure
accepts that) or pre-build it as a wasm `.a` and add to LDFLAGS.
`argp-standalone` is small (~1500 LOC), self-contained C. Adds ~1
hour of work; may then expose further glibc-isms in elfutils.

**Decision update:** (a) has proven harder than initially estimated.
Switching preference to (b) for the next attempt:

**(b) Hand-roll a minimal ELF parser.** Elf2Mac uses a closed set of
~12 libelf calls (`elf_begin`, `elf_kind`, `elf_getshdr`,
`elf_nextscn`, `elf_strptr`, `gelf_getshdr`, `gelf_getsym`,
`elf_getdata`, `elf_errmsg`, `elf_end`, `elf_version`,
`elf_setshstrndx`). All do straightforward reads against the ELF
struct layout (which `elf.h` from the kernel headers gives us — and
emcc ships this). A ~300 LOC `MinimalElf.cc` shim that implements
just these functions over a memory-mapped buffer would unblock
Elf2Mac with zero further dependencies. Easier than fighting
elfutils' build tree.

**(c) Defer and use a Docker call-out.** Until Elf2Mac is in-browser,
the playground could keep using the Phase 2.0 vendoring path: cv-mac
fetches CI-built `.bin` files. That ships Phase 2 partial but loses
the "compile in browser end-to-end" promise.

**Decision (paused-here):** Pick (b) next session — 300-LOC of
hand-rolled ELF read is more bounded than libelf's transitive deps.
Document `MinimalElf.cc` against the closed set of 12 libelf calls
Elf2Mac actually uses (grep `Elf2Mac/*.cc` for `elf_` / `gelf_`).

**Update (later same session, 2026-05-15): (b) WORKED.**
`MinimalElf.cc` is 240 LOC of pure C++. Drop-in replacement for
libelf — same opaque types (`Elf`, `Elf_Scn`, `Elf_Data`), same
function signatures (`elf_begin`, `gelf_getshdr`, ...). Reads ELF
once at `elf_begin`, byte-swaps Elf32 fields from big-endian source
to host-endian on each `gelf_*` read. Linked into Elf2Mac instead of
libelf via a CMake `add_library(ELF INTERFACE)` that depends on the
`MinimalElf` static lib. Compatibility shims `gelf.h` and `libelf.h`
in `minimal-elf/` point at `MinimalElf.h` so existing `#include
<gelf.h>` in Elf2Mac's source compiles unmodified.

The 10 libelf calls Elf2Mac uses (audit via grep over the source):
`elf_begin`, `elf_errmsg`, `elf_end`, `elf_version`, `elf_nextscn`,
`elf_getshdr` → `gelf_getshdr`, `elf_strptr`, `elf_getshdrstrndx`,
`elf_getdata`, `gelf_getehdr`, `gelf_getsym`, `gelf_getrela`. Plus
the `GELF_R_SYM` / `GELF_R_TYPE` / `GELF_ST_BIND` / `GELF_ST_TYPE`
macros — implemented as forwarders to the standard `ELF64_R_*`
macros from `<elf.h>`. gelf_getrela re-encodes Elf32's 32-bit
`r_info` field as `(sym << 32) | type` to match Elf64 layout (which
the macros expect).

### Elf2Mac.wasm built, end-to-end use needs one more piece

Final sizes after this session:

| Artefact | Raw | Brotli |
| --- | --- | --- |
| `Elf2Mac.wasm` | 280 KB | **81 KB** |
| `Elf2Mac.mjs` | 80 KB | — |

Combined Phase 2 toolchain in brotli:
- cc1: 3.3 MB
- as:  270 KB
- ld:  304 KB
- Elf2Mac: 81 KB
- **Total: ~4.0 MB brotli** for the whole C → MacBinary II in-browser pipeline.

Build-time landmines for the wasm port (after MinimalElf solved the
libelf problem):

1. **Boost.algorithm uses C++ exceptions.** Compile-and-link with
   `-fwasm-exceptions` (NOT `-fexceptions`). Mixing exception models
   between compile and link causes `__cxa_uncaught_exceptions:
   undefined symbol` at the link step. Use `-fwasm-exceptions`
   consistently in `CMAKE_CXX_FLAGS` and in the relink LDFLAGS.
2. **CMake's emcc output is `Elf2Mac.js` (not `Elf2Mac`).** Relink's
   sed substitution needs `-o Elf2Mac.js |` → `-o Elf2Mac.mjs |`,
   not `-o Elf2Mac |` → `-o Elf2Mac.mjs |`.
3. **CMake uses `VERBOSE=1`, not `V=1`** for verbose make output.
   Autoconf-built projects (cc1, binutils) use `V=1`; CMake-built
   projects (Elf2Mac) use `VERBOSE=1`. The relink step's
   command-capture regex needs to be aware of both styles.

### Path forward — Phase 2.3c

Elf2Mac.mjs LOADS in Node but `main()` aborts immediately because
the very first thing it does is call `fork()` to spawn an `ld`
subprocess (Elf2Mac orchestrates the link, then converts the
resulting ELF to MacBinary). For our wasm pipeline we want the
*converter* part only — the wasm `ld` is a separate step that JS
glue code orchestrates externally.

**Phase 2.3c — convert-mode Elf2Mac.** Patch `Elf2Mac.cc:RealLD` to
no-op (or expose a new CLI flag like `--no-ld` that skips the fork).
Take an existing ELF as input, emit MacBinary directly. End-to-end
test: pipe `hello_toolbox.o` (Phase 2.2 output) through wasm `ld`
(plain ELF executable) then through patched-`Elf2Mac.wasm` →
MacBinary II → `inspect_macbinary.py` PASS → diff against Phase 2.0
reference `hello-toolbox-retro68.bin`.

Estimated effort: small (a few-line patch to Elf2Mac.cc). No new
build-system landmines expected.

### Phase 2.3 — landmines documented before next attempt

Things we've learned the hard way and should not repeat:

1. **Boost.Filesystem requires compiled lib.** Replace with
   `std::filesystem` for C++17 projects. One-file mechanical port
   for ResourceFile.cc.
2. **`<boost/filesystem.hpp>` pulls in `<vector>`, `<functional>`,
   `<algorithm>` transitively.** When swapping it for `<filesystem>`
   you must add them explicitly or compile fails on `std::vector`
   not found.
3. **CMake's emscripten toolchain restricts include search to wasm
   sysroot.** Setting `-DBoost_INCLUDE_DIR=/usr/include` is too
   broad — pulls host glibc bits. Stage Boost headers into a
   dedicated dir under the build tree, point at that.
4. **`find_library(HFS_LIBRARY NAMES hfs)` followed by
   `target_link_libraries(... ${HFS_LIBRARY})` errors out as
   NOTFOUND in CMake.** Pre-set the variable to a target name (or
   empty string in safe contexts) to bypass.
5. **elfutils requires `argp_parse`.** Glibc-only. Emscripten musl
   doesn't provide it. Use `argp-standalone` or hand-roll ELF
   parsing.
6. **Bash heredoc-in-heredoc with CFLAGS quoting is a quote-escape
   trap.** Use a separate inner script file invoked via
   `run_in_container "bash /path/to/inner.sh"`.

### Bytes-of-progress summary

| Stage  | Status | Artefact | Brotli |
| --- | --- | --- | --- |
| Phase 2.0 | ✅ | hello-toolbox-retro68.bin (vendored) | 12 KB |
| Phase 2.1 | ✅ | cc1.wasm + cc1.mjs | 3.3 MB |
| Phase 2.2 | ✅ | as.wasm + as.mjs | 270 KB |
| Phase 2.3a | ✅ | ld.wasm + ld.mjs | 304 KB |
| Phase 2.3b | 🟡 | Elf2Mac.wasm (blocked on libelf wasm port) | est. ~150 KB |
|  | **Total so far** | | **3.9 MB brotli** |

Compiler + assembler + linker = **3.9 MB brotli** in-browser. Even
with Elf2Mac.wasm added (~150 KB), the full pipeline fits comfortably
under the original 6-8 MB target.

---

## Phase 2.3d — first end-to-end .bin (2026-05-15)

End-to-end glue done. `spike/wasm-cc1/test/full-pipeline.mjs` now
pipes `hello_toolbox.c` through cc1 → as → ld → Elf2Mac and emits a
**single-fork MacBinary II APPL** that passes
`spike-pcc/inspect_macbinary.py`'s structural check:

```
type        = b'APPL'
creator     = b'????'
data fork   = 20 bytes
rsrc fork   = 622 bytes
rsrc types  = CODE×2, DATA×1, RELA×2
CODE 0      = above_a5=48 below_a5=300 jt_size=16 jt_a5_off=0x20 jt_entries=2

STRUCTURAL CHECK PASSED (APPL, CODE 0+1, below_a5>0, DATA, RELA)
```

### The fix that made this work (#15.1)

**Pass `-o /tmp/out.bin`, not `-o /tmp/out`.** Elf2Mac calls
`ResourceFile::write(path, autodetect)`, which decides the on-disk
shape based on `path.extension()`:

| Extension | Format |
| --- | --- |
| `.bin` | `Format::macbin` — single-fork MacBinary II (what we want) |
| `.as` | `Format::applesingle` |
| `.dsk` | `Format::diskimage` |
| *anything else* | `Format::basilisk` on non-`__APPLE__` hosts — splits into `<name>` + `.rsrc/<name>` + `.finf/<name>` |

The wasm host registers as non-`__APPLE__` from Elf2Mac's
preprocessor POV, so any output path without `.bin` falls through to
Basilisk-style split forks. Our earlier pipeline run with
`-o /tmp/out` produced exactly that — three files in `.rsrc/`,
`.finf/`, plus the bare data — instead of one MacBinary II APPL.

Implication: we do **not** need a fifth wasm tool (wasm-rez or
hfsutils) to combine forks. Elf2Mac does it natively when asked
correctly. Saves 300 KB of bundle and a chunk of integration glue.

Also note Elf2Mac's `--mac-single` mode is **wrong** for our
libretrocrt-linked output — produces `below_a5=0` which fails the
structural check (Process Manager won't allocate libretrocrt's
globals). Default segments-mode is what we want, even with a flat
ld script.

### The 622 B vs 9 KB gap (#15.2)

The reference `hello-toolbox-retro68.bin` (from the Phase 2.0
Retro68 docker build) has:

```
rsrc types  = CODE×9, DATA×1, RELA×9, SIZE×1
data fork   = 0 bytes
rsrc fork   = 12247 bytes
below_a5    = 1428
```

Three real differences vs our 622 B output:

1. **CODE×9 vs CODE×2** — Retro68's CMake build invokes Elf2Mac with
   its default `SegmentMap` (Runtime + 6 libstdc++/locale segments
   + Main). Elf2Mac's `CreateLdScript` then emits a multi-segment ld
   script that splits libs into named output sections, one per
   `SegmentInfo` filter. Our pipeline pre-links with the static
   `retro68-flat.ld` which collapses everything into a single `.text`,
   so even though Elf2Mac runs in `MultiSegmentApp` mode it finds
   only one populated segment (Main, the `*` catch-all). Reference
   has 7 mostly-empty CODE resources for unused libstdc++ chunks; we
   skip them.

2. **No SIZE resource.** Retro68's CMake `add_application` macro
   compiles a Rez source alongside the C, producing a `SIZE`
   resource that the Finder reads to decide app memory allocation.
   We don't run Rez in this pipeline at all — the playground's
   classic-vibe-mac downstream already has wasm-rez for the .r
   files, so this gap closes naturally when the two repos meet
   end-to-end (cv-mac #64).

3. **Data-fork content.** Reference has `data fork = 0` (Retro68
   strips the placeholder Object.cc's stage 2 string). Our pipeline
   carries the literal `"Built using Retro68."` from
   `SingleSegmentApp`'s `file.data = "..."` line. Cosmetic.

### Path to bootable equivalence

The structural pass doesn't prove the binary will run on a real
68k. To close that:

- **Multi-segment ld script** — port Elf2Mac's
  `SegmentMap::CreateLdScript` (~140 LOC across `LdScript.cc` +
  `SegmentMap.cc`) into something the JS host can run, OR add a
  `--write-ldscript-only <path>` CLI flag to Elf2Mac and rebuild the
  wasm. The flag is the smaller change; the rebuild costs a docker
  round-trip.
- **SIZE resource** — pipe through wasm-rez (already shipping in
  classic-vibe-mac) with a default `SIZE` template, then splice into
  the resource fork. This is the natural cross-repo handoff.
- **Boot test** — wire the in-browser pipeline output through
  classic-vibe-mac's HFS patcher → BasiliskII, the way the existing
  prebuilt-demo path does. Same hot-load mechanics as #80's Show
  Assembly panel; new orchestration on top.

### Updated bytes-of-progress

| Stage  | Status | Artefact | Brotli |
| --- | --- | --- | --- |
| Phase 2.0 | ✅ | hello-toolbox-retro68.bin (vendored) | 12 KB |
| Phase 2.1 | ✅ | cc1.wasm + cc1.mjs | 3.3 MB |
| Phase 2.2 | ✅ | as.wasm + as.mjs | 270 KB |
| Phase 2.3a | ✅ | ld.wasm + ld.mjs | 304 KB |
| Phase 2.3b | ✅ | Elf2Mac.wasm + Elf2Mac.mjs (MinimalElf, RealLD stubbed) | 81 KB |
| Phase 2.3c | ✅ | convert-mode Elf2Mac.wasm built and proven | (same) |
| Phase 2.3d | ✅ | end-to-end .bin (single-segment, structurally valid) | (n/a — pipeline test) |
|  | **Total** | | **~4.0 MB brotli** |

End-to-end C → MacBinary II APPL in the browser, in ~4 MB brotli,
all four tools chained through MEMFS, structurally valid output.
Bootable equivalence still requires the multi-segment ld script +
SIZE resource — both bounded follow-ups.

---

## Bundle hardening for cv-mac integration (2026-05-15, PR #20)

Three things had to land before the cv-mac side could vendor and use
the full pipeline cleanly. All small, all surprised someone.

### Sysroot blob split

The original `build-show-asm-bundle.mjs` packed one blob — gcc-include
+ include. Adding lib + ld script for the full-pipeline path would
have ~tripled the *cold-load* cost of the Show Assembly panel (~3.6 MB
brotli → ~4.7 MB) for a payload that path never reads.

Fix: two blobs, two indices. `sysroot.bin` (headers, 185 KB br) and
`sysroot-libs.bin` (libs + ld script, 1.1 MB br). Consumers choose
their fetch list per operation. cv-mac's `compileToAsm` fetches only
the headers blob; `compileToBin` fetches both.

Browser HTTP cache still hits the same URL for shared artefacts
(notably `cc1.wasm`), so a user who opens Show Assembly first and
then clicks Build .c reuses the cached compiler.

### Case-fold sysroot aliases (#20)

cv-mac's first end-to-end `compileToBin` run failed at cc1 with
`fatal error: strings.h: No such file or directory` — despite the
header being in our sysroot tree on disk.

Two distinct files coexist in the Retro68 SDK:
- `include/Strings.h` — Mac Toolbox `StringHandle`, `EqualString`, …
- `include/strings.h` — BSD-style `strcasecmp`, `strncasecmp`.

Newlib's `string.h` does `#include <strings.h>` (lowercase, BSD) on
line 24. On case-sensitive FS (Linux / Emscripten MEMFS) this resolves
to the lowercase variant. On macOS HFS+ (case-insensitive default),
the two files collapse to one on extraction — whichever case won the
extraction order. Our packed sysroot had `Strings.h` (Toolbox) and *no*
`strings.h`. MEMFS in the browser is case-sensitive and refused the
lowercase include.

Fix: the bundle packer now emits a **lowercase alias entry** for any
file whose lowercase path differs from the on-disk path AND whose
lowercase form isn't already a distinct entry. Zero blob-byte cost —
aliases share `{o,l}` with the original. ~38 alias entries on the
headers blob, ~1.7 KB JSON index overhead.

The on-disk content for `Strings.h` is actually the BSD `strings.h`
(the Toolbox version got lost to the case-collision). True fix is
re-extracting the sysroot on a case-sensitive filesystem (Linux
container or APFS case-sensitive volume). Alias workaround is
forward-compatible — it costs nothing once the underlying extraction
stops collapsing.

**General rule:** any packaging step that runs on macOS HFS+ should
be checked for case collisions on identifiers known to differ only
in case. Toolbox Pascal naming vs lowercase C convention is the
classic offender; OpenStep/Foundation Naming vs POSIX is another.

### Library whitelist

`lib/` ships many archives; only a few are referenced by a C-only
Retro68 link. The bundle whitelist:

  libretrocrt.a + libInterface.a + libc.a + libm.a

Excludes:
- `libstdc++.a` (17 MB) — C++ STL, not used.
- `libsupc++.a` (1 MB) — C++ runtime support.
- `libg.a` (5 MB) — debug duplicate of libc.
- `libNavigation.far.a` / `libRetroConsole.a` — niche, not in default link.
- Full `ldscripts/` subdir — we ship only `retro68-flat.ld` (single ld
  script wired to `_MULTISEG_APP = 0`).

That keeps the libs blob at 7.2 MB raw / 1.1 MB brotli. If a future
sample needs C++ or RetroConsole, expand the whitelist; if a real
program references math symbols beyond libm, the link will fail
loudly and we add the next archive.

---

## Phase 2.3d — `_start` fallback was pre-satisfying libretrocrt's real entry point (2026-05-15)

Caught by the **first eyes-on test** of the in-browser C compile-and-run
loop on cv-mac's deployed playground (cv-mac #84 and follow-up). Single
fix that closes "you can write and run C in the browser" — without it,
every wasm-built binary launches and immediately exits, because `main`
never runs.

### Symptom

cv-mac user double-clicks `WasmHello` (an in-browser-built `int main()
{ while(1); return 0; }`). Finder runs the launch animation, app
"executes," app disappears. No type-3 dialog, no error, no infinite
spin. Pasted a `SysBeep(30); while(1);` source: same result — no beep,
clean exit. Replaced the spin with `for (volatile long i = 0; i <
2e8; i++) ;`: same again, with no measurable wall-clock delay before
exit. So `main()` is never actually being called.

### Root cause

Extracting CODE 1 from the offending `.bin` and computing the `_start`
offset from the entry-trampoline's `ADDI.L #imm, (A7)` immediate
(stored = 6 in the broken build) put `_start` at offset 16, where the
bytes were a bare **`4e 75`** — m68k RTS. That's the
**`PROVIDE(_start = .)`** *fallback* from `retro68-flat.ld`:

```
PROVIDE(_start = .); /* fallback entry point to a safe spot - needed for libretro bootstrap */
Retro68InitMultisegApp = .;
SHORT(0x4e75); /* rts */
```

Comparing against the reference `hello-toolbox-retro68.bin`'s CODE 1 at
the same offset: `4e 56 ff f8 20 3c …` (`LINK A6, #-8; MOVE.L #imm,
D0; …`) — libretrocrt's real `_start` function prologue. Reference
build pulled it; ours didn't.

Why ours doesn't: **GNU ld's archive search is symbol-driven** — it
pulls a `.o` from a `.a` only when an unresolved symbol references the
defined symbols inside. `in.o` contains `main` and references nothing
in libretrocrt, so the archive scan never reaches start.c.obj. The
script's `PROVIDE(_start = .)` *defines* `_start` (as the fallback
RTS), the `ENTRY(_start)` directive is satisfied, the link succeeds,
and the resulting binary has `_start` pointing at a bare RTS.

`-u _start` *should* have forced the search but didn't — PROVIDE
defines `_start` during script evaluation, which happens before the
archive search reaches the end of its pass.

### The fix (three things together)

1. **Extract `libretrocrt.a:start.c.obj` as a standalone `.o`** and link
   it ahead of any archive:
   ```
   ld ... -o out.gdb /sysroot/lib/start.c.obj in.o --start-group ...
   ```
   start.c.obj's `_start` is a strong symbol; PROVIDE sees `_start`
   already defined and skips. The trampoline lands on real libretrocrt
   code that calls `Retro68Relocate`, `Retro68CallConstructors`,
   `main()`, etc.

2. **`--start-group … --end-group`** around all the archives. Once
   start.c.obj is pulled, it transitively references atexit / malloc /
   exit etc., which cross-reference between libretrocrt / libc / libgcc.
   Without `--start-group`, ld's single-pass scan misses these. With
   it, the archives are scanned iteratively until no new unresolved
   symbols remain.

3. **Add `libgcc.a` to the lib bundle.** libretrocrt's `syscalls.c.obj`
   uses `__udivsi3` / `__mulsi3` (32-bit soft-divide / soft-mul, since
   m68k has no native 32-bit divide). These live in `libgcc.a`, not in
   any of the libretrocrt / libInterface / libc / libm archives. The
   Retro68 ld driver auto-adds `-lgcc`; the bare-bones ld we ship does
   not. Extracted from
   `/Retro68-build/toolchain/lib/gcc/m68k-apple-macos/12.2.0/libgcc.a`
   in the autc04/retro68 docker image (651 KB raw / ~210 KB brotli).

### Bundle changes

- `LIB_KEEP_BASENAMES` gains `libgcc.a`.
- Bundle packer extracts `start.c.obj` from `libretrocrt.a` and ships
  it as a standalone entry at `/lib/start.c.obj` inside
  `sysroot-libs.bin`. Side-effect: also writes it to the source sysroot
  tree so the spike's `full-pipeline.mjs` (which mounts via NODEFS,
  not the packed blob) can link against it directly. One canonical
  source of truth, two delivery paths.
- `full-pipeline.mjs` and `verify-show-asm-bundle.mjs` updated to use
  the new link order + `--start-group` + libgcc.

### Result

`while(1);` source now produces:

```
data fork  =  20 bytes
rsrc fork  =  9194 bytes (was 542)
CODE×2     (jump table + real Main with libretrocrt's _start)
DATA×1, RELA×2
below_a5   =  1400  (vs reference 1428; was 76)
```

Within 2% of the reference's structural fingerprint. Test on deployed
Pages confirms the bin boots — the `while(1);` source hangs BasiliskII
exactly as expected (main runs, doesn't return). The pipeline now
produces actually-running classic Mac apps.

### General rule

When linking via `ld` directly (not through a compiler driver), be
explicit about three things that drivers do for you:

1. **Order matters.** Object files providing required symbols (like
   `_start`) must appear *before* any script-side `PROVIDE` of those
   symbols, otherwise the fallback wins.
2. **`--start-group` for archive cross-references.** Single-pass scan
   silently drops cross-archive symbols. The cost is a slightly slower
   link; the benefit is correctness.
3. **`libgcc.a` is not optional** for C programs on m68k. The compiler
   emits calls to soft-fp/-divide helpers that the rest of the C
   runtime doesn't provide.

---

## Follow-up: even with start.c.obj linked, PROVIDE still wins (2026-05-15 PM)

The fix above (link `start.c.obj` first) was *necessary* but not *sufficient*.
First eyes-on test on the deployed playground showed the resulting binary
still launches-and-exits — the trampoline still jumped to the fallback RTS,
not libretrocrt's real `_start`.

### What I expected vs what happens

The GNU ld manual says `PROVIDE`:

> "The PROVIDE keyword can be used to define a symbol only when it is
> referenced and *not defined in the input or output files*."

So with `start.c.obj` linked in (defining a strong `_start`), PROVIDE should
*skip*. It doesn't, on the bare-ld + `-T script` invocation we use. The
trampoline's `LONG(_start - _entry_trampoline - 6)` resolves to 6 (= fallback
location at offset 16 in CODE 1), not 0x1916 (= libretrocrt's real `_start`
~6 KB into the section). PROVIDE wins regardless.

I haven't fully diagnosed *why* — likely either:
- The script's PROVIDE is processed before archive scanning has fully
  unified all input symbols, so at script-eval time `_start` is still
  undefined from ld's POV.
- Or some GNU-ld quirk with `PROVIDE` having higher precedence than a
  pulled archive symbol when both define the same name at the address
  the PROVIDE evaluates to.

Either way, the practical fix is to remove the PROVIDE entirely.

### Fix

Ship a patched copy of `retro68-flat.ld` (named `retro68-flat-cv.ld`) with
the `PROVIDE(_start = .)` line replaced by a comment. The bundle packer
extracts the stock script, applies the regex transform, and writes the
patched script:

  - Into `sysroot-libs.bin` (under `ld/retro68-flat-cv.ld`) for the cv-mac
    consumer.
  - Onto disk at `sysroot/ld/retro68-flat-cv.ld` for the spike's NODEFS-
    mounted `full-pipeline.mjs`.

Both `full-pipeline.mjs` and `verify-show-asm-bundle.mjs` updated to pass
`-T /sysroot/ld/retro68-flat-cv.ld`.

### Empirical signal

Before patch (trampoline at offset 4 in CODE 1, offset-value at offset 12):

  bytes 12-15: 00 00 00 06   →   _start = trampoline + 6 + 6 = offset 16
                                  bytes 16-17:  4e 75   ← fallback RTS

After patch:

  bytes 12-15: 00 00 19 16   →   _start = trampoline + 6 + 0x1916 = offset 6432
                                  bytes 6432+:  4f ef ff f4 48 e7 1f 3a …
                                                ← libretrocrt's real prologue

The Retro68-reference binary has `0x12` at that position (its real `_start`
is ~24 bytes past the trampoline since it's a multi-segment app with extra
trampoline machinery). Same shape, different magnitude.

### Lesson

`PROVIDE` is not as conservative as the manual's wording suggests for bare-ld
links. If you can't audit the linker's exact behaviour, **don't trust PROVIDE
to defer to your strong symbols** — patch the script to remove the PROVIDE
and rely entirely on your input objects.

Compiler drivers (`m68k-apple-macos-gcc`, `gcc`, …) get this right because
they pre-link the runtime objects internally and arrange the symbol table
*before* the script's PROVIDEs are evaluated. Bare ld doesn't.

---

## Follow-up: the *flat* ld script is fundamentally wrong for libretrocrt (2026-05-15 PM)

After fixing the PROVIDE issue and adding the SIZE resource (cv-mac
#87), the wasm-hello binary *still* crashed at app launch with a
type-3 dialog ("application 'unknown' has unexpectedly quit"). The
"unknown" name was the tell — Mac OS was failing before it could
resolve the app from its resource fork.

### Root cause

`retro68-flat.ld` (which we'd been using all along) sets
`_MULTISEG_APP = 0` and lays out a single `.text` section containing
everything. **libretrocrt's `_start` was written for the multi-seg
case** — it expects the linker to have produced named sections
`.code00001`, `.code00002`, … one per `SegmentInfo`, which Elf2Mac
then walks at convert time to populate the CODE×N resources. Single
`.text` confuses the runtime relocator: it can't find the per-segment
A5 offsets it needs, applies relocations to wrong addresses, corrupts
the jump table, and the next branch lands on garbage.

### Confirmed via inspect_macbinary fingerprint

|                     | flat script (broken)  | multi-seg script (fixed) | Retro68 reference |
|---------------------|-----------------------|--------------------------|-------------------|
| Resource types      | `CODE×2, DATA×1, RELA×2` | `CODE×9, DATA×1, RELA×9` | `CODE×9, DATA×1, RELA×9, SIZE×1` |
| `below_a5`          | 1176                  | 1420                     | 1428              |
| `_MULTISEG_APP`     | 0                     | 1                        | 1                 |
| Boot status         | type-3 on launch      | (needs eyes-on)          | works             |

Within 8 bytes of `below_a5` and identical resource-type counts to the
reference (modulo SIZE which we splice separately).

### How we got the right script

`m68k-apple-macos-gcc`'s real link command path doesn't use a static
script at all — it passes `-elf2mac` to `m68k-apple-macos-ld`, which
is a wrapper that runs Elf2Mac. Elf2Mac in its default `--elf2mac`
mode calls `SegmentMap::CreateLdScript` (in `LdScript.cc`) to emit a
dynamic script tailored to the default SegmentMap, writes it to
`/tmp/ldscriptXXXXXX`, and feeds that to the real ld.

For our pipeline we don't run RealLD inside Elf2Mac (it's stubbed in
convert-only mode), so we never received that script. The result was
that we linked with the wrong (flat) layout and Elf2Mac then tried to
convert assuming multi-seg layout.

### The fix

Capture the script Elf2Mac generates and ship it as a static asset.
The default `SegmentMap` is hard-coded in `SegmentMap.cc`'s default
constructor, and the `_start` entry symbol is fixed for Retro68
builds — so the output script is deterministic and project-
independent. Ship as `/sysroot/ld/retro68-multiseg.ld` alongside the
existing `retro68-flat.ld` (still useful for non-libretrocrt use
cases).

Capture procedure (one-shot, baked into the bundle build):

  1. Pipe any C source through cc1+as+ld(flat)+Elf2Mac.
  2. Invoke Elf2Mac with `--mac-keep-ldscript` — emits the multi-seg
     script to `/tmp/ldscriptXXXXXX` AND prints the path to stderr.
  3. Copy the script bytes from MEMFS to disk.

Today this lives in `spike/wasm-cc1/build/sysroot/ld/retro68-multiseg.ld`
and the bundle packer ships it under the same path. Long-term cleaner
fix: have cv-mac's `compileToBin` invoke Elf2Mac twice (once with
`--mac-keep-ldscript` to extract the script, then run ld with that
script, then Elf2Mac again to convert). That removes the static
dependency on the captured script. Deferred — the static script is
deterministic for our use cases.

### General rule

When porting a Mac runtime crt to a bare-ld environment, the **runtime
crt and the ld script are a matched pair**. Don't mix-and-match a
"simple" flat script with a "real" runtime crt — the crt makes layout
assumptions the script must satisfy. If a runtime expects multi-seg,
use multi-seg; the script's job is to encode the layout the runtime
walks at startup.

### Same `PROVIDE(_start)` bug, second time (2026-05-15 PM follow-up)

Shipped wasm-retro-cc#24 (the multi-seg script) and the binary STILL
silently exited at app launch. Caught this on a fresh diagnostic: built
a CLI Musashi harness (cv-mac #89 / tools/m68k-runner/), ran our binary
through it, watched the entry trampoline jump to memory address 0 after
the `RTS`.

Cause: the multi-seg script Elf2Mac emits ALSO contains
`PROVIDE(_start = .)`. Same trap as the flat script — PROVIDE wins
over the input-object definition on bare-ld. CODE 1's
trampoline-offset immediate was `0x06` (= PROVIDE fallback), should
have been `0x258c` (= libretrocrt's real `_start`).

**Fix:** same patch — `sed s/PROVIDE(_start = .);/comment/` applied
to `retro68-multiseg.ld` at bundle-build time. CODE 1's immediate now
flips to `0x258c`, the trampoline jumps to the real _start, libretrocrt
takes control. Verified Node-side (Musashi runs ~10k instructions
before our incomplete trap stubs run out of context) — exactly the
right shape for a real boot.

**Lesson reinforced:** the patch we apply to one ld script must apply
to ALL scripts in the bundle. The retro68-flat-cv.ld got the
PROVIDE-strip treatment; the multi-seg copy didn't. **Audit checklist
when shipping a bundle update:** for every ld script in the package,
verify whether the PROVIDE(_start) line is present, and patch it if
so.

The harness's value showed immediately: 30 seconds of `m68k-run`
output replaced a 30-minute deploy-and-test cycle that would have
shown the same symptom (silent exit) without explaining where execution
actually went. Building it once paid for itself on the first run.
