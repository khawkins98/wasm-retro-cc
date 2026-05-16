#!/usr/bin/env node
/*
 * compile-c-cli.mjs — Node CLI for the wasm-retro-cc toolchain.
 *
 * A small slice of cv-mac #89: drive the in-browser pipeline from
 * Node so CI scripts (and humans without a browser handy) can build
 * a classic-Mac MacBinary II APPL from C source without spawning
 * a Playwright instance. Mirrors web-demo/compile.mjs's structure,
 * but reads wasm modules and the sysroot blob from the local
 * filesystem instead of fetching them.
 *
 * Usage:
 *   node scripts/compile-c-cli.mjs INPUT.c [-o OUTPUT.bin]
 *   node scripts/compile-c-cli.mjs --bundle dist/show-asm INPUT.c
 *
 * Defaults:
 *   - Bundle path: dist/show-asm/ (matches build-show-asm-bundle.mjs
 *     output). Override with --bundle.
 *   - Output filename: derived from the input (hello.c -> hello.bin)
 *     in the current working directory. Override with -o.
 *
 * Exit codes:
 *   0  success — bin written
 *   1  bad CLI args
 *   2  source unreadable / missing
 *   3+ stage failure (10 = cc1, 20 = as, 30 = ld, 40 = Elf2Mac)
 *
 * Out of scope (for this CLI):
 *   - Mixed C + .r builds. The wasm-rez pipeline is a separate tool;
 *     splicing the two forks together happens in cv-mac's
 *     spliceResourceFork (per #100 Phase B). A future cv-mac-side CLI
 *     could compose this script with wasm-rez to produce the spliced
 *     final binary.
 *   - Multi-file C. Single .c input only for now; the underlying wasm
 *     tools support N files (cv-mac's compileToBin does it for
 *     wasm-hello-multi) so adding it is mechanical when needed.
 *   - The execute-side harness (Musashi 68k VM). #89 still open for
 *     that part.
 */
import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  existsSync,
  statSync,
} from "node:fs";
import { dirname, resolve, basename, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, "..");

// ── CLI parsing ─────────────────────────────────────────────────────
const args = process.argv.slice(2);
function flag(name, def) {
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--" + name && args[i + 1] !== undefined) return args[i + 1];
    if (args[i] === "-" + name && args[i + 1] !== undefined) return args[i + 1];
  }
  return def;
}
function bool(name) {
  return args.includes("--" + name) || args.includes("-" + name);
}
if (bool("help") || bool("h")) {
  console.log(`Usage: node scripts/compile-c-cli.mjs INPUT.c [-o OUTPUT.bin] [--bundle dist/show-asm]

Compiles a single classic-Mac C source file to a MacBinary II APPL
using the wasm-retro-cc toolchain (Retro68's cc1 + as + ld + Elf2Mac,
Emscripten-built). Prints per-stage timings + a final size summary.

  -o, --o OUTPUT.bin     Where to write the output. Defaults to
                         <input-basename>.bin in the current
                         working directory.
  --bundle DIR           Override the toolchain bundle location.
                         Defaults to dist/show-asm/ relative to the
                         repo root.
  -h, --help             This help text.
`);
  process.exit(0);
}

// First non-flag arg is the input source.
const positional = args.filter(
  (a, i) =>
    !a.startsWith("-") &&
    !["o", "bundle", "-o", "--o", "--bundle"].includes(args[i - 1] ?? ""),
);
if (positional.length === 0) {
  console.error("error: no input .c file given. See --help.");
  process.exit(1);
}
const sourcePath = resolve(positional[0]);
if (!existsSync(sourcePath)) {
  console.error(`error: ${sourcePath} not found.`);
  process.exit(2);
}

const bundleDir = resolve(flag("bundle", join(REPO, "dist/show-asm")));
if (!existsSync(join(bundleDir, "cc1.mjs"))) {
  console.error(
    `error: bundle not found at ${bundleDir}. Run "node scripts/build-show-asm-bundle.mjs" first, or pass --bundle DIR.`,
  );
  process.exit(2);
}

