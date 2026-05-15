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
  // libgcc.a — softfloat / softdiv helpers (`__udivsi3`, `__mulsi3`, …)
  // referenced transitively from libretrocrt's syscalls.c.obj and from
  // any C source that does 32-bit multiplication or division on m68k.
  // Without this, ld can't resolve those symbols and the link fails.
  // Extracted from `/Retro68-build/toolchain/lib/gcc/m68k-apple-macos/12.2.0/libgcc.a`
  // in the Retro68 docker image.
  "libgcc.a",
]);
const LIB_SUBTREE = "lib";
const LD_SUBTREE = "ld";

// libretrocrt.a:start.c.obj is the Mac _start function — it sets up the
// A5 world, runs Retro68's relocations and constructors, then calls
// `main`. We need it linked at the very start of the input list so the
// ld script's `PROVIDE(_start = .)` *fallback* (a single `RTS`) doesn't
// pre-satisfy `_start` before the archive scan reaches start.c.obj.
//
// GNU ld's archive search is symbol-driven: it pulls a `.o` from a `.a`
// only when an unresolved symbol references it. Once `PROVIDE` defines
// `_start`, the archive scan stops searching for `_start` — the
// non-libretrocrt fallback wins, the entry trampoline jumps to a
// single `RTS`, and the app exits immediately after launch with no
// `main()` ever running. We caught this end-to-end on the deployed
// cv-mac playground; see LEARNINGS "Phase 2.3d — _start fallback was
// pre-satisfying libretrocrt's real entry point".
//
// The fix: ship `start.c.obj` as a standalone `.o` in the bundle so the
// consumer can pass it directly to `ld` before any `.a` archive, which
// satisfies `_start` ahead of the script's PROVIDE.
const START_OBJ_BASENAME = "start.c.obj";

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

/** Pull a single object member out of a GNU ar archive. Returns the
 *  raw .o bytes. Used to ship `libretrocrt.a:start.c.obj` as a
 *  standalone input file in the bundle — see START_OBJ_BASENAME's
 *  doc comment for the rationale.
 *
 *  GNU `ar` archive layout: 8-byte magic `!<arch>\n`, then a sequence
 *  of 60-byte headers each followed by data and an optional padding
 *  byte. Extended-length filenames are stored as `/<offset>` references
 *  into the special `//` member's data. We handle exactly enough format
 *  to find the named .obj — full ar parsers do much more (symbol index,
 *  thin archives, BSD-style names) that this code intentionally skips. */
function extractArchiveMember(archivePath, memberName) {
  const data = readFileSync(archivePath);
  const magic = data.slice(0, 8).toString("ascii");
  if (magic !== "!<arch>\n") {
    throw new Error(`${archivePath}: not a GNU ar archive (magic '${magic}')`);
  }
  let cursor = 8;
  let extTable = null;
  while (cursor + 60 <= data.length) {
    const header = data.slice(cursor, cursor + 60);
    let name = header.slice(0, 16).toString("ascii").trimEnd();
    const size = parseInt(header.slice(48, 58).toString("ascii").trim(), 10);
    const memberData = data.slice(cursor + 60, cursor + 60 + size);
    cursor += 60 + size + (size % 2); // pad to even byte
    if (name === "//") {
      extTable = memberData;
      continue;
    }
    if (name === "/" || name === "") continue; // symbol index
    if (name.startsWith("/") && extTable) {
      const idx = parseInt(name.slice(1), 10);
      const end = extTable.indexOf("/\n", idx);
      name = extTable.slice(idx, end).toString("ascii");
    } else if (name.endsWith("/")) {
      name = name.slice(0, -1);
    }
    if (name === memberName) return Buffer.from(memberData);
  }
  throw new Error(`${archivePath}: member '${memberName}' not found`);
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
//   /lib/start.c.obj          — extracted from libretrocrt.a and shipped
//                                as a standalone .o so the consumer can
//                                link it ahead of any .a archive (see
//                                the comment on START_OBJ_BASENAME above).
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

// 2c. Extract `start.c.obj` from `libretrocrt.a` and append it to the
//     libs blob as a standalone entry at `lib/start.c.obj`. We append
//     rather than re-pack to keep the implementation small; the JSON
//     index gains one entry and the .bin grows by ~1.2 KB.
//
// Side-effect: ALSO write the extracted .obj to the source sysroot
// tree under `lib/start.c.obj`. That way the spike's `full-pipeline.mjs`
// (which mounts the source sysroot via NODEFS rather than reading the
// packed blob) can link against it directly. The packed-blob consumers
// (cv-mac) read from the blob entry; the in-tree spike consumer reads
// from disk. One canonical source of truth, two delivery paths.
const startObjBytes = extractArchiveMember(
  resolve(SYSROOT_SRC, LIB_SUBTREE, "libretrocrt.a"),
  START_OBJ_BASENAME,
);
writeFileSync(
  resolve(SYSROOT_SRC, LIB_SUBTREE, START_OBJ_BASENAME),
  startObjBytes,
);
console.log(
  `[bundle] wrote ${LIB_SUBTREE}/${START_OBJ_BASENAME} to source sysroot for spike use`,
);
{
  // Re-read the libs blob, append start.c.obj, re-write blob + index.
  const libsBin = readFileSync(join(OUT_DIR, "sysroot-libs.bin"));
  const libsIndex = JSON.parse(
    readFileSync(join(OUT_DIR, "sysroot-libs.index.json"), "utf8"),
  );
  libsIndex.push({
    p: `${LIB_SUBTREE}/${START_OBJ_BASENAME}`,
    o: libsBin.length,
    l: startObjBytes.length,
  });
  const newLibs = Buffer.concat([libsBin, startObjBytes]);
  writeFileSync(join(OUT_DIR, "sysroot-libs.bin"), newLibs);
  writeFileSync(
    join(OUT_DIR, "sysroot-libs.index.json"),
    JSON.stringify(libsIndex),
  );
  libs.blob = new Uint8Array(newLibs);
  libs.indexEntries = libsIndex;
  console.log(
    `[bundle] sysroot-libs.bin           +${startObjBytes.length} B for ${LIB_SUBTREE}/${START_OBJ_BASENAME}`,
  );
}

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
