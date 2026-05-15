#!/usr/bin/env node
/**
 * Phase 2.3d — full in-browser pipeline end-to-end test.
 *
 * Pipes hello_toolbox.c through all four wasm tools and produces a
 * single-fork MacBinary II APPL in MEMFS. The four tools are:
 *
 *   cc1.wasm     :  .c -> .s    (already byte-identical to native)
 *   as.wasm      :  .s -> .o    (already byte-identical to native)
 *   ld.wasm      :  .o + libs + ldscript -> .gdb (m68k ELF executable)
 *   Elf2Mac.wasm :  .gdb -> .bin (MacBinary II APPL — single-fork)
 *
 * Done criterion: the output .bin passes
 * `spike-pcc/inspect_macbinary.py` (APPL + CODE 0 + CODE 1+ + DATA +
 * RELA, below_a5 > 0). End-to-end byte-equivalence to the Phase 2.0
 * reference `hello-toolbox-retro68.bin` is **not** a goal here — the
 * reference is built with Retro68's CMake `add_application` flow
 * which emits extra resources (SIZE from Rez, more CODE segments from
 * the dynamically-generated multi-seg ld script) that this pipeline
 * doesn't replicate yet. Boot-level equivalence is the next step;
 * see LEARNINGS.md "Phase 2.3d — first end-to-end .bin" for the gap
 * analysis and what would close it.
 *
 * Run:
 *   node spike/wasm-cc1/test/full-pipeline.mjs
 */
