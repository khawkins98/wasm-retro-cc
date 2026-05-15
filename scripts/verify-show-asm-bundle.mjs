#!/usr/bin/env node
/**
 * verify-show-asm-bundle.mjs — sanity-check the dist/show-asm/ bundle.
 *
 * Two scenarios exercised:
 *   1. Show Assembly path — load cc1.mjs, unpack `sysroot.bin` (headers
 *      only), compile a tiny C program → .s, assert m68k mnemonics present.
 *   2. Full pipeline path — load cc1 + as + ld + Elf2Mac, unpack both
 *      sysroot blobs (headers + libs), chain through MEMFS, assert
 *      Elf2Mac emits a `.bin` whose first bytes are a MacBinary II header
 *      and whose size matches the structural expectation.
 *
 * Both scenarios mirror what the cv-mac playground will do at runtime.
 * The structural inspector (spike-pcc/inspect_macbinary.py) is the
 * full-pipeline ground truth and is exercised separately by
 * spike/wasm-cc1/test/full-pipeline.mjs.
 *
 * Run:
 *   node scripts/verify-show-asm-bundle.mjs
 */
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DIST = resolve(__dirname, "../dist/show-asm");

const SOURCE = `
int square(int x) { return x * x; }
`;

const mod = await import(resolve(DIST, "cc1.mjs"));
const stdout = [];
const stderr = [];
const Module = await mod.default({
  noInitialRun: true,
  print: (s) => stdout.push(s),
  printErr: (s) => stderr.push(s),
});

// Unpack sysroot.bin into MEMFS at /sysroot — the way the cv-mac bridge will.
const blob = readFileSync(resolve(DIST, "sysroot.bin"));
const index = JSON.parse(readFileSync(resolve(DIST, "sysroot.index.json"), "utf8"));

Module.FS.mkdir("/sysroot");
const madeDirs = new Set(["/sysroot"]);
for (const entry of index) {
  const full = "/sysroot/" + entry.p;
  // mkdir -p every parent.
  const parts = full.split("/").filter(Boolean);
  let path = "";
  for (let i = 0; i < parts.length - 1; i++) {
    path += "/" + parts[i];
    if (!madeDirs.has(path)) {
      try {
        Module.FS.mkdir(path);
      } catch {}
      madeDirs.add(path);
    }
  }
  Module.FS.writeFile(full, blob.subarray(entry.o, entry.o + entry.l));
}
console.log(`[verify] mounted ${index.length} sysroot files`);

Module.FS.writeFile("/tmp/in.c", SOURCE);

let rc;
try {
  rc = Module.callMain([
    "-quiet",
    "-isystem", "/sysroot/gcc-include",
    "-isystem", "/sysroot/include",
    "-mcpu=68020",
    "/tmp/in.c",
    "-o", "/tmp/out.s",
  ]);
} catch (e) {
  rc = e?.name === "ExitStatus" ? e.status : NaN;
}

if (stderr.length) {
  console.log(`[verify] cc1 stderr:`);
  for (const l of stderr) console.log(`  | ${l}`);
}
if (rc !== 0) {
  console.error(`[verify] FAIL: cc1 exit ${rc}`);
  process.exit(1);
}

const asm = new TextDecoder().decode(Module.FS.readFile("/tmp/out.s"));
console.log(`[verify] out.s (${asm.length} bytes):`);
console.log(asm.split("\n").slice(0, 25).map((l) => "  " + l).join("\n"));

// Spot-check: m68k mul instruction should be in there somewhere for `x * x`.
if (!/muls\b|muls?\.\w/.test(asm)) {
  console.error(`[verify] FAIL: no m68k multiply instruction in output`);
  process.exit(1);
}
console.log(`[verify] Show Assembly path PASS`);

// ─────────────────────────────────────────────────────────────────────
// Scenario 2: full pipeline (cc1 + as + ld + Elf2Mac → MacBinary II).
//
// Uses the bundled hello_toolbox.c source. Mirrors cv-mac's
// `compileToBin` bridge will-be path: each tool gets its own Module
// with the relevant sysroot subset mounted. We re-use cc1 from above.
// ─────────────────────────────────────────────────────────────────────

const HELLO = await import("node:fs").then((fs) =>
  fs.readFileSync(resolve(__dirname, "../spike/hello_toolbox.c"), "utf8"),
);

// Helper: load a tool .mjs, return its Module. `mountLibs` controls
// whether we additionally unpack sysroot-libs.bin under /sysroot/.
async function loadTool(name, { mountHeaders, mountLibs }) {
  const mod = await import(resolve(DIST, name));
  const errs = [];
  const Module = await mod.default({
    noInitialRun: true,
    print: () => {},
    printErr: (s) => errs.push(s),
  });
  if (mountHeaders) {
    Module.FS.mkdir("/sysroot");
    const sysroot = readFileSync(resolve(DIST, "sysroot.bin"));
    const sIndex = JSON.parse(
      readFileSync(resolve(DIST, "sysroot.index.json"), "utf8"),
    );
    mountInto(Module, "/sysroot", sysroot, sIndex);
  }
  if (mountLibs) {
    if (!mountHeaders) Module.FS.mkdir("/sysroot"); // ld might want
    const libs = readFileSync(resolve(DIST, "sysroot-libs.bin"));
    const lIndex = JSON.parse(
      readFileSync(resolve(DIST, "sysroot-libs.index.json"), "utf8"),
    );
    mountInto(Module, "/sysroot", libs, lIndex);
  }
  return { Module, errs };
}

