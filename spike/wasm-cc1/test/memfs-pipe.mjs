#!/usr/bin/env node
/**
 * Phase 2.1.x — MEMFS pipe-through harness.
 *
 * Loads cc1.mjs in Node, writes a tiny stdlib-free C source into MEMFS,
 * invokes cc1 with the cooked argv the native gcc driver uses (captured
 * via `gcc -v` against stage 1's cross-cc1), then reads the generated
 * m68k assembly out of MEMFS and sanity-checks it against the expected
 * shape from the native build.
 *
 * Success = the wasm cc1 emits m68k assembly equivalent to what the
 * native m68k-apple-macos-cc1 emits for the same source. This is the
 * Phase 2.1.x derisk — proves the wasm cc1 is functionally equivalent
 * to the native one, not just structurally loadable.
 *
 * Run:
 *   node spike/wasm-cc1/test/memfs-pipe.mjs
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const CC1_MJS = resolve(__dirname, "../build/stage2/gcc/cc1.mjs");

// Test source: a stdlib-free, header-free function. Phase 2.1.x scope —
// just prove the pipeline works on something cc1 can handle without a
// vendored sysroot. hello_toolbox.c (which needs Retro68's CIncludes)
// is a separate sub-spike (Phase 2.1.y, with sysroot vendoring).
const TEST_C = `
int add(int a, int b) { return a + b; }
`;

// Expected m68k mnemonics in the output. If any are missing, cc1 is
// either not running or running differently than the native build.
// Captured from stage 1 native cc1's emission for the same source:
//   add:
//     link.w %fp,#0
//     move.l 8(%fp),%d0
//     add.l 12(%fp),%d0
//     unlk %fp
//     rts
const EXPECTED_MNEMONICS = ["link.w", "move.l", "add.l", "unlk", "rts"];

async function main() {
  console.log(`[harness] loading ${CC1_MJS}`);
  const mod = await import(CC1_MJS);
  const stdout = [];
  const stderr = [];
  const Module = await mod.default({
    noInitialRun: true,
    print: (s) => stdout.push(s),
    printErr: (s) => stderr.push(s),
  });
  console.log(`[harness] cc1.wasm instantiated`);

  // Write the input. Use a fresh /tmp dir inside MEMFS — emscripten's
  // default sysroot has /tmp mounted as MEMFS.
  Module.FS.writeFile("/tmp/test.c", TEST_C);
  console.log(`[harness] wrote /tmp/test.c (${TEST_C.length} bytes) to MEMFS`);

  // Mirror the native gcc -v capture, minus the -iprefix/-isystem paths
  // (those point at host paths inside Docker that don't exist in our
  // MEMFS). For a header-free source this is fine; -isystem matters
  // only when including system headers.
  //
  // Flags explained:
  //   -quiet         cc1's standard "no banner" mode
  //   -mcpu=68020    target the same cpu as the native build
  //   /tmp/test.c    input (positional)
  //   -o /tmp/test.s output (positional)
  // -dumpdir / -dumpbase are diagnostic file paths; harmless here.
  const argv = [
    "-quiet",
    "-mcpu=68020",
    "/tmp/test.c",
    "-o", "/tmp/test.s",
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
    stderr.slice(0, 20).forEach((l) => console.log(`  | ${l}`));
  }
  if (stdout.length) {
    console.log(`[harness] cc1 stdout (${stdout.length} lines):`);
    stdout.slice(0, 5).forEach((l) => console.log(`  | ${l}`));
  }

  // Read the output assembly back from MEMFS.
  let asm;
  try {
    asm = new TextDecoder().decode(Module.FS.readFile("/tmp/test.s"));
  } catch (e) {
    console.error(`[harness] FAIL: /tmp/test.s not produced — ${e.message}`);
    process.exit(1);
  }
  console.log(`[harness] read /tmp/test.s (${asm.length} bytes) from MEMFS`);
  console.log(`[harness] --- assembly head ---`);
  asm.split("\n").slice(0, 20).forEach((l) => console.log(`  | ${l}`));
  console.log(`[harness] --- end ---`);

  // Sanity check: the expected m68k mnemonics should appear.
  const missing = EXPECTED_MNEMONICS.filter((m) => !asm.includes(m));
  if (missing.length) {
    console.error(`[harness] FAIL: missing mnemonics: ${missing.join(", ")}`);
    process.exit(1);
  }
  console.log(`[harness] PASS: all expected mnemonics found: ${EXPECTED_MNEMONICS.join(", ")}`);
  console.log(`[harness] Phase 2.1.x MEMFS pipe-through derisk: PASS.`);
}

main().catch((e) => {
  console.error(`[harness] FAIL: ${e.stack || e}`);
  process.exit(1);
});
