#!/usr/bin/env node
/**
 * build-show-asm-bundle.mjs — package cc1.wasm + a minimal sysroot for
 * the "Show Assembly" feature (wasm-retro-cc tracker #17, classic-vibe-mac #64).
 *
 * Output layout (dist/show-asm/):
 *
 *   cc1.mjs              — Emscripten ES module factory (147 KB)
 *   cc1.wasm             — the compiler (~12 MB raw / ~3.3 MB brotli)
 *   sysroot.bin          — concatenated header bytes (raw, no compression here —
 *                          static hosting layer applies brotli)
 *   sysroot.index.json   — [{ p, o, l }] one entry per file: path / offset / length
 *   README.md            — bundle contract for consumers
 *
 * What's in the sysroot:
 *   - gcc-include/   (GCC builtins: stdarg.h, stddef.h, stdbool.h, …) — 104 KB
 *   - include/       (Retro68 Mac Toolbox + libc headers) — 15 MB raw, but we
 *                    EXCLUDE include/c++/ (13 MB of STL we don't need for C)
 *                    → ~2 MB raw, well under 1 MB brotli.
 *
 * Why a flat blob + JSON index rather than tar / .data / individual files:
 *   - Tar parsers add code or a dep on the consumer; not worth it for a
 *     write-once-mount-once payload.
 *   - Emscripten --preload-file (.data) bakes the sysroot into the wasm
 *     pipeline at link time. We want the sysroot decoupled so the cv-mac
 *     playground can update headers without relinking cc1.
 *   - Many small files defeat brotli; one flat blob compresses optimally.
 *
 * Consumer-side use:
 *   1. Fetch cc1.mjs and cc1.wasm (lazy import on first use).
 *   2. Fetch sysroot.bin (ArrayBuffer) and sysroot.index.json (parse once).
 *   3. For each entry, slice the blob and `Module.FS.writeFile(...)` to
 *      `/sysroot/<p>` inside MEMFS, mkdir-p'ing parent directories.
 *   4. Invoke `Module.callMain(["-quiet", "-isystem", "/sysroot/gcc-include",
 *      "-isystem", "/sysroot/include", "-mcpu=68020", "/tmp/in.c",
 *      "-o", "/tmp/out.s"])`.
 *
 * Run:
 *   node scripts/build-show-asm-bundle.mjs
 */
import {
  copyFileSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");

const CC1_BUILD = resolve(ROOT, "spike/wasm-cc1/build/stage2/gcc");
const SYSROOT_SRC = resolve(ROOT, "spike/wasm-cc1/build/sysroot");
const OUT_DIR = resolve(ROOT, "dist/show-asm");

const CC1_MJS_SRC = resolve(CC1_BUILD, "cc1.mjs");
const CC1_WASM_SRC = resolve(CC1_BUILD, "cc1.wasm");

// Sysroot subtrees we want.  include/c++ is the C++ STL — useless for the
// C compiler we're shipping, and it's 13 MB of the 15 MB include/ tree.
const SUBTREES = ["gcc-include", "include"];
const EXCLUDE_PREFIXES = ["include/c++/"];

function ensureExists(p) {
  if (!statSync(p, { throwIfNoEntry: false })) {
    throw new Error(
      `missing input: ${p}\n` +
        `  run \`cmake --build spike/wasm-cc1/build\` first ` +
        `(see CONTRIBUTING.md "wasm-cc1" section).`,
    );
  }
}

function walk(dir, into) {
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, ent.name);
    if (ent.isDirectory()) {
      walk(full, into);
    } else if (ent.isFile()) {
      into.push(full);
    }
    // Skip symlinks defensively — sysroot has none today.
  }
}

ensureExists(CC1_MJS_SRC);
ensureExists(CC1_WASM_SRC);
ensureExists(SYSROOT_SRC);

console.log(`[bundle] root: ${ROOT}`);
console.log(`[bundle] output: ${OUT_DIR}`);

rmSync(OUT_DIR, { recursive: true, force: true });
mkdirSync(OUT_DIR, { recursive: true });