const outPath = resolve(
  flag("o", basename(sourcePath, ".c") + ".bin"),
);

// ── sysroot blob loader ─────────────────────────────────────────────
// Same shape as web-demo/compile.mjs but reads from disk via fs.
const blobCache = new Map();
function loadSysrootBlob(binName, indexName) {
  const key = binName;
  if (blobCache.has(key)) return blobCache.get(key);
  const blob = readFileSync(join(bundleDir, binName));
  const index = JSON.parse(readFileSync(join(bundleDir, indexName), "utf8"));
  const out = { blob: new Uint8Array(blob.buffer, blob.byteOffset, blob.byteLength), index };
  blobCache.set(key, out);
  return out;
}

function mkdirPInMem(Module, fullPath, made) {
  const parts = fullPath.split("/").filter(Boolean);
  parts.pop();
  let cur = "";
  for (const p of parts) {
    cur += "/" + p;
    if (made.has(cur)) continue;
    try { Module.FS.mkdir(cur); } catch {}
    made.add(cur);
  }
}

async function mountSysroot(Module, which) {
  const { blob, index } =
    which === "headers"
      ? loadSysrootBlob("sysroot.bin", "sysroot.index.json")
      : loadSysrootBlob("sysroot-libs.bin", "sysroot-libs.index.json");
  try { Module.FS.mkdir("/sysroot"); } catch {}
  const made = new Set(["/sysroot"]);
  for (const entry of index) {
    const full = "/sysroot/" + entry.p;
    mkdirPInMem(Module, full, made);
    Module.FS.writeFile(full, blob.subarray(entry.o, entry.o + entry.l));
  }
}

// ── tool loader ─────────────────────────────────────────────────────
async function loadTool(mjsName, mount) {
  // Dynamic-import the Emscripten ES module factory. The .mjs files
  // expect to find their .wasm sibling next to themselves; Emscripten
  // looks up the wasm via `locateFile(path)` which we override to
  // point straight at the bundle directory.
  const factoryMod = await import(join(bundleDir, mjsName));
  const factory = factoryMod.default;
  const stderr = [];
  const Module = await factory({
    noInitialRun: true,
    print: (s) => stderr.push(s),
    printErr: (s) => stderr.push(s),
    locateFile: (path) => join(bundleDir, path),
  });
  if (mount) await mountSysroot(Module, mount);
  return { Module, stderr };
}

function callMain(tool, argv) {
  tool.stderr.length = 0;
  try {
    return tool.Module.callMain(argv);
  } catch (e) {
    if (e?.name === "ExitStatus") return e.status ?? 1;
    tool.stderr.push(`wasm trap: ${e?.message ?? e}`);
    return 2;
  }
}

// ── full pipeline ───────────────────────────────────────────────────
const source = readFileSync(sourcePath, "utf8");
const sourceName = basename(sourcePath);
const baseNoExt = basename(sourceName, ".c");

console.log(`[wasm-retro-cc] ${sourceName} (${source.length} bytes) -> ${outPath}`);
console.log(`[wasm-retro-cc] bundle: ${bundleDir}`);

const fmt = (n) => `${Math.round(n)}ms`;
function fail(stage, exitCode, msg) {
  console.error(`[wasm-retro-cc] FAILED at stage ${stage}: ${msg}`);
  process.exit(exitCode);
}

const t0 = performance.now();

