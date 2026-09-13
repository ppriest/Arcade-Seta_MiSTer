#!/usr/bin/env python3
"""Read the X1-001 sprite RAM out of a running Seta_stp build, as capture files.

    python scripts/dump_sprram.py qzkklogy debug/hw/sprram-bad
    python scripts/x1_001_model.py qzkklogy debug/hw/sprram-bad --png out.png

Pause the game on the frame of interest first (the readback pauses the CPU
too, and releases it when done). Writes <tag>_sprcode.bin (0x2000 words),
<tag>_sprylow.bin (0x300 words, byte in the low half) and <tag>_sprctrl.bin,
big-endian like scripts/mame_capture.py, so the models load them directly.
Copy a palette (and VRAM, for a layered render) from a MAME capture of the
same scene.
"""
import argparse
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from hwlock import jtag_session  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag")
    ap.add_argument("outdir")
    ap.add_argument("--all", action="store_true",
                    help="all 0x2000 code words; default is 0x0000-0x07ff and 0x1000-0x17ff")
    a = ap.parse_args()
    out = Path(a.outdir)
    out.mkdir(parents=True, exist_ok=True)
    raw = out / "sprram.txt"
    ranges = ["0", "8192"] if a.all else ["0", "2048", "4096", "2048"]
    with jtag_session("dump_sprram"):
        r = subprocess.run(["quartus_stp", "-t", "scripts/dump_sprram.tcl", str(raw), *ranges],
                           cwd=REPO, text=True, capture_output=True)
    if r.returncode or not raw.exists():
        sys.exit(r.stdout[-2000:] + r.stderr[-2000:])

    code = [0] * 0x2000
    ylow = [0] * 0x300
    ctrl = [0] * 4
    for line in raw.read_text().splitlines():
        i, v = line.split()
        i, v = int(i), int(v, 16)
        code[i] = v & 0xFFFF
        if i < 0x300:
            ylow[i] = (v >> 16) & 0xFF
        if i < 4:
            ctrl[i] = (v >> 24) & 0xFF
    (out / f"{a.tag}_sprcode.bin").write_bytes(struct.pack(">8192H", *code))
    (out / f"{a.tag}_sprylow.bin").write_bytes(struct.pack(">768H", *ylow))
    (out / f"{a.tag}_sprctrl.bin").write_bytes(struct.pack(">4H", *ctrl))
    print(f"spritectrl {' '.join(f'{c:02x}' for c in ctrl)} -> {out}")


if __name__ == "__main__":
    main()
