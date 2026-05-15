#!/usr/bin/env node
/**
 * Phase 2.3d — full in-browser pipeline end-to-end test.
 *
 * Pipes hello_toolbox.c through all four wasm tools and produces a
 * .bin in MEMFS. The four tools are:
 *
 *   cc1.wasm     :  .c -> .s    (already byte-identical to native)
 *   as.wasm      :  .s -> .o    (already byte-identical to native)
 *   ld.wasm      :  .o + libs + ldscript -> .gdb (m68k ELF executable)
 *   Elf2Mac.wasm :  .gdb -> .bin (MacBinary II APPL)
 *
 * Done criterion: the output .bin passes inspect_macbinary.py and
 * diffs ~equivalent to the Phase 2.0 reference hello-toolbox-retro68.bin.
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
rc = runMain(ld, [
  "-T", "/sysroot/ld/retro68-flat.ld",
  "-L", "/sysroot/lib",
  "--no-warn-rwx-segments",
  "-o", "/tmp/out.gdb",
  "/tmp/in.o",
  // Standard Retro68 link order — same as `add_application` produces.
  "/sysroot/lib/libretrocrt.a",
  "/sysroot/lib/libInterface.a",
  "/sysroot/lib/libc.a",
]);
if (rc !== 0) { console.error("[pipeline] ld failed"); process.exit(rc); }
const elfBytes = ld.Module.FS.readFile("/tmp/out.gdb");
console.log(`[pipeline] /tmp/out.gdb (ELF executable): ${elfBytes.length} bytes`);

// ── 4. Elf2Mac.wasm: ELF → MacBinary II ─────────────────────────
const e2m = await loadTool(E2M_MJS, "Elf2Mac");
e2m.Module.FS.writeFile("/tmp/out.gdb", elfBytes);
// Elf2Mac in convert-only mode (RealLD stubbed). It expects an ELF at
// outputFile + ".gdb" — we pass "-o /tmp/out" so it looks for
// /tmp/out.gdb (which we just wrote) and emits /tmp/out.bin.
rc = runMain(e2m, [
  "--elf2mac",
  // Default multi-segment mode (no --mac-flat). Produces outputFile.bin
  // — the MacBinary II APPL Elf2Mac normally emits when invoked by the
  // Retro68 ld driver. Flat mode writes a single CODE blob without the
  // MacBinary wrapper, which is not what we want.
  "-o", "/tmp/out",
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
