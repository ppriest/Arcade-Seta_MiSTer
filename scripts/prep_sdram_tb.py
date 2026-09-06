#!/usr/bin/env python3
"""Build sim/sdram_top_tb's fixtures: the three ROM regions of one real set.

    python scripts/prep_sdram_tb.py thunderl
    scripts/run_sim.sh sdram_top_tb           (from the repository root)

The bench streams these in through the ioctl port exactly as the HPS does,
then reads every region back through the port the core will actually use it
from -- and for the sprite region, checks that the download-time layout
permutation put a 16-pixel row where the engine expects to find it, as ONE
64-bit granule.

Each file holds 16-bit words in the region's NATURAL byte order (word k is
image[2k] << 8 | image[2k+1]), so the bench can stream the high byte then the
low one and reproduce the ascending byte order the HPS delivers. That is not
the order the data ends up in -- sdram_download pairs bytes {odd, even} with
the even byte in the LOW half -- and keeping the fixture natural is deliberate:
the byte order is then something the RTL does, and the bench can check it,
rather than something the fixture pre-arranged.
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from build_region import region_image

OUT = REPO / "sim" / "sdram_top_tb"

# Must match rtl/memory/seta_sdram_top.sv's LAYOUT_A.
LAYOUT_A = {
    "maincpu": (0x000000, 0x100000),
    "gfx1":    (0x100000, 0x200000),
    "x1snd":   (0x300000, 0x100000),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--out", default=str(OUT),
                    help="fixture directory (sim/seta_core_tb uses the same "
                         "files, so it takes the same generator)")
    a = ap.parse_args()
    out = Path(a.out)

    out.mkdir(parents=True, exist_ok=True)
    info = []
    for region, (base, reserved) in LAYOUT_A.items():
        img, size, zippath = region_image(a.game, region)
        if size > reserved:
            sys.exit(f"{a.game}/{region} is {size:#x} bytes but LAYOUT_A reserves "
                     f"{reserved:#x} -- the map in seta_sdram_top.sv is too small "
                     f"for this set")
        blob = bytearray(img)
        if len(blob) & 1:
            blob.append(0)
        (out / f"{region}.hex").write_text(
            "".join(f"{blob[2 * k] << 8 | blob[2 * k + 1]:04x}\n"
                    for k in range(len(blob) // 2)))
        info.append((region, base, size, zippath))
        print(f"  {region:8s} {size:#09x} bytes at {base:#09x}  ({zippath})")

    gfx_size = dict((r, s) for r, _, s, _ in info)["gfx1"]
    cfg = {
        "gfx_half_words": gfx_size // 4,
        "maincpu_bytes":  dict((r, s) for r, _, s, _ in info)["maincpu"],
        "gfx1_bytes":     gfx_size,
        "x1snd_bytes":    dict((r, s) for r, _, s, _ in info)["x1snd"],
    }
    order = ["gfx_half_words", "maincpu_bytes", "gfx1_bytes", "x1snd_bytes"]
    (out / "cfg.hex").write_text("".join(f"{cfg[k]:08x}\n" for k in order))
    (out / "fixture.txt").write_text(
        f"game {a.game}\n" +
        "".join(f"{r:8s} {s:#09x} at {b:#09x}  {z}\n" for r, b, s, z in info) +
        f"gfx_half_words {cfg['gfx_half_words']:#x}\n")
    print(f"  cfg: gfx_half_words {cfg['gfx_half_words']:#x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
