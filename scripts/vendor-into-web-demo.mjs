#!/usr/bin/env node
/*
 * vendor-into-web-demo.mjs — refresh the bundle bytes committed under
 * web-demo/wasm-cc1/ from the freshly-built bundle at dist/show-asm/.
 *
 * Run after `scripts/build-show-asm-bundle.mjs` to keep the live demo
 * tracking the latest toolchain. The bytes are committed so GitHub
 * Pages can serve them without a build step.
 *
 *   node scripts/build-show-asm-bundle.mjs
 *   node scripts/vendor-into-web-demo.mjs
 *
 * Mirrors the cv-mac script of the same name. Single source of truth
 * is dist/show-asm/ — web-demo/wasm-cc1/ is a byte-for-byte copy.
 */
import { copyFileSync, mkdirSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, "..");
const SRC = resolve(REPO, "dist/show-asm");
const DEST = resolve(REPO, "web-demo/wasm-cc1");

const FILES = [
  "cc1.mjs", "cc1.wasm",
  "as.mjs", "as.wasm",
  "ld.mjs", "ld.wasm",
  "Elf2Mac.mjs", "Elf2Mac.wasm",
  "sysroot.bin", "sysroot.index.json",
  "sysroot-libs.bin", "sysroot-libs.index.json",
];

mkdirSync(DEST, { recursive: true });
let total = 0;
for (const f of FILES) {
  const src = resolve(SRC, f);
  const dst = resolve(DEST, f);
  copyFileSync(src, dst);
  const sz = statSync(dst).size;
  total += sz;
  console.log(`  ${f.padEnd(28)} ${(sz / 1024).toFixed(1).padStart(8)} KiB`);
}
console.log(`-> ${DEST}`);
console.log(`   ${FILES.length} files, ${(total / 1024 / 1024).toFixed(2)} MiB total (raw — browsers fetch brotli)`);
