# Motorola 68000 ABI Reference for wasm-retro-cc

This document describes the calling conventions the shim headers and PCC must agree on.
Any mismatch here causes silent data corruption or crashes inside the emulator.

## Register assignment

| Register | Role | Saved by |
|----------|------|----------|
| D0 | Return value (16/32-bit int) | Caller |
| D1 | Scratch | Caller |
| D2–D7 | Saved temporaries | Callee |
| A0 | Return value (pointer) | Caller |
| A1 | Scratch | Caller |
| A2–A6 | Saved temporaries | Callee |
| A5 | Global data pointer (Application globals) | Callee — **must never be modified** |
| A7 | Stack pointer | — |

## Standard C calling convention

- Parameters pushed **right-to-left** on the stack before the call
- Caller pops the stack after return (`cdecl`)
- 16-bit values in D0 on return (sign-extended to 32 bits)
- 32-bit values in D0
- Pointer values in A0
- Structs > 4 bytes: caller allocates, passes pointer in a hidden first parameter

## `pascal` calling convention (Mac Toolbox)

Most Toolbox functions were originally Pascal routines, so they use a different ABI:

- Parameters pushed **left-to-right** on the stack
- **Callee** cleans the stack (`stdcall`-like)
- Same register usage as C for return values

**Critical:** The `#define pascal` in our `Types.h` makes `pascal` a no-op,
which means every function declared `pascal` in the original headers will be called
with **C convention** (right-to-left push, caller cleans). The `libretro68.a` stubs
compensate for this — they re-order the arguments before making the actual trap call.

Verify each stub handles argument reordering if you add new Toolbox functions.

## Stack alignment

The 68000 does not require strict stack alignment, but the System software assumes
word (2-byte) alignment for stack-allocated objects. Always `sizeof`-align stack
allocations; never store a byte-aligned value at an odd address.

## A5 world

Classic Mac apps use A5 as a base register to access:
- Application globals (allocated by the OS loader)
- QuickDraw globals
- Jump table

`crt0.o` (from Retro68) sets up A5 before calling `main()`. Our PCC-compiled code
must never clobber A5. This is normally safe because:
1. The C ABI designates A5 as callee-saved
2. PCC should not generate code that writes to A5

However, if you see crashes on the first global variable access, check the disassembly
for any unexpected `movea` to A5.

## Return values for common Mac types

| Return type | Where |
|-------------|-------|
| Boolean (uint8_t) | D0 (low byte) |
| Integer (int16_t) | D0 (low 16 bits) |
| LongInt (int32_t) | D0 |
| OSErr (int16_t) | D0 |
| Ptr / Handle | A0 |
| void * | A0 |
| WindowPtr | A0 |

## `pascal` functions that RETURN via the stack

Some Pascal functions return large structs on the stack — caller must allocate space
and pass a pointer as a hidden parameter. In classic Mac practice, this is rare in
the Toolbox (most return pointers or error codes). If you encounter a Toolbox function
that seems to return a struct, check Inside Macintosh for its actual calling convention.

## 68000 instruction set restrictions

The classic Macintosh (all models up to Mac IIsi) uses a 68000, 68010, 68020, or 68030.
The original Mac 128k, 512k, and Plus use **68000 only**.

The emulator in classic-vibe-mac targets a 68000 CPU. Do not generate:
- `MULS.L` / `MULU.L` — 68020+ only
- `DIVS.L` / `DIVU.L` — 68020+ only
- `BFXXX` (bit field instructions) — 68020+ only
- `PACK` / `UNPK` — 68020+ only

PCC's m68k backend should default to 68000 instructions. Verify with:
```bash
objdump -d build/hello.elf | grep -E "muls.l|mulu.l|divs.l|divu.l|bfextu|bfexts"
```
No matches = safe.

## Endianness

The 68000 is **big-endian**. All multi-byte values (int16, int32, pointers) are stored
most-significant byte first.

When writing the MacBinary header in JavaScript (little-endian host):
```js
view.setInt32(83, dataForkLength, false);  // false = big-endian
```
