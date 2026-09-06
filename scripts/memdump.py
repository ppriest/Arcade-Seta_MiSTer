#!/usr/bin/env python3
"""Read any CPU-visible memory back from the running core over JTAG.

    python scripts/memdump.py vram 0 64            # 64 pages from page 0 -> debug/hw/dump/vram.bin
    python scripts/memdump.py sdram 0x1400 4       # SDRAM byte 0x280000.. (page = 512 bytes)
    python scripts/memdump.py sdram 0x1400 4 --compare sim/tilemap_tb/l0_gfx.bin
    python scripts/memdump.py vregs 0 1 --print

Regions (rtl/seta_core.sv, "MEMORY DUMP"): sdram (512-byte pages of the
64 MB), vram (64 pages), palette (32), spriteram (16, the live RAM), vregs (1:
words 0-15 registers, 16-17 unknown, 18 priority, 19-20 the sprite tile bank), workram (256),
linecap (4: the per-line display record, four words per line -- layers 0-2 at
x=160 as {opaque, 2'b0, palette index} and sprites as {any, 6'b0, first opaque x}).

The core must be running with the trace overlay on and source 3 (the walker)
selected: `cfg.py <game> --set overlay=1 src=3 ring=0` before the launch. The
walker pauses the CPU while it runs, so the game freezes for the dump and
resumes afterwards. Each page is one 256-word walk re-armed over JTAG source
bit 6 and read back through the banded screenshot readout; that is about 40 s
per page, so ask for what you need.

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs the memory-dump walker and probe in rtl/seta_core.sv, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import argparse
import struct
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from tracer_readout import read_buffer, issp   # noqa: E402

OUT = REPO / "debug" / "hw" / "dump"
REGION = {"sdram": 0, "vram": 1, "palette": 2, "spriteram": 3, "vregs": 4, "workram": 5,
          "linecap": 6}
PAGES = {"sdram": 1 << 17, "vram": 64, "palette": 32, "spriteram": 16, "vregs": 1, "workram": 256,
         "linecap": 4}


def dump_page(region, page, tag, low=0):
    high = (REGION[region] << 20) | page
    # re-arm the walker: bit 6 toggles; hold the {region, page} in [31:8]
    # and any held control bits (0x20 = CPU pause) in [7:0]
    issp("set", (high << 8) | 0x40 | low); time.sleep(0.5)
    issp("set", (high << 8) | 0x00 | low); time.sleep(1.5)
    ents, probs = read_buffer(tag=tag, src_high=high, low_or=low)
    words = [None] * 256
    bad = 0
    for pos, v in enumerate(ents):
        if v is None:
            continue
        if (v >> 16) != pos:
            bad += 1; continue
        words[pos] = v & 0xFFFF
    return words, probs, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("region", choices=list(REGION))
    ap.add_argument("page", type=lambda s: int(s, 0))
    ap.add_argument("count", type=int, nargs="?", default=1)
    ap.add_argument("--out", help="output .bin (default debug/hw/dump/<region>_<page>.bin)")
    ap.add_argument("--compare", help="a file holding the expected bytes (offset = page*512 - file-base into it)")
    ap.add_argument("--file-base", type=lambda s: int(s, 0), default=0,
                    help="SDRAM byte address at which --compare's file starts (e.g. 0x1480000 for the FG-3 sprite image)")
    ap.add_argument("--print", action="store_true", help="hex-dump the words")
    ap.add_argument("--live", action="store_true",
                    help="dump a game that is running with the overlay OFF: JTAG source bit 1 forces the "
                         "overlay on and the walker selected (CPU paused) for the dump, then releases")
    ap.add_argument("--pause", action="store_true",
                    help="hold the CPU paused (JTAG source bit 5) for the whole dump, so every page "
                         "is from one instant; the game stays paused afterwards until `read_issp.tcl set 0`")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if a.page + a.count > PAGES[a.region]:
        sys.exit(f"{a.region} has {PAGES[a.region]} pages")
    exp = Path(a.compare).read_bytes() if a.compare else None
    out = Path(a.out) if a.out else OUT / f"{a.region}_{a.page:x}.bin"
    blob = bytearray()
    total_bad = 0
    for pg in range(a.page, a.page + a.count):
        t0 = time.time()
        words, probs, bad = dump_page(a.region, pg, tag=f"dump_{a.region}_{pg:x}",
                                      low=(0x20 if a.pause else 0) | (0x02 if a.live else 0))
        missing = sum(w is None for w in words)
        line = f"page {pg:#x}: {256 - missing}/256 words, {bad} misindexed, {len(probs)} readout problems, {time.time()-t0:.0f}s"
        if exp is not None:
            off = pg * 512 - a.file_base
            want = [struct.unpack(">H", exp[off + 2*i: off + 2*i + 2])[0] if 0 <= off and off + 2*i + 2 <= len(exp) else None
                    for i in range(256)]
            diff = [i for i in range(256) if words[i] is not None and want[i] is not None and words[i] != want[i]]
            line += f", {len(diff)} differ from the expected image"
            for i in diff[:4]:
                line += f"\n    word {i:3d}: got {words[i]:04X} expected {want[i]:04X}"
        print(line)
        for pr in probs[:3]:
            print("    ", pr)
        if a.print:
            for i in range(0, 256, 16):
                print(f"  {pg*512 + 2*i:06X}: " + " ".join("----" if w is None else f"{w:04X}" for w in words[i:i+16]))
        for w in words:
            blob += struct.pack(">H", 0 if w is None else w)
        total_bad += missing + bad
    if a.live and not a.pause:
        issp("set", 0)          # release: overlay off, walker off, CPU resumes
    out.write_bytes(blob)
    print(f"wrote {out} ({len(blob)} bytes){'; INCOMPLETE' if total_bad else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