import { readFileSync, writeFileSync, mkdirSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT      = resolve(__dirname, "../../..");
const CC1_MJS   = resolve(__dirname, "../build/stage2/gcc/cc1.mjs");
const AS_MJS    = resolve(ROOT, "spike/wasm-binutils/build/stage2/gas/as.mjs");
const LD_MJS    = resolve(ROOT, "spike/wasm-binutils/build/stage2/ld/ld.mjs");
const E2M_MJS   = resolve(ROOT, "spike/wasm-elf2mac/build/stage2/Elf2Mac/Elf2Mac.mjs");
const SYSROOT   = resolve(__dirname, "../build/sysroot");
const SOURCE    = resolve(ROOT, "spike/hello_toolbox.c");
const OUT_DIR   = resolve(__dirname, "../build/test/pipeline");
const OUT_BIN   = resolve(OUT_DIR, "hello_toolbox.bin");

mkdirSync(OUT_DIR, { recursive: true });

const sourceText = readFileSync(SOURCE, "utf8");
console.log(`[pipeline] source: ${SOURCE} (${sourceText.length} bytes)`);
console.log(`[pipeline] sysroot: ${SYSROOT}`);

/* Helper: load an Emscripten ES module factory, build a Module with
 * NODEFS-mountable sysroot at /sysroot, expose callMain that swallows
 * ExitStatus exceptions and returns the exit code instead of throwing. */
async function loadTool(mjsPath, name) {
  const mod = await import(mjsPath);
  const stdout = [], stderr = [];
  const Module = await mod.default({
    noInitialRun: true,
    print:    (s) => stdout.push(s),
    printErr: (s) => stderr.push(s),
  });
  // Mount the host sysroot at /sysroot inside this tool's MEMFS so
  // -isystem /sysroot/include and -L /sysroot/lib resolve.
  try {
    Module.FS.mkdir("/sysroot");
    Module.FS.mount(Module.NODEFS, { root: SYSROOT }, "/sysroot");
  } catch (e) {
    // /sysroot may already exist on re-mount; ignore.
  }
  // Shared /tmp lives in MEMFS; each tool gets its own (so output
  // files written by one tool need to be transferred to the next).
  return { Module, stdout, stderr, name };
}

function runMain(tool, argv) {
  console.log(`[${tool.name}] callMain(${JSON.stringify(argv)})`);
  let rc;
  try { rc = tool.Module.callMain(argv); }
  catch (e) {
    if (e.name === "ExitStatus") rc = e.status;
    else throw e;
  }
  if (tool.stderr.length) {
    console.log(`[${tool.name}] stderr:`);
    tool.stderr.slice(0, 20).forEach((l) => console.log(`  | ${l}`));
    tool.stderr.length = 0;
  }
  console.log(`[${tool.name}] exit ${rc}`);
  return rc;
}

function transfer(srcTool, srcPath, dstTool, dstPath) {
  const bytes = srcTool.Module.FS.readFile(srcPath);
  // Ensure parent dirs exist in destination MEMFS.
  const parts = dstPath.split("/").filter(Boolean).slice(0, -1);
  let p = "";
  for (const part of parts) {
    p += "/" + part;
    try { dstTool.Module.FS.mkdir(p); } catch {}
  }
  dstTool.Module.FS.writeFile(dstPath, bytes);
  console.log(`[transfer] ${srcTool.name}:${srcPath} (${bytes.length} bytes) → ${dstTool.name}:${dstPath}`);
}

// ── 1. cc1.wasm: .c → .s ─────────────────────────────────────────
const cc1 = await loadTool(CC1_MJS, "cc1");
cc1.Module.FS.writeFile("/tmp/in.c", sourceText);
let rc = runMain(cc1, [
  "-quiet",
  "-isystem", "/sysroot/gcc-include",
  "-isystem", "/sysroot/include",
  "-mcpu=68020",
  "/tmp/in.c",
  "-o", "/tmp/out.s",
]);
if (rc !== 0) { console.error("[pipeline] cc1 failed"); process.exit(rc); }
const sBytes = cc1.Module.FS.readFile("/tmp/out.s");
console.log(`[pipeline] /tmp/out.s: ${sBytes.length} bytes`);

// ── 2. as.wasm: .s → .o ──────────────────────────────────────────
const as = await loadTool(AS_MJS, "as");
as.Module.FS.writeFile("/tmp/in.s", sBytes);
rc = runMain(as, ["-march=68020", "/tmp/in.s", "-o", "/tmp/out.o"]);
if (rc !== 0) { console.error("[pipeline] as failed"); process.exit(rc); }
const oBytes = as.Module.FS.readFile("/tmp/out.o");
console.log(`[pipeline] /tmp/out.o: ${oBytes.length} bytes`);

// ── 3. ld.wasm: .o + libs + ldscript → ELF executable ───────────
const ld = await loadTool(LD_MJS, "ld");
ld.Module.FS.writeFile("/tmp/in.o", oBytes);
// Link order matters (cv-mac eyes-on test 2026-05-15, see LEARNINGS
// "Phase 2.3d — _start fallback was pre-satisfying libretrocrt's
// real entry point"):
//
//   1. `start.c.obj` *first*, before any .a — it defines `_start` and
//      satisfies the ld script's ENTRY before the script's
//      `PROVIDE(_start = .)` fallback (a bare RTS) can preempt it.
//      Without this, archive search never pulls libretrocrt's real
//      start.c, the trampoline jumps to the RTS fallback, and `main`
//      never runs.
//
//   2. All archives wrapped in `--start-group … --end-group` so
//      cross-archive references (libretrocrt → libc → libretrocrt,
//      libretrocrt → libgcc, etc.) resolve regardless of order.
//
//   3. `libgcc.a` included — softfloat / softdiv helpers
//      (`__udivsi3`, `__mulsi3`, …) that libretrocrt's syscalls.c
//      transitively needs.
rc = runMain(ld, [
  // Patched script — same content as retro68-flat.ld minus the
  // `PROVIDE(_start = .)` line. The PROVIDE fallback pre-empts
  // libretrocrt's real `_start` and routes the entry trampoline to a
  // bare RTS, so `main` never runs. See LEARNINGS "Phase 2.3d —
  // PROVIDE(_start) pre-empts libretrocrt".
  "-T", "/sysroot/ld/retro68-flat-cv.ld",
  "-L", "/sysroot/lib",
  "--no-warn-rwx-segments",
  "-o", "/tmp/out.gdb",
  "/sysroot/lib/start.c.obj",
  "/tmp/in.o",
  "--start-group",
  "/sysroot/lib/libretrocrt.a",
  "/sysroot/lib/libInterface.a",
  "/sysroot/lib/libc.a",
  "/sysroot/lib/libm.a",
  "/sysroot/lib/libgcc.a",
  "--end-group",
]);
if (rc !== 0) { console.error("[pipeline] ld failed"); process.exit(rc); }
const elfBytes = ld.Module.FS.readFile("/tmp/out.gdb");
console.log(`[pipeline] /tmp/out.gdb (ELF executable): ${elfBytes.length} bytes`);

// ── 4. Elf2Mac.wasm: ELF → MacBinary II ─────────────────────────
//
// Output-path quirk (caught 2026-05-15, Phase 2.3d). Elf2Mac calls
// `ResourceFile::write(path, autodetect)` which `assign(path)`s a
// format based on `path.extension()`:
//
//   .bin → Format::macbin       (single-fork MacBinary II APPL — what we want)
//   .as  → Format::applesingle
//   .dsk → Format::diskimage
//   <other / no ext> → Format::basilisk on non-__APPLE__ hosts
//                       (split fork: data + .rsrc/<name> + .finf/<name>)
//
// We're a node host (not __APPLE__ in Elf2Mac's preprocessor sense),
// so anything without `.bin` falls through to basilisk — the failure
// mode this pipeline used to hit when calling with `-o /tmp/out`.
//
// Also note: Elf2Mac reads the input ELF from `outputFile + ".gdb"`
// (legacy hangover from when it spawned the real ld and named its
// output `.gdb`). Convert-only mode preserves that convention, so we
// stage the linked ELF at `/tmp/out.bin.gdb` and ask Elf2Mac to emit
// `/tmp/out.bin`.
const e2m = await loadTool(E2M_MJS, "Elf2Mac");
e2m.Module.FS.writeFile("/tmp/out.bin.gdb", elfBytes);
rc = runMain(e2m, [
  "--elf2mac",
  // Default multi-segment mode (no --mac-flat / --mac-single).
  // --mac-flat writes a single CODE blob without the MacBinary wrapper.
  // --mac-single calls SingleSegmentApp() which produces a structurally
  //  invalid binary (below_a5=0) on a libretrocrt-linked ELF — verified
  //  via spike-pcc/inspect_macbinary.py.
  "-o", "/tmp/out.bin",
]);
if (rc !== 0) { console.error("[pipeline] Elf2Mac failed"); process.exit(rc); }

// Diagnostic: list what Elf2Mac actually wrote.
function walk(fs, base, depth) {
  const indent = "  ".repeat(depth);
  const entries = fs.readdir(base).filter((n) => n !== "." && n !== "..");
  for (const name of entries) {
    const path = base === "/" ? "/" + name : base + "/" + name;
    try {
      const stat = fs.stat(path);
      const isDir = (stat.mode & 0o170000) === 0o040000;
      console.log(`${indent}${name}${isDir ? "/" : ""}  ${stat.size} bytes`);
      if (isDir && depth < 2) walk(fs, path, depth + 1);
    } catch {}
  }
}
console.log(`[pipeline] /tmp tree after Elf2Mac:`);
walk(e2m.Module.FS, "/tmp", 0);

let binBytes;
try {
  binBytes = e2m.Module.FS.readFile("/tmp/out.bin");
} catch (err) {
  console.error("[pipeline] /tmp/out.bin not produced:", err.message);
  process.exit(1);
}
writeFileSync(OUT_BIN, binBytes);
console.log(`[pipeline] PASS: wrote ${OUT_BIN} (${binBytes.length} bytes)`);

// ── 5. Structural validation ─────────────────────────────────────
//
// `spike-pcc/inspect_macbinary.py` is the Phase 1 structural inspector
// — it understands MacBinary II layout, the resource map, and the
// CODE 0 jump-table fields (above_a5 / below_a5 / jt_size /
// jt_entries) that the classic Mac Process Manager actually reads on
// launch. A PASS here means the artefact is *shaped* like a bootable
// APPL — it doesn't prove the runtime won't trap-3 on entry, but it
// rules out the structural failures the inspector knows about.
//
// We invoke the inspector via the host's python3 rather than wiring
// up a JS port — the inspector is a few hundred LOC and lives in
// spike-pcc/ for reasons that predate Phase 2 (it's the same
// inspector PR #14's CI uses). Re-running it from JS gives us the
// canonical answer with one source of truth.
try {
  const { spawnSync } = await import("node:child_process");
  const r = spawnSync(
    "python3",
    [resolve(ROOT, "spike-pcc/inspect_macbinary.py"), OUT_BIN],
    { encoding: "utf8" },
  );
  console.log(`[pipeline] inspect_macbinary.py:`);
  for (const l of (r.stdout || "").trim().split("\n")) console.log(`  ${l}`);
  if (r.stderr) console.log(`  stderr: ${r.stderr.trim()}`);
  if (r.status !== 0) {
    console.error(`[pipeline] FAIL: inspect_macbinary.py exit ${r.status}`);
    process.exit(r.status ?? 1);
  }
} catch (e) {
  console.warn(`[pipeline] WARN: could not run inspect_macbinary.py: ${e.message}`);
}
