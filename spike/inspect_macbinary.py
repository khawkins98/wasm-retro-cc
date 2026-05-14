#!/usr/bin/env python3
"""
spike/inspect_macbinary.py — structural inspector for MacBinary II files.

Beyond the basic "type == APPL, rsrc fork > 0" check in run-spike.sh, this
parses the resource fork and surfaces the fields that matter for whether
libretrocrt can actually launch the binary on a real Mac (or BasiliskII):

  * CODE 0  — must have below_a5 > 0 (or libretrocrt's QuickDraw globals
              and other below-A5 statics land in unallocated memory and
              crash with type 3 on the first Toolbox call after InitGraf).
  * DATA 0  — must exist if the program references initialised globals
              (libretrocrt does).
  * RELA n  — must exist for multi-segment apps so that Retro68Relocate
              can fix up absolute addresses at load time.

Exit code:
  0  — all required-for-launch checks pass
  1  — missing or malformed required structure
  2  — usage / I/O error

Invoked as:  python3 spike/inspect_macbinary.py <path-to-macbinary>

This replaces the earlier inline-heredoc verification.  The check fires on
every CI run; it would have caught the --mac-single regression that put us
through a wasted "BasiliskII swap" investigation in 2026-05-14.
"""
import struct
import sys


def parse_macbinary(path: str) -> dict:
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 128:
        raise ValueError(f"{path} is {len(data)} bytes — too small for MacBinary header")
    name_len = data[1]
    name = data[2 : 2 + name_len].decode("mac_roman", errors="replace")
    ftype = data[65:69]
    creator = data[69:73]
    dlen = struct.unpack(">I", data[83:87])[0]
    rlen = struct.unpack(">I", data[87:91])[0]
    rstart = 128 + ((dlen + 127) // 128) * 128
    rsrc = data[rstart : rstart + rlen]
    return {
        "name": name,
        "type": ftype,
        "creator": creator,
        "data_fork_len": dlen,
        "rsrc_fork_len": rlen,
        "rsrc": rsrc,
    }


def parse_rsrc(rsrc: bytes) -> dict:
    if len(rsrc) < 16:
        raise ValueError("resource fork too short for header")
    data_off = struct.unpack(">I", rsrc[0:4])[0]
    map_off = struct.unpack(">I", rsrc[4:8])[0]
    data_len = struct.unpack(">I", rsrc[8:12])[0]
    map_len = struct.unpack(">I", rsrc[12:16])[0]
    m = rsrc[map_off : map_off + map_len]
    tl_off = struct.unpack(">H", m[24:26])[0]
    n_types = struct.unpack(">H", m[tl_off : tl_off + 2])[0] + 1
    types = {}
    for i in range(n_types):
        e = tl_off + 2 + i * 8
        t = m[e : e + 4].decode("latin-1")
        n = struct.unpack(">H", m[e + 4 : e + 6])[0] + 1
        rl_off = struct.unpack(">H", m[e + 6 : e + 8])[0]
        items = []
        for j in range(n):
            ro = tl_off + rl_off + j * 12
            rid = struct.unpack(">h", m[ro : ro + 2])[0]
            d_off = struct.unpack(">I", m[ro + 4 : ro + 8])[0] & 0xFFFFFF
            res_start = data_off + d_off
            sz = struct.unpack(">I", rsrc[res_start : res_start + 4])[0]
            body = rsrc[res_start + 4 : res_start + 4 + sz]
            items.append({"id": rid, "size": sz, "bytes": body})
        types[t] = items
    return {
        "data_off": data_off,
        "map_off": map_off,
        "data_len": data_len,
        "map_len": map_len,
        "types": types,
    }


def parse_code_0(c0: bytes) -> dict:
    if len(c0) < 16:
        raise ValueError(f"CODE 0 is {len(c0)} bytes; expected at least 16")
    return {
        "above_a5": struct.unpack(">I", c0[0:4])[0],
        "below_a5": struct.unpack(">I", c0[4:8])[0],
        "jt_size": struct.unpack(">I", c0[8:12])[0],
        "jt_a5_offset": struct.unpack(">I", c0[12:16])[0],
        "n_jt_entries": (len(c0) - 16) // 8,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: inspect_macbinary.py <path>", file=sys.stderr)
        return 2

    try:
        mb = parse_macbinary(argv[1])
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2

    failures = []

    print(f"  name        = {mb['name']!r}")
    print(f"  type        = {mb['type']!r}")
    print(f"  creator     = {mb['creator']!r}")
    print(f"  data fork   = {mb['data_fork_len']} bytes")
    print(f"  rsrc fork   = {mb['rsrc_fork_len']} bytes")

    if mb["type"] != b"APPL":
        failures.append(f"file type is {mb['type']!r}, expected b'APPL'")

    try:
        r = parse_rsrc(mb["rsrc"])
    except Exception as exc:
        print(f"FAIL: could not parse resource fork: {exc}", file=sys.stderr)
        return 1

    type_summary = ", ".join(
        f"{t}×{len(items)}" for t, items in sorted(r["types"].items())
    )
    print(f"  rsrc types  = {type_summary}")

    code = r["types"].get("CODE", [])
    if not code:
        failures.append("no CODE resources")
    else:
        c0 = next((c for c in code if c["id"] == 0), None)
        c1 = next((c for c in code if c["id"] == 1), None)
        if c0 is None:
            failures.append("missing CODE 0 (jump table)")
        if c1 is None:
            failures.append("missing CODE 1 (main code segment)")
        if c0 is not None:
            try:
                h = parse_code_0(c0["bytes"])
            except Exception as exc:
                failures.append(f"CODE 0 malformed: {exc}")
            else:
                print(
                    f"  CODE 0      = above_a5={h['above_a5']} below_a5={h['below_a5']} "
                    f"jt_size={h['jt_size']} jt_a5_off=0x{h['jt_a5_offset']:x} "
                    f"jt_entries={h['n_jt_entries']}"
                )
                # below_a5 must be > 0 for libretrocrt's globals (qd, etc.)
                # to have allocated space.  This is the check that would have
                # caught the --mac-single bug.
                if h["below_a5"] == 0:
                    failures.append(
                        "CODE 0 below_a5 = 0 — Process Manager will not allocate "
                        "space for libretrocrt's below-A5 globals (qd, etc.).  This "
                        "is the --mac-single failure mode."
                    )

    if "DATA" not in r["types"]:
        failures.append(
            "no DATA resource — libretrocrt expects initialised globals to be "
            "copied from a DATA resource at startup (multi-segment mode emits one)"
        )

    if "RELA" not in r["types"]:
        failures.append(
            "no RELA resource — Retro68Relocate's multi-segment branch needs "
            "relocation tables (one per CODE segment) to fix absolute addresses"
        )

    if failures:
        print()
        print("STRUCTURAL CHECK FAILED:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print()
    print("STRUCTURAL CHECK PASSED (APPL, CODE 0+1, below_a5>0, DATA, RELA)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
