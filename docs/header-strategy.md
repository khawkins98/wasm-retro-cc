# Shim Header Strategy

This document explains the design of the shim headers in `src/include/` and the
decisions behind them.

## The Problem

Retro68's official SDK headers declare Toolbox functions using a GCC m68k extension:

```c
pascal WindowPtr NewWindow(...) = { 0xA913 };
```

The `= { 0xA913 }` is an **A-trap specifier** — it tells GCC to emit an `A-LINE`
exception instruction (e.g., `dc.w 0xA913`) instead of a `jsr`. This is a GCC
m68k-specific language extension. No other C compiler supports it.

PCC (our WASM compiler target) cannot parse this syntax and will error out.

## The Solution: Option A (chosen)

**Pre-compile the Toolbox stubs with Retro68 GCC in CI. Bundle them as `libtoolbox-stubs.a`.
Replace the A-trap headers with plain `extern` declarations PCC can parse.**

> **Phase 0 finding:** `libInterface.a` from Retro68 contains only ~30 uppercase
> OS-level stubs (GESTALT, DELAY, etc.). It does **not** contain QuickDraw, Window
> Manager, Event Manager, or other high-level Toolbox functions. We therefore build
> `libtoolbox-stubs.a` — hand-assembled stubs that accept C-cdecl calls and execute
> the appropriate A-trap. `libtoolbox-stubs.a` is therefore the **sole provider**
> of those Toolbox symbols at link time, not a shadow of Interface's versions.
> Interface still resolves the OS-level traps that `libretrocrt`'s `syscalls.c`
> needs (FSWRITE, FSREAD, etc.).

```c
/* Shim header — no A-trap syntax */
extern WindowPtr NewWindow(void *wStorage, const Rect *boundsRect,
                           const unsigned char *title, Boolean visible,
                           int16_t theProc, WindowPtr behind,
                           Boolean goAwayFlag, int32_t refCon);
```

When PCC compiles user code:
1. It includes our shim headers (plain C90 `extern` declarations)
2. It generates a call to `_NewWindow` (undefined at this point)
3. The linker links against `libtoolbox-stubs.a`
4. `libtoolbox-stubs.a` contains the hand-assembled stub: accept C-cdecl args, execute `dc.w 0xA913`
5. All undefined symbols are resolved

## Why not Option B (parse A-traps in PCC)?

Option B would involve patching PCC to understand `= { 0xHEX }` syntax.

Rejected because:
- It's a significant compiler modification (~500 LOC estimate)
- It would need to be maintained as a fork of PCC
- Option A requires no PCC modification at all
- The stubs are a one-time CI build; they don't change often

## `pascal` calling convention

The official headers mark most Toolbox functions as `pascal`, which means
left-to-right parameter push + callee stack cleanup.

Our shim headers use `#define pascal` (from `Types.h`) to make `pascal` a no-op.
This means PCC will call these functions with C convention (right-to-left push,
caller cleanup).

**This is intentional.** The `libtoolbox-stubs.a` stubs accept
C-convention calls and execute the proper Toolbox A-trap. Each stub must be written
to accept arguments in right-to-left (C cdecl) order and invoke the trap directly
without re-pushing arguments (the Mac ROM handles the call internally).

Verify each stub for new functions you add:

```bash
m68k-linux-gnu-objdump -d src/stubs/libtoolbox-stubs.a | grep -A 20 "_NewWindow"
```

## Known functions requiring special handling

| Function | Issue | Workaround |
|----------|-------|------------|
| `MoveTo` | Toolbox trap expects `v`/`h` packed in D0 in Pascal order | Stub swaps words using `%d1` temp before trap |
| Memory-to-memory stack swaps | `m68k-linux-gnu-as` may reject memory-to-memory forms in MIT mode | Use register intermediates (`%d0`/`%d1`) |
| Assembly syntax | Ubuntu `m68k-linux-gnu-as` defaults to MIT syntax, not Motorola | Use `%d0`, `%a0@`, `%sp@(4)`, `movl`/`movw`, etc. |

Add to this table as additional trap bridges are implemented.

## QuickDraw globals ABI note

`qd` must match Retro68's `libretrocrt.a` startup layout closely enough that `InitGraf(&qd.thePort)`
passes the address of the `thePort` field at the expected byte offset.

```c
typedef struct QDGlobals {
    char    privates[76];
    int32_t randSeed;
    BitMap  screenBits;
    Cursor  arrow;
    Pattern dkGray;
    Pattern ltGray;
    Pattern gray;
    Pattern black;
    Pattern white;
    GrafPtr thePort;   /* byte offset 202 in the m68k layout */
} QDGlobals;
```

This offset comment is part of the ABI contract validated by the current spike.
Also note that `InitDialogs(0L)` is valid C90/C99: the integer constant zero
converts to a null `ResumeProcPtr`.

## Header tiers

**Tier 1** (required for `spike/hello.c`):
- `Types.h` — fundamental types
- `Quickdraw.h` — graphics primitives, including the `QDGlobals` shim layout needed for `qd.thePort`
- `Windows.h` — window management
- `Events.h` — event loop
- `Fonts.h` — font initialisation
- `Memory.h` — heap management

**Tier 2** (needed for more complex apps):

`spike/hello.c` already needs part of the standard Macintosh startup sequence from
Tier 2: `InitMenus()`, `TEInit()`, and `InitDialogs(0L)`.

- `Menus.h` — menu bar and pull-down menus (`InitMenus` for standard app startup)
- `Dialogs.h` — dialog boxes and alerts (`InitDialogs(0L)` passes a null resume procedure)
- `Files.h` — File Manager (FSSpec, HOpen, etc.)
- `Resources.h` — Resource Manager
- `TextEdit.h` — editable text fields (`TEInit` for standard app startup)

**Tier 3** (advanced):
- `Sound.h` — Sound Manager
- `Serial.h` — serial ports
- `AppleTalk.h` — networking

## Adding a new Tier 1 or Tier 2 function

1. Look up the function in *Inside Macintosh* (Vol 1–5) for the authoritative
   parameter list and types
2. Verify the symbol will be provided by `libtoolbox-stubs.a`:
   ```bash
   nm src/stubs/libtoolbox-stubs.a | grep FunctionName
   ```
3. Add the `extern` declaration to the appropriate shim header, using plain C types
4. Write a test in `spike/` that calls the function and links successfully
5. Run `spike/run-spike.sh compile` to confirm zero undefined symbols
6. Update `LEARNINGS.md` if you discover any calling convention quirks
