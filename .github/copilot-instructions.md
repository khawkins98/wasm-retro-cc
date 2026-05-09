# wasm-retro-cc — Copilot Instructions

**Read `README.md` (PRD) and `LEARNINGS.md` before writing any code. Both are short and
contain decisions that took significant research to reach. Relitigating them wastes time.**

---

## Project status

**Phase 0 — Feasibility spike.** No full WASM build exists yet. The primary goal is to
confirm that PCC's m68k output is ABI-compatible with Retro68's pre-compiled stubs, and
that a linked ELF binary can be produced without undefined symbols or 68020+ instructions.

---

## Commits

Use **Conventional Commits**: `feat:`, `fix:`, `docs:`, `chore:`, `test:`, `refactor:`

Scope is optional but encouraged for clarity: `feat(headers):`, `fix(abi):`, `chore(ci):`.

---

## Multi-agent workflow

Spin up relevant custom agents **in parallel** for independent workstreams (e.g. shim
headers and spike validation can run simultaneously). Report progress at **phase
boundaries**, not sub-task level. Route tasks to the appropriate agent per the table
below rather than doing domain-specialist work inline.

---

## Commands

```bash
# Phase 0 spike (native PCC, no WASM)
bash spike/run-spike.sh setup      # pull Retro68 Docker image, extract stubs/headers
bash spike/run-spike.sh build-pcc  # build PCC for m68k target
bash spike/run-spike.sh compile    # compile spike/hello.c → spike/build/hello.elf
bash spike/run-spike.sh compare    # diff against Retro68 reference output

# Validation (run after any change to spike/ or src/include/)
m68k-linux-gnu-nm spike/build/hello.elf | grep " U "
# → zero output = pass (no undefined symbols)

m68k-linux-gnu-objdump -d spike/build/hello.elf \
  | grep -Ei "muls\.l|mulu\.l|divs\.l|divu\.l|bfextu|bfexts"
# → zero output = pass (no 68020+ instructions)

# Phase 1+ (WASM build — requires Emscripten SDK)
npm run build   # emcmake cmake -B build … && emmake cmake --build build
npm test        # node test/run.mjs
npm run clean
```

---

## Architecture

The core insight that makes this feasible:

> User-written Classic Mac C code never contains A-trap syntax (`= { 0xA913 }`). That
> syntax lives only in the SDK headers. So we pre-compile the entire Retro68 SDK into a
> static library using real Retro68 GCC in CI, and ship PCC to the browser to compile only
> user code, linking against those pre-built stubs.

### Pipeline (inside the WASM module)

```
user source.c
  └─▶ [PCC m68k frontend + codegen] → .s assembly (MEMFS)
        └─▶ [GNU as m68k] → .o (MEMFS)
              └─▶ [GNU ld + libretro68.a + libc.a] → ELF binary (MEMFS)
                    └─▶ [MacBinary II wrapper] → .bin → returned to browser
```

### Components

| Component | Location | Notes |
|---|---|---|
| PCC (compiler) | `src/compiler/` (Phase 1) | Compiled to WASM via Emscripten; **no fork/exec** — link pipeline stages directly, not through PCC's driver `cc.c` |
| Shim headers | `src/include/` | Plain C90 `extern` declarations; no A-trap syntax; `pascal` is a no-op |
| Pre-compiled stubs | `src/stubs/` (Phase 1) | `libretro68.a`, `crt0.o` from Retro68 GCC; embedded via Emscripten `--preload-file` |
| MacBinary writer | `src/macbinary/` (Phase 1) | Wraps linker ELF output in MacBinary II header |
| JS API wrapper | `src/js/retro-cc.ts` | Same lazy-load pattern as `wasm-rez` in classic-vibe-mac |
| Phase 0 spike | `spike/` | Native (non-WASM) validation only |

### Relationship to classic-vibe-mac

`wasm-retro-cc` is consumed by `classic-vibe-mac` identically to how it already
consumes `wasm-rez`: lazy-loaded via `<script>` injection (only when the user clicks
**Compile & Run**), Emscripten MEMFS for file I/O, no network calls during compilation.

The JS API shape is fixed and must match:

```ts
const result = await cc.compile({
  files: [{ name: "main.c", content: "..." }],
  appName: "HelloMac",
});
// result.ok → true/false
// result.macBinary → Uint8Array (MacBinary II)
// result.diagnostics → { file, line, column, message, severity }[]
```