// 1. cc1 — .c -> .s
let t = performance.now();
const cc1 = await loadTool("cc1.mjs", "headers");
const cc1FetchMs = performance.now() - t;
cc1.Module.FS.writeFile(`/tmp/${sourceName}`, source);
t = performance.now();
const cc1Rc = callMain(cc1, [
  "-quiet",
  "-isystem", "/sysroot/gcc-include",
  "-isystem", "/sysroot/include",
  "-mcpu=68020",
  "-O0",
  `/tmp/${sourceName}`,
  "-o", `/tmp/${baseNoExt}.s`,
]);
console.log(`[1/4] cc1   init ${fmt(cc1FetchMs)}, compile ${fmt(performance.now() - t)}, rc=${cc1Rc}`);
if (cc1.stderr.length) cc1.stderr.forEach((l) => console.error(`      ${l}`));
if (cc1Rc !== 0) fail("cc1", 10, `rc=${cc1Rc}`);
const asmBytes = cc1.Module.FS.readFile(`/tmp/${baseNoExt}.s`);

// 2. as — .s -> .o
t = performance.now();
const as = await loadTool("as.mjs", null);
const asFetchMs = performance.now() - t;
as.Module.FS.writeFile(`/tmp/${baseNoExt}.s`, asmBytes);
t = performance.now();
const asRc = callMain(as, [
  "-march=68020",
  `/tmp/${baseNoExt}.s`,
  "-o", `/tmp/${baseNoExt}.o`,
]);
console.log(`[2/4] as    init ${fmt(asFetchMs)}, assemble ${fmt(performance.now() - t)}, rc=${asRc}`);
if (as.stderr.length) as.stderr.forEach((l) => console.error(`      ${l}`));
if (asRc !== 0) fail("as", 20, `rc=${asRc}`);
const oBytes = as.Module.FS.readFile(`/tmp/${baseNoExt}.o`);

// 3. ld — link with the Retro68 sysroot using multi-segment ld script.
t = performance.now();
const ld = await loadTool("ld.mjs", "libs");
const ldFetchMs = performance.now() - t;
ld.Module.FS.writeFile(`/tmp/${baseNoExt}.o`, oBytes);
t = performance.now();
const ldRc = callMain(ld, [
  "-T", "/sysroot/ld/retro68-multiseg.ld",
  "-L", "/sysroot/lib",
  "--no-warn-rwx-segments",
  "--emit-relocs",
  "-o", "/tmp/out.gdb",
  "/sysroot/lib/start.c.obj",
  `/tmp/${baseNoExt}.o`,
  "--start-group",
  "/sysroot/lib/libretrocrt.a",
  "/sysroot/lib/libInterface.a",
  "/sysroot/lib/libc.a",
  "/sysroot/lib/libm.a",
  "/sysroot/lib/libgcc.a",
  "--end-group",
]);
console.log(`[3/4] ld    init ${fmt(ldFetchMs)}, link ${fmt(performance.now() - t)}, rc=${ldRc}`);
if (ld.stderr.length) ld.stderr.forEach((l) => console.error(`      ${l}`));
if (ldRc !== 0) fail("ld", 30, `rc=${ldRc}`);
const elfBytes = ld.Module.FS.readFile("/tmp/out.gdb");

// 4. Elf2Mac — ELF -> MacBinary II
t = performance.now();
const e2m = await loadTool("Elf2Mac.mjs", null);
const e2mFetchMs = performance.now() - t;
e2m.Module.FS.writeFile("/tmp/out.bin.gdb", elfBytes);
t = performance.now();
const e2mRc = callMain(e2m, ["--elf2mac", "-o", "/tmp/out.bin"]);
console.log(`[4/4] Elf2Mac init ${fmt(e2mFetchMs)}, convert ${fmt(performance.now() - t)}, rc=${e2mRc}`);
if (e2m.stderr.length) e2m.stderr.forEach((l) => console.error(`      ${l}`));
if (e2mRc !== 0) fail("Elf2Mac", 40, `rc=${e2mRc}`);
const bin = e2m.Module.FS.readFile("/tmp/out.bin");

mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, Buffer.from(bin));

console.log(
  `[wasm-retro-cc] done in ${fmt(performance.now() - t0)} — ${bin.length}-byte MacBinary II -> ${outPath}`,
);