// 1. Copy the two wasm artefacts verbatim.
copyFileSync(CC1_MJS_SRC, join(OUT_DIR, "cc1.mjs"));
copyFileSync(CC1_WASM_SRC, join(OUT_DIR, "cc1.wasm"));
console.log(
  `[bundle] cc1.mjs   ${statSync(join(OUT_DIR, "cc1.mjs")).size} B`,
);
console.log(
  `[bundle] cc1.wasm  ${statSync(join(OUT_DIR, "cc1.wasm")).size} B`,
);

// 2. Collect sysroot files.
const files = [];
for (const sub of SUBTREES) {
  const base = join(SYSROOT_SRC, sub);
  if (!statSync(base, { throwIfNoEntry: false })) continue;
  const acc = [];
  walk(base, acc);
  for (const f of acc) files.push(f);
}
const indexEntries = [];
const chunks = [];
let offset = 0;

for (const abs of files.sort()) {
  const rel = relative(SYSROOT_SRC, abs).split("\\").join("/");
  if (EXCLUDE_PREFIXES.some((p) => rel.startsWith(p))) continue;
  const bytes = readFileSync(abs);
  indexEntries.push({ p: rel, o: offset, l: bytes.length });
  chunks.push(bytes);
  offset += bytes.length;
}

const blob = Buffer.concat(chunks, offset);
writeFileSync(join(OUT_DIR, "sysroot.bin"), blob);
writeFileSync(
  join(OUT_DIR, "sysroot.index.json"),
  JSON.stringify(indexEntries),
);

console.log(
  `[bundle] sysroot.bin           ${blob.length} B across ${indexEntries.length} files`,
);
console.log(
  `[bundle] sysroot.index.json    ${
    statSync(join(OUT_DIR, "sysroot.index.json")).size
  } B`,
);

// 3. README.
const totalRaw =
  statSync(join(OUT_DIR, "cc1.mjs")).size +
  statSync(join(OUT_DIR, "cc1.wasm")).size +
  blob.length +
  statSync(join(OUT_DIR, "sysroot.index.json")).size;

const readme = `# show-asm bundle

Generated by \`scripts/build-show-asm-bundle.mjs\`. Consumers: the
\`classic-vibe-mac\` playground "Show Assembly" panel (see cv-mac #64,
wasm-retro-cc #17).

## Contents

| File | Purpose |
| --- | --- |
| \`cc1.mjs\` | Emscripten ES module factory for cc1 |
| \`cc1.wasm\` | The compiler — runs C → m68k \`.s\` in the browser |
| \`sysroot.bin\` | Concatenated header bytes (no compression at this layer) |
| \`sysroot.index.json\` | \`[{p,o,l}]\` per file: path / byte-offset / length |

## What's in the sysroot

- \`gcc-include/\` — GCC builtins (stdarg.h, stddef.h, stdbool.h, …)
- \`include/\` — Retro68 Mac Toolbox + Newlib libc headers
  - **Excludes** \`include/c++/\` (13 MB of C++ STL — not needed for C compile)

## Sizes

${indexEntries.length} sysroot files, ${blob.length} bytes raw.
Total bundle (raw): ${totalRaw} bytes.

## Consumer contract

1. Fetch \`cc1.mjs\` and \`cc1.wasm\` lazily (Emscripten will load the wasm
   relative to the .mjs — pass \`locateFile\` if hosting under a different path).
2. Fetch \`sysroot.bin\` (\`ArrayBuffer\`) and \`sysroot.index.json\` once.
3. For each entry, \`Module.FS.writeFile("/sysroot/" + entry.p,
   new Uint8Array(buf, entry.o, entry.l))\`. Use a per-directory mkdir-p
   walk over distinct prefixes of \`entry.p\` first.
4. Invoke \`Module.callMain([
     "-quiet",
     "-isystem", "/sysroot/gcc-include",
     "-isystem", "/sysroot/include",
     "-mcpu=68020",
     "/tmp/in.c",
     "-o", "/tmp/out.s",
   ])\`.

## Regenerate

\`\`\`
node scripts/build-show-asm-bundle.mjs
\`\`\`

(Requires the cc1 + sysroot to already be built — see CONTRIBUTING.md.)
`;
writeFileSync(join(OUT_DIR, "README.md"), readme);

console.log(`[bundle] total (raw): ${totalRaw} B`);
console.log(`[bundle] done.`);