---

## Key conventions

### Shim headers (`src/include/`)

- Plain C90 `extern` declarations only — no GCC extensions, no `= { 0xAxx }` syntax
- `#define pascal` in `Types.h` makes `pascal` a no-op; all Toolbox calls use C convention
  (right-to-left push, caller cleans). The `libretro68.a` stubs handle argument reordering.
- When adding a Toolbox function, verify the stub actually reorders arguments:
  ```bash
  m68k-elf-objdump -d spike/retro68-stubs/libretro68.a | grep -A 20 "_FunctionName"
  ```
  If it doesn't, document the workaround in `docs/header-strategy.md`.
- Every new header entry gets a corresponding note in `docs/header-strategy.md`.
- Tier 1 headers (needed for any windowed app): `Types.h`, `Quickdraw.h`, `Windows.h`,
  `Events.h`, `Fonts.h`, `Memory.h`. Implement these before any Tier 2 work.

### m68k ABI constraints

- **68000 only** — the classic-vibe-mac emulator targets 68000. Do not generate
  `MULS.L`, `MULU.L`, `DIVS.L`, `DIVU.L`, or bit-field instructions.
- **A5 is sacred** — it holds the Application globals pointer. PCC must never write to A5.
  If you see crashes on the first global access, inspect the disassembly for `movea` to A5.
- Return values: 16/32-bit integers in D0; pointers in A0; `Boolean` (uint8_t) in low byte of D0.
- MacBinary II header fields are **big-endian** — use `DataView.setInt32(offset, val, false)`.

### C code (compiler, linker, MacBinary writer)

- C99; no VLAs; no `alloca` (complicate Emscripten stack size budgeting)
- No dynamic allocation beyond what Mac Memory Manager provides in user code context

### JavaScript / TypeScript

- ES2022 modules; no CommonJS
- No dependencies in the JS wrapper beyond what Emscripten generates

### `LEARNINGS.md` is a living document

Update it when you discover something non-obvious — a calling convention quirk, an
Emscripten flag that matters, a stub that behaves unexpectedly. Check it first to avoid
re-discovering known issues.

### Settled decisions — do not re-open without strong evidence

| Decision | Rationale |
|---|---|
| PCC as compiler | Only small C compiler with an existing m68k backend; ~130K LOC; BSD licensed |
| Pre-compiled stubs (not A-trap parsing) | A-trap syntax is GCC-only; users never write it |
| `pascal` → no-op; stubs handle reordering | No PCC modification needed |
| Shim headers (Option A) before auto-processing (Option B) | Simpler; sufficient for Phase 1 |
| 68000 only | classic-vibe-mac emulator target |
| No C++ initially | Sample apps are all C; C++ adds significant complexity |
| Same JS API as wasm-rez | Proven pattern; consistent with classic-vibe-mac |

---

## Custom agents

Use these agents for specialised tasks by typing `/` followed by the agent name:

| Agent | When to use |
|---|---|
| `compiler-engineer` | PCC m68k codegen, Emscripten flags, pipeline linking, calling convention bugs |
| `header-engineer` | Writing or reviewing shim headers in `src/include/` |
| `wasm-build-engineer` | Emscripten CMake config, bundle size, WASM loading in the browser |
| `retro-mac-expert` | Mac Toolbox ABI, System 7 internals, HFS, MacBinary format, ROM traps |
| `integration-engineer` | classic-vibe-mac playground integration, HFS patcher, wasm-rez pattern |
| `phase-0-runner` | Executing and iterating the Phase 0 feasibility spike end-to-end |
| `rubber-duck` | Catching ABI mismatches, calling convention bugs, or WASM memory issues before they land |

---

## Reference documents

| Document | Contents |
|---|---|
| `README.md` | PRD: problem, goal, architecture, phased plan, JS API spec |
| `LEARNINGS.md` | Research findings: A-trap analysis, PCC evaluation, Emscripten notes, MacBinary format |
| `CONTRIBUTING.md` | Prereqs, workflow, settled vs open decisions, code conventions |
| `docs/abi.md` | Full m68k register/calling convention reference |
| `docs/header-strategy.md` | Shim header design, `pascal` no-op rationale, per-function quirks |
| `docs/architecture.md` | Component diagram and build phase status |
