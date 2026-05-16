/*
 * compile.mjs — minimal in-browser driver for the wasm-retro-cc
 * toolchain. Runs four Emscripten-built tools in sequence and surfaces
 * the intermediate artefacts:
 *
 *   cc1.wasm   .c   -> m68k .s    (assembly)
 *   as.wasm    .s   -> ELF .o     (object)
 *   ld.wasm    .o   -> ELF exec   (linked)
 *   Elf2Mac    ELF  -> MacBinary  (single-fork APPL)
 *
 * Lives next to wasm-cc1/ which holds the bundled tools and the two
 * sysroot blobs (headers + libs).
 *
 * This is a deliberately small reference implementation: one source
 * file, no editor, no caching, no streaming progress. The full
 * production driver — multi-file projects, header co-mounting, cc1
 * re-entrancy workarounds, optimisation levels, diagnostic parsing —
 * lives in classic-vibe-mac at src/web/src/playground/cc1.ts. Read that
 * if you want to build something real.
 */

const BUNDLE = "./wasm-cc1/";

// ── tiny logger ──────────────────────────────────────────────────────
const logEl = () => document.getElementById("log");
function log(line, cls) {
  const div = document.createElement("div");
  if (cls) div.className = cls;
  div.textContent = line;
  logEl().appendChild(div);
  logEl().scrollTop = logEl().scrollHeight;
}
function logClear() {
  logEl().innerHTML = "";
}

// ── sysroot blob loader ──────────────────────────────────────────────
//
// The bundle ships header bytes and library bytes as two concatenated
// blobs plus an index of `[{p, o, l}]` entries (path, offset, length).
// At tool startup we walk the index and write each entry into the
// tool's MEMFS under /sysroot/<path>. Slicing one ArrayBuffer is much
// cheaper than fetching ~200 individual files.
const blobCache = new Map();
async function loadSysrootBlob(binName, indexName) {
  const key = binName;
  if (blobCache.has(key)) return blobCache.get(key);
  const [blobBuf, indexText] = await Promise.all([
    fetch(BUNDLE + binName).then((r) => r.arrayBuffer()),
    fetch(BUNDLE + indexName).then((r) => r.text()),
  ]);
  const out = {
    blob: new Uint8Array(blobBuf),
    index: JSON.parse(indexText),
  };
  blobCache.set(key, out);
  return out;
}

function mkdirP(Module, fullPath, made) {
  const parts = fullPath.split("/").filter(Boolean);
  parts.pop(); // drop filename
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
      ? await loadSysrootBlob("sysroot.bin", "sysroot.index.json")
      : await loadSysrootBlob("sysroot-libs.bin", "sysroot-libs.index.json");
  try { Module.FS.mkdir("/sysroot"); } catch {}
  const made = new Set(["/sysroot"]);
  for (const entry of index) {
    const full = "/sysroot/" + entry.p;
    mkdirP(Module, full, made);
    Module.FS.writeFile(full, blob.subarray(entry.o, entry.o + entry.l));
  }
}

