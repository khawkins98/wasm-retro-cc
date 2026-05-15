#!/usr/bin/env node
/**
 * build-show-asm-bundle.mjs — package the in-browser Retro68 toolchain
 * (cc1 + as + ld + Elf2Mac + Retro68 sysroot headers and libs) for the
 * classic-vibe-mac playground. Originally built for the "Show Assembly"
 * feature (just cc1 + headers); extended in Phase 2.3d to ship the
 * full pipeline (#15 / cv-mac #64).
 *
 * The bundle name "show-asm" is sticky for backwards-compatible
 * vendoring — the cv-mac script `scripts/vendor-wasm-cc1.mjs` looks
 * here. Conceptually it's now "the playground's toolchain bundle".
 *
 * Output layout (dist/show-asm/):
 *
 *   cc1.mjs              — Emscripten ES module factory for cc1 (147 KB)
 *   cc1.wasm             — the compiler (~12 MB raw / ~3.3 MB brotli)
 *   as.mjs / as.wasm     — assembler (~845 KB raw / ~270 KB brotli)
 *   ld.mjs / ld.wasm     — linker (~1.1 MB raw / ~310 KB brotli)
 *   Elf2Mac.mjs/wasm     — ELF → MacBinary II converter (~360 KB / ~85 KB br)
 *   sysroot.bin          — concatenated *header* bytes (gcc-include + include)
 *   sysroot.index.json   — [{ p, o, l }] per-file path/offset/length
 *   sysroot-libs.bin     — concatenated *library + ld-script* bytes
 *                          (libretrocrt + libInterface + libc + libm +
 *                           retro68-flat.ld). Separate blob so the
 *                          Show Assembly panel can fetch *only* the
 *                          headers and skip ~6 MB of libs it never reads.
 *   sysroot-libs.index.json
 *   README.md            — bundle contract for consumers
 *
 * What's in the sysroot:
 *   - gcc-include/   (GCC builtins: stdarg.h, stddef.h, stdbool.h, …) — 104 KB
 *   - include/       (Retro68 Mac Toolbox + libc headers) — 15 MB raw, but we
 *                    EXCLUDE include/c++/ (13 MB of STL we don't need for C)
 *                    → ~2 MB raw, well under 1 MB brotli.
 *   - lib/           (subset — see SYSROOT_LIB_KEEP below): the m68k static
 *                    archives the linker actually references for a C-only
 *                    Toolbox app. Skips libstdc++.a (17 MB), libg.a (5 MB,
 *                    debug duplicate of libc), libsupc++.a, libNavigation.far.a,
 *                    libRetroConsole.a, and the full ldscripts/ directory
 *                    (we ship just `retro68-flat.ld`).
 *   - ld/            (just `retro68-flat.ld`).
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
const AS_BUILD = resolve(ROOT, "spike/wasm-binutils/build/stage2/gas");
const LD_BUILD = resolve(ROOT, "spike/wasm-binutils/build/stage2/ld");
const E2M_BUILD = resolve(ROOT, "spike/wasm-elf2mac/build/stage2/Elf2Mac");
const SYSROOT_SRC = resolve(ROOT, "spike/wasm-cc1/build/sysroot");
const OUT_DIR = resolve(ROOT, "dist/show-asm");

// Tool artefacts to ship.  Each entry: [src_dir, mjs_basename, wasm_basename].
const TOOLS = [
  [CC1_BUILD, "cc1.mjs", "cc1.wasm"],
  [AS_BUILD, "as.mjs", "as.wasm"],
  [LD_BUILD, "ld.mjs", "ld.wasm"],
  [E2M_BUILD, "Elf2Mac.mjs", "Elf2Mac.wasm"],
];

// "Header" subtrees we want for the cc1-only path (Show Assembly).
// include/c++ is the C++ STL — useless for the C compiler we're shipping,
// and it's 13 MB of the 15 MB include/ tree.
const HEADER_SUBTREES = ["gcc-include", "include"];
const HEADER_EXCLUDE_PREFIXES = ["include/c++/"];

// "Lib" subtrees we want for the full-pipeline path (Build .c → .bin).
// `lib/` has many archives; only a handful are referenced by a C-only
// Retro68 link. Whitelist by basename:
//   libretrocrt.a   — startup, segment loader, A5-world setup
//   libInterface.a  — Toolbox glue (DrawString, WaitNextEvent, …)
//   libc.a          — newlib libc
//   libm.a          — newlib libm (math symbols ld may pull in)
// Excludes (would more than triple the bundle):
//   libstdc++.a (17 MB) / libsupc++.a (1 MB) — C++ runtime, not used
//   libg.a (5 MB) — debug duplicate of libc
//   libNavigation.far.a / libRetroConsole.a — niche, not in default link
// Plus `ld/retro68-flat.ld` is the only ld script we ship today.
const LIB_KEEP_BASENAMES = new Set([
  "libretrocrt.a",
  "libInterface.a",
  "libc.a",
  "libm.a",
]);
const LIB_SUBTREE = "lib";
const LD_SUBTREE = "ld";

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

for (const [srcDir, mjs, wasm] of TOOLS) {
  ensureExists(resolve(srcDir, mjs));
  ensureExists(resolve(srcDir, wasm));
}
ensureExists(SYSROOT_SRC);

console.log(`[bundle] root: ${ROOT}`);
console.log(`[bundle] output: ${OUT_DIR}`);

rmSync(OUT_DIR, { recursive: true, force: true });
mkdirSync(OUT_DIR, { recursive: true });

// 1. Copy the four .mjs + .wasm pairs verbatim.
for (const [srcDir, mjs, wasm] of TOOLS) {
  copyFileSync(resolve(srcDir, mjs), join(OUT_DIR, mjs));
  copyFileSync(resolve(srcDir, wasm), join(OUT_DIR, wasm));
  console.log(
    `[bundle] ${mjs.padEnd(14)} ${statSync(join(OUT_DIR, mjs)).size} B`,
  );
  console.log(
    `[bundle] ${wasm.padEnd(14)} ${statSync(join(OUT_DIR, wasm)).size} B`,
  );
}

// 2. Pack a flat blob + index by walking the given relative subtrees and
//    applying an entry-level filter. Used for both the headers blob and
//    the libs blob.
//
// Case-fold aliasing
// ------------------
// The sysroot is extracted on macOS HFS+ (case-insensitive). Two header
// names that differ only in case (e.g. Mac Toolbox `Strings.h` vs newlib
// `strings.h`) collide on disk into a single file. MEMFS in the browser
// is case-sensitive, so when newlib's `string.h` does
// `#include <strings.h>` it can't resolve — only `Strings.h` exists.
//
// We work around this at pack time by emitting a *lowercase alias* entry
// for any file whose lowercase path differs from its on-disk path AND
// whose lowercase path doesn't already exist as a distinct entry. The
// alias points at the same byte range in the blob — zero size cost.
//
// Long-term fix is to re-extract the sysroot on a case-sensitive
// filesystem (Linux container or APFS case-sensitive volume). Until
// then, this works for the headers newlib actually `#include`s.
function packBlob(blobName, indexName, options) {
  const { subtrees, keepEntry } = options;
  const files = [];
  for (const sub of subtrees) {
    const base = join(SYSROOT_SRC, sub);
    if (!statSync(base, { throwIfNoEntry: false })) continue;
    walk(base, files);
  }
  const indexEntries = [];
  const chunks = [];
  let offset = 0;
  // First pass — pack each on-disk file. Record paths so we can
  // detect collisions in the alias pass below.
  const existingPaths = new Set();
  for (const abs of files.sort()) {
    const rel = relative(SYSROOT_SRC, abs).split("\\").join("/");
    if (!keepEntry(rel)) continue;
    const bytes = readFileSync(abs);
    indexEntries.push({ p: rel, o: offset, l: bytes.length });
    existingPaths.add(rel);
    chunks.push(bytes);
    offset += bytes.length;
  }
  // Second pass — emit case-fold aliases for any entry whose lowercase
  // path isn't already represented. Same {o,l} as the original.
  let aliasCount = 0;
  for (const e of [...indexEntries]) {
    const lower = e.p.toLowerCase();
    if (lower === e.p) continue;
    if (existingPaths.has(lower)) continue;
    indexEntries.push({ p: lower, o: e.o, l: e.l });
    existingPaths.add(lower);
    aliasCount++;
  }
  const blob = Buffer.concat(chunks, offset);
  writeFileSync(join(OUT_DIR, blobName), blob);
  writeFileSync(join(OUT_DIR, indexName), JSON.stringify(indexEntries));
  console.log(
    `[bundle] ${blobName.padEnd(22)} ${blob.length} B across ${indexEntries.length} files (${aliasCount} case-fold aliases)`,
  );
  console.log(
    `[bundle] ${indexName.padEnd(22)} ${statSync(join(OUT_DIR, indexName)).size} B`,
  );
  return { blob, indexEntries, aliasCount };
}

// 2a. Header blob — what Show Assembly fetches (cc1's input headers).
const headers = packBlob("sysroot.bin", "sysroot.index.json", {
  subtrees: HEADER_SUBTREES,
  keepEntry: (rel) => !HEADER_EXCLUDE_PREFIXES.some((p) => rel.startsWith(p)),
});

// 2b. Library + ld-script blob — what Build .c fetches in addition.
//
//   /lib/<basename>           — only LIB_KEEP_BASENAMES (top-level files
//                                under lib/, no subdirs — lib/ldscripts/
//                                is intentionally NOT in the keep set).
//   /ld/retro68-flat.ld       — single ld script.
const libs = packBlob("sysroot-libs.bin", "sysroot-libs.index.json", {
  subtrees: [LIB_SUBTREE, LD_SUBTREE],
  keepEntry: (rel) => {
    if (rel.startsWith("ld/")) return rel === "ld/retro68-flat.ld";
    if (rel.startsWith("lib/")) {
      // Whitelist only top-level archives by basename. lib/ldscripts/ and
      // any other subdirs are dropped.
      const sub = rel.slice(4); // strip "lib/"
      if (sub.includes("/")) return false;
      return LIB_KEEP_BASENAMES.has(sub);
    }
    return false;
  },
});

// 3. README.
let totalRaw = 0;
for (const f of [
  ...TOOLS.flatMap(([, mjs, wasm]) => [mjs, wasm]),
  "sysroot.bin",
  "sysroot.index.json",
  "sysroot-libs.bin",
  "sysroot-libs.index.json",
]) {
  totalRaw += statSync(join(OUT_DIR, f)).size;
}

const readme = `# wasm-retro-cc playground bundle (alias: show-asm)

Generated by \`scripts/build-show-asm-bundle.mjs\`. Consumes the
\`spike/wasm-cc1/\`, \`spike/wasm-binutils/\`, and \`spike/wasm-elf2mac/\`
builds. Consumer: the \`classic-vibe-mac\` playground (cv-mac #64,
wasm-retro-cc #15, #17).

## Contents

| File | Purpose |
| --- | --- |
| \`cc1.mjs\` / \`cc1.wasm\` | Compiler (C → m68k \`.s\`) |
| \`as.mjs\` / \`as.wasm\` | Assembler (\`.s\` → \`.o\` ELF) |
| \`ld.mjs\` / \`ld.wasm\` | Linker (\`.o\` + libs + ld script → ELF executable) |
| \`Elf2Mac.mjs\` / \`Elf2Mac.wasm\` | ELF executable → single-fork MacBinary II APPL |
| \`sysroot.bin\` + \`sysroot.index.json\` | **Header** blob — gcc-include + include/ minus c++/ (~1.1 MB raw / ~190 KB br) |
| \`sysroot-libs.bin\` + \`sysroot-libs.index.json\` | **Lib + ld-script** blob — libretrocrt + libInterface + libc + libm + retro68-flat.ld |

## Why two sysroot blobs

The Show Assembly panel only needs cc1 + headers; it never reads the
libs or the ld script. Splitting lets a "preview-only" client fetch
~190 KB brotli of headers and skip the multi-MB libs entirely. Clients
that want full-pipeline compile-to-\`.bin\` fetch both blobs.

## Sizes

- Header blob: ${headers.indexEntries.length} files, ${headers.blob.length} B raw
- Libs blob: ${libs.indexEntries.length} files, ${libs.blob.length} B raw
- Total bundle (raw): ${totalRaw} B

## Consumer contract

1. **Show Assembly path** (cc1 only):
   - Fetch \`cc1.mjs\` + \`cc1.wasm\` (Emscripten resolves the wasm relative
     to the .mjs — pass \`locateFile\` if hosted at a different path).
   - Fetch \`sysroot.bin\` + \`sysroot.index.json\`.
   - For each entry, \`Module.FS.writeFile("/sysroot/" + entry.p, blob.subarray(o, o+l))\`
     with a per-directory mkdir-p walk over distinct path prefixes.
   - Invoke:
     \`\`\`
     Module.callMain([
       "-quiet",
       "-isystem", "/sysroot/gcc-include",
       "-isystem", "/sysroot/include",
       "-mcpu=68020",
       "/tmp/in.c",
       "-o", "/tmp/out.s",
     ]);
     \`\`\`

2. **Full pipeline path** (C → MacBinary II APPL):
   - Plus \`as.mjs/wasm\`, \`ld.mjs/wasm\`, \`Elf2Mac.mjs/wasm\`.
   - Plus \`sysroot-libs.bin\` + \`sysroot-libs.index.json\` mounted under
     \`/sysroot/\` (so \`/sysroot/lib/libretrocrt.a\` etc. resolve).
   - Per-tool MEMFS: each Emscripten Module has its own. The headers
     blob is needed for cc1; the libs blob is needed for ld. as and
     Elf2Mac don't read sysroot, so you can skip the mount entirely
     in their Modules.
   - Chain via in-MEMFS file transfers (\`FS.readFile\` → \`FS.writeFile\`).
   - Done criterion: \`Elf2Mac\` emits \`/tmp/out.bin\` that passes
     \`spike-pcc/inspect_macbinary.py\`. End-to-end recipe: see
     \`spike/wasm-cc1/test/full-pipeline.mjs\`. The Elf2Mac call MUST
     have \`-o\` ending in \`.bin\` — otherwise Elf2Mac's format autodetect
     falls through to Linux split-fork (see LEARNINGS.md "Phase 2.3d").

## Regenerate

\`\`\`
node scripts/build-show-asm-bundle.mjs
\`\`\`

(Requires all four wasm builds + the sysroot extraction to already be
present locally — see CONTRIBUTING.md "wasm-cc1" / "wasm-binutils" /
"wasm-elf2mac" sections.)
`;
writeFileSync(join(OUT_DIR, "README.md"), readme);

console.log(`[bundle] total (raw): ${totalRaw} B`);
console.log(`[bundle] done.`);
