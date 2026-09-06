#!/usr/bin/env python3
"""Build sim/maincpu_tb's fixtures: a program image and an expected fetch list.

    python scripts/mame_capture.py thunderl --boot-trace 400 --name bt/thunderl
    python scripts/prep_maincpu_tb.py thunderl debug/bt/thunderl/thunderl_boot.trace

Writes into sim/maincpu_tb/ (gitignored -- ROM-derived):

    rom.hex        the program image, one 16-bit word per line
    expect.hex     the reads MAME's CPU made from the program region, as
                   addr/data pairs, in order
    fixture.txt    which set these came from, so a stale pair cannot be
                   mistaken for a fresh one

BYTE ORDER, AND WHY rom.hex IS NOT SIMPLY THE IMAGE
---------------------------------------------------
The RTL fetches through sdram_narrow_bridge, which packs the EVEN byte address
in the LOW half of each 16-bit lane -- little-endian, and correct for regions
that genuinely are. The 68000 is big-endian: the word at address A has its high
byte AT A. maincpu.sv therefore swaps at the seam (ROM_BYTESWAP), and this file
writes rom.hex the way the bridge would present it, so the bench exercises that
swap rather than bypassing it.

Get this backwards and the CPU reads byte-swapped opcodes, which on Psikyo
looked like a corrupt stack pointer and cost a rewritten loader that turned out
to be inert. The check is cheap: the first expected fetch is the reset SP's high
word, and it is in the trace.
"""
import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("trace")
    ap.add_argument("--zip")
    ap.add_argument("--out", default=None,
                    help="output directory (default sim/maincpu_tb)")
    ap.add_argument("--max-words", type=int, default=1 << 20,
                    help="cap on rom.hex length, to keep elaboration quick. "
                         "The bench's ROM is this many words; a fetch past it "
                         "is reported rather than wrapped")
    a = ap.parse_args()

    bm = _load("build_maincpu_hex", HERE / "build_maincpu_hex.py")
    if a.set not in bm.SETS:
        sys.exit(f"no ROM_START records for '{a.set}'")

    zippath = a.zip
    if not zippath:
        import zipfile
        for z in sorted((HERE.parent / "roms").glob("*.zip")):
            if z.stem == a.set or any(
                    n.startswith(a.set + "/")
                    for n in zipfile.ZipFile(z).namelist()):
                zippath = str(z)
                break
        if not zippath:
            sys.exit(f"no archive holds set '{a.set}'")

    img = bm.build(zippath, bm.SETS[a.set], a.set)
    out = Path(a.out) if a.out else (HERE.parent / "sim" / "maincpu_tb")
    out.mkdir(parents=True, exist_ok=True)

    # rom.hex -- as sdram_narrow_bridge would present it (even byte low).
    nwords = min(a.max_words, len(img) // 2)
    with open(out / "rom.hex", "w", newline="\n") as f:
        for w in range(nwords):
            lo, hi = img[2 * w], img[2 * w + 1]      # big-endian in the image
            f.write(f"{hi:02x}{lo:02x}\n")           # bridge packing: even byte low

    # rom_bytes.hex -- the RAW image, one byte per line in ascending address
    # order, which is what hps_io's ioctl stream delivers.
    # sim/maincpu_sdram_tb feeds this through the real sdram_download path,
    # so the byte order is exercised rather than asserted: sdram_download
    # pairs an even byte into the LOW half and the odd byte into the HIGH
    # half, sdram_narrow_bridge hands that word back unchanged, and
    # maincpu.sv's ROM_BYTESWAP turns it into the big-endian word a 68000
    # expects. Three conventions in a row, and the only honest way to know
    # they compose is to run them.
    with open(out / "rom_bytes.hex", "w", newline=chr(10)) as f:
        for b in img[:nwords * 2]:
            f.write("%02x" % b + chr(10))

    # expect.hex -- MAME's reads from inside the program image, in order.
    rows = [l.rstrip("\n").split("\t")
            for l in open(a.trace, encoding="utf8")
            if l.strip() and not l.startswith("#")]
    #
    # CONSECUTIVE DUPLICATE READS ARE COLLAPSED, on this side and in the bench.
    #
    # TG68K.C and MAME's 68000 do not prefetch identically, and the difference
    # runs BOTH ways: after the reset vectors the RTL reads 0x000008, which MAME
    # never does, and MAME reads 0x00013E twice in a row, which the RTL does
    # once. So neither access stream is a subsequence of the other, and a
    # matcher that skips only on one side wedges on the first duplicate -- which
    # is what the first version of this bench reported as "the CPU stalled",
    # while a verbose dump showed it executing happily 400 accesses deep.
    #
    # Collapsing a read that repeats the immediately preceding address AND data
    # costs nothing: it carries no information about whether the two cores agree
    # on what is at that address. What remains is a fair question -- did the CPU
    # fetch the same words, in the same order -- between two cores that are
    # cycle-different by design (TG68K's own README: "does not value cycle
    # accuracy").
    exp = []
    for _seq, rw, addr, data in rows:
        ai = int(addr, 16)
        if rw == "r" and ai + 1 < len(img) and ai < nwords * 2:
            pair = (ai, int(data, 16))
            if exp and exp[-1] == pair:
                continue
            exp.append(pair)
    if not exp:
        sys.exit("no comparable reads in the trace -- wrong set?")

    # Sanity: the first four must be the reset vectors, or the trace is not
    # from a reset.
    if [e[0] for e in exp[:4]] != [0, 2, 4, 6]:
        print(f"WARNING: the trace does not start with the reset vectors "
              f"(first addresses {[hex(e[0]) for e in exp[:4]]}) -- it may not "
              f"begin at reset", file=sys.stderr)

    with open(out / "expect.hex", "w", newline="\n") as f:
        for ai, d in exp:
            f.write(f"{ai >> 1:06x}{d:04x}\n")       # word address, then data

    (out / "fixture.txt").write_text(
        f"set     {a.set}\n"
        f"zip     {zippath}\n"
        f"trace   {a.trace}\n"
        f"image   {len(img)} bytes, {nwords} words written\n"
        f"expect  {len(exp)} reads\n", encoding="utf8")

    sp = int.from_bytes(img[0:4], "big")
    pc = int.from_bytes(img[4:8], "big")
    print(f"{out}:")
    print(f"  rom.hex     {nwords} words ({nwords*2} bytes of {len(img)})")
    print(f"  rom_bytes.hex {nwords*2} bytes, for the real download path")
    print(f"  expect.hex  {len(exp)} reads")
    print(f"  reset SP {sp:#010x}  PC {pc:#010x}")


if __name__ == "__main__":
    main()
