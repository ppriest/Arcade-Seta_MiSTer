#!/usr/bin/env python3
"""Check one granule the running core reported against the ROM it should hold.

    python scripts/check_granule.py daioh 0x01A2C4 0x1234FFFF0000ABCD

The core's instance-B probe reports the granule ADDRESS layer 0 asked for and
the 64 bits that came back (scripts/read_issp.tcl, fields_B). A granule is
8 bytes, so the byte offset into "gfx2" is address * 8.

WHY THIS EXISTS
    x1_012_tb proves the tilemap engine against a hex ROM, and seta_video_tb
    does the same. Neither instantiates the SDRAM or the arbiter, so the path
    from the engine through the 3-client arbiter to the chip is verified
    nowhere -- and it is the only difference between the passing simulations
    and the failing hardware.

    Equal means SDRAM holds the right bytes at the right place and the fault is
    in the engine. Different means the download or the arbiter put the wrong
    bytes there, and the shape of the difference says which: the ROM's own
    bytes found at another offset points at addressing, another region's bytes
    point at the arbiter handing a granule to the wrong client.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_region import region_image, load_blocks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("addr", help="granule address from the probe (hex ok)")
    ap.add_argument("data", help="the 64 bits it returned (hex)")
    ap.add_argument("--region", default="gfx2")
    a = ap.parse_args()

    gran = int(a.addr, 0)
    got = int(a.data, 16) & ((1 << 64) - 1)
    off = gran * 8

    blocks = load_blocks()
    img = region_image(a.game, a.region, blocks)[0]
    if off + 8 > len(img):
        sys.exit(f"granule {gran:#x} is byte {off:#x}, past {a.region}'s "
                 f"{len(img):#x} bytes -- the engine asked outside the region")

    # sdram.sv answers a granule as four 16-bit words, word 0 in the LOW bits,
    # and a word there is {odd byte, even byte}. So the granule as an integer is
    # the eight bytes little-endian.
    want = int.from_bytes(img[off:off + 8], "little")

    print(f"{a.game}/{a.region} granule {gran:#x} = byte {off:#x}")
    print(f"  expected  {want:016x}")
    print(f"  got       {got:016x}")
    if got == want:
        print("  MATCH -- SDRAM holds the right bytes; the fault is in the engine")
        return 0

    print("  DIFFERENT")
    # Where else in this region do these bytes live? That distinguishes a
    # wrong address from wrong data.
    needle = got.to_bytes(8, "little")
    at = img.find(needle)
    if at >= 0 and needle != b"\x00" * 8:
        print(f"  those bytes DO appear in {a.region} at byte {at:#x} "
              f"(granule {at // 8:#x}) -- an addressing fault, off by "
              f"{at - off:+#x} bytes")
    elif needle == b"\x00" * 8:
        print("  all zero -- nothing was written there, or the wrong region "
              "was read")
    else:
        print(f"  those bytes are not in {a.region} at all -- check gfx1/gfx3, "
              "which would mean the arbiter served another client's granule")
    return 1


if __name__ == "__main__":
    sys.exit(main())
