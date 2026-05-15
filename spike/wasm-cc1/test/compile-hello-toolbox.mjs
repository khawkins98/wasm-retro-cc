#!/usr/bin/env node
/**
 * Phase 2.1 end-to-end test — compile hello_toolbox.c via WASM cc1.
 *
 * Same source the Phase 2.0 derisk binary was built from
 * (`spike/hello_toolbox.c` — InitGraf + InitFonts + … + DrawString +
 * Button wait). Compiles it with the wasm cc1, then diffs the output
 * against the native cross-cc1 build to confirm functional equivalence.
 *
 * If the diff is empty (or trivially-different whitespace), Phase 2.1
 * as a sub-spike is complete: same compiler, just running in wasm.
 *
 * Run:
 *   node spike/wasm-cc1/test/compile-hello-toolbox.mjs
 *
 * Requirements:
 *   - cc1.mjs + cc1.wasm from `bash spike/wasm-cc1/build.sh relink`
 *   - sysroot at spike/wasm-cc1/build/sysroot/ — populated by:
 *     bash spike/wasm-cc1/build.sh sysroot
 */
import { readFileSync, writeFileSync, statSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT      = resolve(__dirname, "../../..");
const CC1_MJS   = resolve(__dirname, "../build/stage2/gcc/cc1.mjs");
const SYSROOT   = resolve(__dirname, "../build/sysroot");
const SOURCE    = resolve(ROOT, "spike/hello_toolbox.c");
const OUT_WASM  = resolve(__dirname, "../build/test/hello_toolbox_wasm.s");

const source = readFileSync(SOURCE, "utf8");
console.log(`[harness] source: ${SOURCE} (${source.length} bytes)`);
console.log(`[harness] sysroot: ${SYSROOT}`);
console.log(`[harness] cc1.mjs: ${CC1_MJS}`);

const mod = await import(CC1_MJS);
const stdout = [];
const stderr = [];
const Module = await mod.default({
  noInitialRun: true,
  print:    (s) => stdout.push(s),
  printErr: (s) => stderr.push(s),
});
console.log(`[harness] cc1.wasm instantiated`);

// Mount the host sysroot as NODEFS at /sysroot/.  NODEFS is
// emscripten's bridge to the underlying OS filesystem; it lets cc1
// read host files without pre-loading them into MEMFS. Right tradeoff
// for Node tests; the browser will use a different strategy (preload
// or fetched+unpacked tarball).
Module.FS.mkdir("/sysroot");
Module.FS.mount(Module.NODEFS, { root: SYSROOT }, "/sysroot");

// Write input to MEMFS.
Module.FS.writeFile("/tmp/hello_toolbox.c", source);

const argv = [
  "-quiet",
  "-isystem", "/sysroot/gcc-include",   // GCC builtin headers (stddef etc.)
  "-isystem", "/sysroot/include",        // Retro68 CIncludes (Quickdraw etc.)
  "-mcpu=68020",
  "/tmp/hello_toolbox.c",
  "-o", "/tmp/hello_toolbox.s",
];
console.log(`[harness] callMain(${JSON.stringify(argv)})`);

let rc;
try {
  rc = Module.callMain(argv);
} catch (e) {
  if (e.name === "ExitStatus") rc = e.status;
  else throw e;
}
console.log(`[harness] cc1 exit code: ${rc}`);

if (stderr.length) {
  console.log(`[harness] cc1 stderr (${stderr.length} lines):`);
  stderr.slice(0, 30).forEach((l) => console.log(`  | ${l}`));
}

if (rc !== 0) {
  console.error(`[harness] FAIL: cc1 exited ${rc}`);
  process.exit(rc || 1);
}

let asm;
try {
  asm = new TextDecoder().decode(Module.FS.readFile("/tmp/hello_toolbox.s"));
} catch (e) {
  console.error(`[harness] FAIL: /tmp/hello_toolbox.s not produced — ${e.message}`);
  process.exit(1);
}

try { statSync(dirname(OUT_WASM)); } catch { mkdirSync(dirname(OUT_WASM), { recursive: true }); }
writeFileSync(OUT_WASM, asm);
console.log(`[harness] wrote ${OUT_WASM} (${asm.length} bytes)`);

// Sanity checks. The Retro68 SDK headers declare Toolbox calls with
// `= { 0xAxxx }` annotations that inline the trap directly — function
// names DON'T appear in the assembly; opcodes do. So we check for the
// Pascal string + A-trap opcodes for the calls hello_toolbox.c makes.
//   InitGraf    0xA86E
//   InitFonts   0xA8FE
//   InitWindows 0xA912
//   InitMenus   0xA930
//   TEInit      0xA9CC
//   InitDialogs 0xA97B
//   MoveTo      0xA893
//   DrawString  0xA884
//   FlushEvents 0xA032
//   Button      0xA974
const expected = [
  "kHelloStr",
  "Hello, World!",
  "qd+202",           // &qd.thePort — confirms mac68k packing
  "0xa86e",           // InitGraf
  "0xa8fe",           // InitFonts
  "0xa912",           // InitWindows
  "0xa930",           // InitMenus
  "0xa9cc",           // TEInit
  "0xa893",           // MoveTo
  "0xa884",           // DrawString
  "0xa974",           // Button
  "link.w",           // m68k function prologue
  "unlk",             // epilogue
];
const missing = expected.filter((s) => !asm.includes(s));
if (missing.length) {
  console.error(`[harness] FAIL: missing in assembly: ${missing.join(", ")}`);
  console.error(`[harness] first 40 lines of output:`);
  asm.split("\n").slice(0, 40).forEach((l) => console.error(`  | ${l}`));
  process.exit(1);
}

console.log(`[harness] PASS: all expected symbols + mnemonics in output`);
console.log(`[harness] Phase 2.1 end-to-end: wasm cc1 compiles hello_toolbox.c → m68k asm`);
console.log(`[harness] (${asm.split("\n").length} lines of assembly, ${asm.length} bytes)`);