function mountInto(Module, root, blob, indexEntries) {
  const made = new Set([root]);
  for (const e of indexEntries) {
    const full = root + "/" + e.p;
    const parts = full.split("/").filter(Boolean);
    let p = "";
    for (let i = 0; i < parts.length - 1; i++) {
      p += "/" + parts[i];
      if (!made.has(p)) {
        try { Module.FS.mkdir(p); } catch {}
        made.add(p);
      }
    }
    Module.FS.writeFile(full, blob.subarray(e.o, e.o + e.l));
  }
}

function callMain(tool, argv) {
  try { return tool.Module.callMain(argv); }
  catch (e) {
    if (e && e.name === "ExitStatus") return e.status;
    throw e;
  } finally {
    if (tool.errs.length) {
      console.log(`  stderr:`);
      for (const s of tool.errs.splice(0)) console.log(`    | ${s}`);
    }
  }
}

console.log(`[verify] starting full-pipeline scenario…`);

// Stage 1: cc1. Fresh Module — Emscripten's argv handling makes
// re-invoking callMain on the same instance with different args
// unreliable (it remembers the initial `arguments_` slice from
// process.argv).
const cc1b = await loadTool("cc1.mjs", { mountHeaders: true, mountLibs: false });
cc1b.Module.FS.writeFile("/tmp/in.c", HELLO);
rc = callMain(cc1b, [
  "-quiet",
  "-isystem", "/sysroot/gcc-include",
  "-isystem", "/sysroot/include",
  "-mcpu=68020",
  "/tmp/in.c",
  "-o", "/tmp/out.s",
]);
if (rc !== 0) { console.error(`[verify] cc1 failed`); process.exit(rc); }
const sBytes = cc1b.Module.FS.readFile("/tmp/out.s");
console.log(`[verify]   cc1: ${sBytes.length} B .s`);

// Stage 2: as.
const as = await loadTool("as.mjs", { mountHeaders: false, mountLibs: false });
as.Module.FS.writeFile("/tmp/in.s", sBytes);
rc = callMain(as, ["-march=68020", "/tmp/in.s", "-o", "/tmp/out.o"]);
if (rc !== 0) { console.error(`[verify] as failed`); process.exit(rc); }
const oBytes = as.Module.FS.readFile("/tmp/out.o");
console.log(`[verify]   as:  ${oBytes.length} B .o`);

// Stage 3: ld.
// Link order matters — `start.c.obj` first (before any .a) so the
// real libretrocrt `_start` satisfies the ld script's ENTRY ahead of
// the script's `PROVIDE(_start = .)` fallback. Without that, the
// trampoline jumps to a bare RTS and `main` never runs. Plus libgcc.a
// + `--start-group` so soft-divide / soft-mul helpers and cross-archive
// references resolve. See LEARNINGS "Phase 2.3d — _start fallback".
const ld = await loadTool("ld.mjs", { mountHeaders: false, mountLibs: true });
ld.Module.FS.writeFile("/tmp/in.o", oBytes);
rc = callMain(ld, [
  "-T", "/sysroot/ld/retro68-flat.ld",
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
if (rc !== 0) { console.error(`[verify] ld failed`); process.exit(rc); }
const elfBytes = ld.Module.FS.readFile("/tmp/out.gdb");
console.log(`[verify]   ld:  ${elfBytes.length} B ELF`);

// Stage 4: Elf2Mac.
const e2m = await loadTool("Elf2Mac.mjs", { mountHeaders: false, mountLibs: false });
e2m.Module.FS.writeFile("/tmp/out.bin.gdb", elfBytes);
rc = callMain(e2m, ["--elf2mac", "-o", "/tmp/out.bin"]);
if (rc !== 0) { console.error(`[verify] Elf2Mac failed`); process.exit(rc); }
const binBytes = e2m.Module.FS.readFile("/tmp/out.bin");
console.log(`[verify]   Elf2Mac: ${binBytes.length} B .bin`);

// MacBinary II header check: byte 0 is the legacy version (0 in MacBin II),
// byte 1 is the filename length (1..63), bytes 65..68 are file type, 69..72
// creator. We just spot-check the structural shape — full validation lives
// in spike-pcc/inspect_macbinary.py.
if (binBytes.length < 128) {
  console.error(`[verify] FAIL: .bin too small (${binBytes.length} B)`);
  process.exit(1);
}
if (binBytes[0] !== 0) {
  console.error(`[verify] FAIL: MacBinary version byte != 0 (got ${binBytes[0]})`);
  process.exit(1);
}
const fnLen = binBytes[1];
if (fnLen < 1 || fnLen > 63) {
  console.error(`[verify] FAIL: filename length byte out of range (${fnLen})`);
  process.exit(1);
}
const type = String.fromCharCode(...binBytes.slice(65, 69));
const creator = String.fromCharCode(...binBytes.slice(69, 73));
if (type !== "APPL") {
  console.error(`[verify] FAIL: expected type APPL, got '${type}'`);
  process.exit(1);
}
console.log(`[verify]   .bin header: type=${type} creator=${creator} fnLen=${fnLen}`);
console.log(`[verify] full-pipeline path PASS`);
console.log(`[verify] ALL PASS`);
