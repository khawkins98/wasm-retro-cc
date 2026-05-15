#!/usr/bin/env node
/**
 * verify-show-asm-bundle.mjs — sanity-check the dist/show-asm/ bundle by
 * loading cc1.mjs in Node, unpacking the sysroot blob into MEMFS the way
 * the cv-mac playground will, and compiling a tiny C program down to .s.
 *
 * Pass criterion: cc1 exits 0, /tmp/out.s is non-empty, and the asm
 * contains an obvious m68k instruction. This is a smoke test, not a byte
 * equivalence check — that's covered by the existing
 * spike/wasm-cc1/test/* suites.
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
console.log(`[verify] PASS`);
