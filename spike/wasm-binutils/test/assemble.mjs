#!/usr/bin/env node
/**
 * Phase 2.2 end-to-end test — assemble hello_toolbox.s via WASM `as`.
 *
 * Mirrors the spike/wasm-cc1/test/compile-hello-toolbox.mjs pattern:
 * import the ESM factory, instantiate, write input to MEMFS, callMain,
 * read output, validate.
 *
 * Input is the .s the wasm cc1 produced in Phase 2.1's end-to-end test.
 * Output is an m68k ELF .o we can hand to ld next.
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const AS_MJS  = resolve(__dirname, "../build/stage2/gas/as.mjs");
const INPUT_S = resolve(__dirname, "../../wasm-cc1/build/test/hello_toolbox_wasm.s");
const OUT_O   = resolve(__dirname, "../build/test/hello_toolbox.o");

const asmBytes = readFileSync(INPUT_S);
console.log(`[harness] input: ${INPUT_S} (${asmBytes.length} bytes)`);

const mod = await import(AS_MJS);
const stdout = [], stderr = [];
const Module = await mod.default({
  noInitialRun: true,
  print:    (s) => stdout.push(s),
  printErr: (s) => stderr.push(s),
});
console.log(`[harness] as.wasm instantiated`);

Module.FS.writeFile("/tmp/hello.s", asmBytes);
console.log(`[harness] wrote /tmp/hello.s (${asmBytes.length} bytes)`);

const argv = ["-march=68020", "/tmp/hello.s", "-o", "/tmp/hello.o"];
console.log(`[harness] callMain(${JSON.stringify(argv)})`);
let rc;
try { rc = Module.callMain(argv); }
catch (e) {
  if (e.name === "ExitStatus") rc = e.status;
  else throw e;
}
console.log(`[harness] as exit code: ${rc}`);

if (stderr.length) {
  console.log(`[harness] as stderr (${stderr.length} lines):`);
  stderr.slice(0, 10).forEach((l) => console.log(`  | ${l}`));
}
if (rc !== 0) { console.error("[harness] FAIL: as exited non-zero"); process.exit(rc); }

const elfBytes = Module.FS.readFile("/tmp/hello.o");
console.log(`[harness] read /tmp/hello.o (${elfBytes.length} bytes)`);

// Validate ELF magic + class + endian + machine.
const m = elfBytes;
const magicOk = m[0] === 0x7f && m[1] === 0x45 && m[2] === 0x4c && m[3] === 0x46;
if (!magicOk) { console.error("[harness] FAIL: not an ELF"); process.exit(1); }
const elfClass = m[4];   // 1 = ELF32, 2 = ELF64
const elfEndian = m[5];  // 1 = LE, 2 = BE
const eMachine = elfEndian === 2 ? (m[0x12] << 8) | m[0x13] : (m[0x13] << 8) | m[0x12];
console.log(`[harness] ELF: ${elfClass === 1 ? "ELF32" : "ELF64"}, ${elfEndian === 2 ? "big" : "little"}-endian, machine=0x${eMachine.toString(16).padStart(4, "0")} (m68k = 0x0004)`);
if (elfClass !== 1)       { console.error("[harness] FAIL: expected ELF32");       process.exit(1); }
if (elfEndian !== 2)      { console.error("[harness] FAIL: expected big-endian");  process.exit(1); }
if (eMachine !== 0x0004)  { console.error("[harness] FAIL: expected m68k (0x0004)"); process.exit(1); }

// The InitGraf A-trap (0xa86e) should appear as big-endian bytes in
// the .text section.
let foundTrap = false;
for (let i = 0; i < m.length - 1; i++) {
  if (m[i] === 0xa8 && m[i + 1] === 0x6e) { foundTrap = true; break; }
}
if (!foundTrap) { console.error("[harness] FAIL: InitGraf A-trap not in output"); process.exit(1); }

mkdirSync(dirname(OUT_O), { recursive: true });
writeFileSync(OUT_O, elfBytes);
console.log(`[harness] wrote ${OUT_O} (${elfBytes.length} bytes)`);
console.log(`[harness] PASS: WASM as assembled m68k ELF object file`);
console.log(`[harness] Phase 2.2 end-to-end derisk: PASS.`);