// ── tool loader ──────────────────────────────────────────────────────
//
// Each tool gets a fresh Module instance per pipeline run — cc1, as,
// ld and Elf2Mac all carry static state across callMain() that breaks
// a second invocation. (Full discussion: cv-mac LEARNINGS Key Story
// #3, "cc1.wasm is not re-entrant".) For a one-shot compile this is
// fine; for repeated builds the wasm bytes come from the HTTP cache.
async function loadTool(mjsName, mount) {
  const factoryMod = await import(BUNDLE + mjsName);
  const factory = factoryMod.default;
  const stderr = [];
  const Module = await factory({
    noInitialRun: true,
    print: (s) => stderr.push(s),
    printErr: (s) => stderr.push(s),
    locateFile: (path) => BUNDLE + path,
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

// ── full pipeline ────────────────────────────────────────────────────
//
// Mirrors src/web/src/playground/cc1.ts:compileToBin() from cv-mac,
// trimmed to one source file. The argv invocations here are the
// canonical recipe — see the long comments in cv-mac's cc1.ts around
// the ld stage if you wonder why `start.c.obj` is first or why
// `--emit-relocs` is required.
export async function compile(source, sourceName = "hello.c") {
  logClear();
  log(`compiling ${sourceName} (${source.length} bytes)`);
  const t0 = performance.now();
  const baseNoExt = sourceName.replace(/\.c$/i, "");

  // Per-stage timing accumulators. Each stage has two phases:
  //   `fetch` — fetch the .mjs/.wasm + Emscripten Module init + (optional)
  //             sysroot mount. On a cold tab this dominates: cc1.wasm is
  //             3.3 MB brotli and has to download + instantiate.
  //   `run`   — the actual callMain() that does the compiling.
  // Showing them split makes "the page took 4 s but the compiler only ran
  // for 50 ms" comprehensible at a glance.
  const t = {
    cc1Fetch: 0, cc1Run: 0,
    asFetch:  0, asRun:  0,
    ldFetch:  0, ldRun:  0,
    e2mFetch: 0, e2mRun: 0,
  };
  const fmt = (ms) => `${Math.round(ms)}ms`;
  const isWarm = blobCache.has("sysroot.bin");  // 2nd+ compile in this tab

  // 1. cc1 — C → m68k .s
  log("[1/4] cc1.wasm  (.c -> .s) — fetching toolchain + sysroot…");
  const cc1FetchStart = performance.now();
  const cc1 = await loadTool("cc1.mjs", "headers");
  t.cc1Fetch = performance.now() - cc1FetchStart;
  cc1.Module.FS.writeFile(`/tmp/${sourceName}`, source);
  const cc1Start = performance.now();
  const cc1Rc = callMain(cc1, [
    "-quiet",
    "-isystem", "/sysroot/gcc-include",
    "-isystem", "/sysroot/include",
    "-mcpu=68020",
    "-O0",
    `/tmp/${sourceName}`,
    "-o", `/tmp/${baseNoExt}.s`,
  ]);
  t.cc1Run = performance.now() - cc1Start;
  log(`      cc1 rc=${cc1Rc} — fetch+init ${fmt(t.cc1Fetch)}, compile ${fmt(t.cc1Run)}`);
  if (cc1.stderr.length) cc1.stderr.forEach((l) => log("      " + l, "warn"));
  if (cc1Rc !== 0) {
    log(`compile failed at stage 1 (cc1)`, "err");
    return { ok: false };
  }
  const asmBytes = cc1.Module.FS.readFile(`/tmp/${baseNoExt}.s`);
  const asm = new TextDecoder().decode(asmBytes);

  // 2. as — .s → ELF .o
  log("[2/4] as.wasm   (.s -> .o)");
  const asFetchStart = performance.now();
  const as = await loadTool("as.mjs", null);
  t.asFetch = performance.now() - asFetchStart;
  as.Module.FS.writeFile(`/tmp/${baseNoExt}.s`, asmBytes);
  const asStart = performance.now();
  const asRc = callMain(as, [
    "-march=68020",
    `/tmp/${baseNoExt}.s`,
    "-o", `/tmp/${baseNoExt}.o`,
  ]);
  t.asRun = performance.now() - asStart;
  log(`      as rc=${asRc} — fetch+init ${fmt(t.asFetch)}, assemble ${fmt(t.asRun)}`);
  if (as.stderr.length) as.stderr.forEach((l) => log("      " + l, "warn"));
  if (asRc !== 0) {
    log(`compile failed at stage 2 (as)`, "err");
    return { ok: false, asm };
  }
  const oBytes = as.Module.FS.readFile(`/tmp/${baseNoExt}.o`);

  // 3. ld — link with Retro68 sysroot (libretrocrt + libInterface + libc
  //    + libm + libgcc) using the multi-segment ld script.
  log("[3/4] ld.wasm   (.o -> ELF executable) — fetching libs…");
  const ldFetchStart = performance.now();
  const ld = await loadTool("ld.mjs", "libs");
  t.ldFetch = performance.now() - ldFetchStart;
  ld.Module.FS.writeFile(`/tmp/${baseNoExt}.o`, oBytes);
  const ldStart = performance.now();
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
  t.ldRun = performance.now() - ldStart;
  log(`      ld rc=${ldRc} — fetch+init ${fmt(t.ldFetch)}, link ${fmt(t.ldRun)}`);
  if (ld.stderr.length) ld.stderr.forEach((l) => log("      " + l, "warn"));
  if (ldRc !== 0) {
    log(`compile failed at stage 3 (ld)`, "err");
    return { ok: false, asm };
  }
  const elfBytes = ld.Module.FS.readFile("/tmp/out.gdb");

  // 4. Elf2Mac — ELF → single-fork MacBinary II APPL
  log("[4/4] Elf2Mac.wasm (ELF -> MacBinary II)");
  const e2mFetchStart = performance.now();
  const e2m = await loadTool("Elf2Mac.mjs", null);
  t.e2mFetch = performance.now() - e2mFetchStart;
  e2m.Module.FS.writeFile("/tmp/out.bin.gdb", elfBytes);
  const e2mStart = performance.now();
  const e2mRc = callMain(e2m, ["--elf2mac", "-o", "/tmp/out.bin"]);
  t.e2mRun = performance.now() - e2mStart;
  log(`      Elf2Mac rc=${e2mRc} — fetch+init ${fmt(t.e2mFetch)}, convert ${fmt(t.e2mRun)}`);
  if (e2m.stderr.length) e2m.stderr.forEach((l) => log("      " + l, "warn"));
  if (e2mRc !== 0) {
    log(`compile failed at stage 4 (Elf2Mac)`, "err");
    return { ok: false, asm };
  }
  const bin = e2m.Module.FS.readFile("/tmp/out.bin");

  // Summary: where did the time actually go?
  const total = performance.now() - t0;
  const fetchTotal =
    t.cc1Fetch + t.asFetch + t.ldFetch + t.e2mFetch;
  const runTotal =
    t.cc1Run + t.asRun + t.ldRun + t.e2mRun;
  const fetchPct = Math.round((fetchTotal / total) * 100);
  log(``);
  log(
    `done in ${fmt(total)} — ${bin.length}-byte MacBinary II`,
    "ok",
  );
  log(
    `  breakdown: ${fmt(fetchTotal)} fetching wasm + sysroot ` +
      `(${fetchPct}%), ${fmt(runTotal)} actually compiling ` +
      `(${100 - fetchPct}%)`,
  );
  if (!isWarm) {
    log(
      `  cold tab: cc1.wasm is ~3.3 MB brotli, sysroot.bin ~190 KB ` +
        `brotli, libs blob ~1 MB brotli. Once cached the next compile ` +
        `skips the network and runs in the "actually compiling" time only.`,
    );
  } else {
    log(
      `  warm tab: wasm + sysroot served from the browser HTTP cache ` +
        `— the remaining "fetch+init" time is Emscripten Module ` +
        `instantiation + the FS mounts (~200 file writes).`,
    );
  }
  return { ok: true, asm, bin };
}
