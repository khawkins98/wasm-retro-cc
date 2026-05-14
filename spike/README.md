# spike/ — Phase 2 derisk artefacts

> Phase 1 (PCC) lives under [`../spike-pcc/`](../spike-pcc/), archived
> with its own [`ARCHIVE.md`](../spike-pcc/ARCHIVE.md). This directory
> is where Phase 2 (Retro68 GCC → WASM) work lands. See
> [`../README.md`](../README.md) and tracker
> [#11](https://github.com/khawkins98/wasm-retro-cc/issues/11) for the
> phase rollup.

## Phase 2.0 — Retro68 GCC binary derisk (2026-05-14)

Smallest possible derisk before any Emscripten porting work: confirm
that a Retro68 GCC build of `hello_toolbox.c` (the same source the
Phase 1 PCC pipeline failed on) compiles cleanly, structurally matches
the reference shape produced by every booting Retro68 sample, and
plugs into classic-vibe-mac's playground without any patcher errors.

If this fails, Phase 2 is harder than expected and we revisit before
investing in the GCC port. If it succeeds, the remaining work is
purely the (known-bounded) Emscripten port — there's no question that
Retro68's compiler output runs on this BasiliskII.

### Files

- `hello_toolbox.c` — same C source as `spike-pcc/hello_toolbox.c` (the
  Phase 1 bisect probe), kept here so the Phase 2 build is
  self-contained and the two phases can stay independently
  reproducible.
- `build-retro68.sh` — Docker-driven build script. Pulls the pinned
  Retro68 image, runs CMake + `add_application`, and writes
  `build/hello-toolbox-retro68.bin` (+ a `.sha` provenance file). Pin
  matches `spike-pcc/run-spike.sh`'s `RETRO68_IMAGE`.

### Build locally

```bash
bash spike/build-retro68.sh           # writes spike/build/*.bin + .sha
bash spike/build-retro68.sh clean     # wipe spike/build/
```

Output is bit-identical with the CI artifact uploaded by
`.github/workflows/phase2.yml`, because both run the same script
against the same image digest.

### Phase 2.0 outcome

The produced binary:
- **Structurally passes** `inspect_macbinary.py` (APPL, CODE 0 + 8×
  CODE + DATA + 9× RELA + SIZE, `below_a5 > 0`).
- **Patches cleanly** into classic-vibe-mac's HFS volume via the
  existing playground patcher — no parser errors, `[prebuilt-demo]`
  console line confirms the fetch + SHA match.
- **Behaves identically** to the known-good Phase 1 PCC reference
  binary in the boot-test harness (`tools/test-demo.sh`).

The end-to-end "watch DrawString render 'Hello, World!' on the
desktop" verification runs against the deployed playground after the
classic-vibe-mac vendoring PR lands (local preview build doesn't apply
`NO_STARTUP_ITEMS=1`, so MacWeather auto-launches and visually masks
the Apps disk; deployed Pages env has the cleaner boot).
