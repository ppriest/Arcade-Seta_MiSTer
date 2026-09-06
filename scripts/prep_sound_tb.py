#!/usr/bin/env python3
"""Extract a game's sound ROMs for sim/fg2_sound_tb.

    python scripts/prep_sound_tb.py            # gogomile (default)
    python scripts/prep_sound_tb.py pbancho

Writes sim/fg2_sound_tb/z80.hex (the 128 KB Z80 program) and oki.hex (the
sample ROM, padded to 1 MB so the bench's OKI model always has a byte to
serve), one byte per line for $readmemh, straight out of roms/<set>.zip.
Both land under sim/**/*.hex, which
is gitignored: the ROMs are never committed.

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs sim/ sound testbench, and the X1-010 rather than Z80+OKI, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SETS = {
    "gogomile": ("fs1.rom24", "lh538n1d.rom25"),
    "pbancho":  ("no4.rom23", "n03.rom25"),
}

def main():
    game = sys.argv[1] if len(sys.argv) > 1 else "gogomile"
    if game not in SETS:
        sys.exit(f"unknown set {game!r}; known: {', '.join(SETS)}")
    z80_name, oki_name = SETS[game]
    out = REPO / "sim" / "fg2_sound_tb"
    out.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(REPO / "roms" / f"{game}.zip") as zf:
        z80 = zf.read(z80_name)
        oki = zf.read(oki_name)
    if len(z80) != 0x20000:
        sys.exit(f"{z80_name}: {len(z80)} bytes, expected 0x20000")
    oki = oki.ljust(0x100000, b"\xff")
    # One byte per line, for $readmemh.
    (out / "z80.hex").write_text("\n".join(f"{b:02x}" for b in z80) + "\n")
    (out / "oki.hex").write_text("\n".join(f"{b:02x}" for b in oki) + "\n")
    print(f"{game}: {z80_name} -> {out / 'z80.hex'} ({len(z80)} bytes), "
          f"{oki_name} -> {out / 'oki.hex'} ({len(oki)} bytes)")

if __name__ == "__main__":
    main()
