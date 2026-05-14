# `spike-pcc/` — archived Phase 1 PCC pipeline

**Status:** archived 2026-05-14. Not actively maintained. Kept for
reproducibility and as a paper trail.

This directory holds the **Phase 1** spike: a Portable C Compiler (PCC)
m68k backend producing classic Mac OS MacBinary II binaries via Retro68's
`Elf2Mac` linker. The pipeline worked structurally — output passes every
`inspect_macbinary.py` check and matches Retro68 reference binaries in
shape — but the linked binaries crash on Toolbox entry inside BasiliskII.
After three real bugs found and fixed and no successful boot, we pivoted
to the Retro68 GCC → WASM path in Phase 2.

For the strategic rationale see [`../LEARNINGS.md`](../LEARNINGS.md)
"Phase 2 pivot (2026-05-14)" and the cross-repo tracker
[khawkins98/classic-vibe-mac#64](https://github.com/khawkins98/classic-vibe-mac/issues/64).

## What's in here

| File | Purpose |
| --- | --- |
| `run-spike.sh` | End-to-end driver: setup → build PCC → compile → link → verify. Triggered manually via [`spike.yml`](../.github/workflows/spike.yml) (workflow_dispatch only). |
| `pcc.patch` | Patches to upstream PCC's m68k backend (`union flt → struct flt` fix; IEEE FP defines). Pinned to PCC SHA `05a6d54...`. |
| `mac.ld` | Minimal linker script for the Phase 0 bare-metal `_start`-only ELF. |
| `crt0_minimal.s` | Phase 0 standalone `_start` stub (predates libretrocrt linkage). |
| `inspect_macbinary.py` | Structural validator: asserts `below_a5 > 0`, CODE 0+1 present, DATA + RELA resources exist. Catches the `--mac-single` regression. |
| `include/` | Hand-written shim headers for classic Mac Toolbox types. `Quickdraw.h` uses `#pragma pack(2)` to match libretrocrt's mac68k layout (PR #6). |
| `stubs/libtoolbox-stubs.s` | Hand-written m68k A-trap stubs (`InitGraf`, `InitWindows`, `MoveTo`, `DrawString`, `MaxApplZone`, etc.). `MoveTo` + `FlushEvents` handle PCC's 4-byte short-arg slots (PR #7). |
| `hello.c` | Phase 0 probe: integer math, no Toolbox. Launches cleanly. |
| `hello_toolbox.c` | Phase 2 probe: full Toolbox init + DrawString + Button loop. **Crashes** on emulator. |
| `hello_initgraf.c` | Bisect probe: just `InitGraf(&qd.thePort); return 0;`. Crashes. |
| `hello_initgraf_local.c` | H1 probe: `InitGraf(&local)` with stack-allocated `GrafPtr`. Crashes — H1 dead. |
| `hello_initgraf_zone.c` | H2 probe: `MaxApplZone(); MoreMasters()×3; InitGraf(...)`. Crashes — H2 dead. |

## Bugs fixed during the bisect

Three real bugs were discovered and fixed in the PCC pipeline before we
gave up. They're documented in detail in `LEARNINGS.md`:

| # | Bug | Fix |
| --- | --- | --- |
| 1 | `Elf2Mac --mac-single` produced binaries with `below_a5=0`, no DATA, no RELA. | PR #5: use `m68k-apple-macos-ld -elf2mac` symlink (argv[0] dispatch enables multi-segment mode). |
| 2 | PCC's default struct alignment placed `qd.thePort` at offset 204; libretrocrt expects mac68k packing → offset 202. | PR #6: `#pragma pack(push, 2)` around `QDGlobals` in `include/Quickdraw.h`. |
| 3 | `MoveTo` and `FlushEvents` stubs read 2-byte short args from PCC's 4-byte slots — wrong half of each slot. | PR #7: read low word of each 4-byte slot in `stubs/libtoolbox-stubs.s`. |

Each fix was verified at the appropriate level (structural inspector,
readelf, on-emulator test). Each made the failure mode shift but did not
fix the final symptom: any single Toolbox call still crashes.

## Why we stopped

The remaining bug pattern is **"any Toolbox call from any
PCC + libretrocrt + libtoolbox-stubs binary crashes the system, even
ones that previously worked from system apps in the same boot."** That's
not a bug at a specific Toolbox call — it's something earlier
(libretrocrt startup, A5-world setup, relocation, or trap dispatch) that
destabilises the running system. We have no clear next bisect step that
isn't "rewrite libretrocrt by hand" or "rebuild PCC's m68k codegen from
scratch."

The structural argument also weighs against further investment in PCC:
its m68k backend is rare in production use, so the population of bugs we
might still hit is unknown and unbounded. The Retro68 GCC path, by
contrast, ships pre-built binaries that work in the same emulator — the
known-good output is several PRs' worth of de-risking ahead.

## How to reproduce

Manual only:

```bash
# from repo root, requires Docker for the Retro68 image
bash spike-pcc/run-spike.sh setup       # one-time
bash spike-pcc/run-spike.sh all         # phases 0/1/2 end-to-end
```

Or trigger the **[archived] PCC m68k pipeline (manual)** workflow in GitHub
Actions via "Run workflow" → main.
