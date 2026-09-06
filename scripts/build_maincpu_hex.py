#!/usr/bin/env python3
"""Build a main-CPU ROM image (and ModelSim .hex) from a MAME ROM set.

    python scripts/build_maincpu_hex.py roms/thunderl.zip thunderl --check
    python scripts/build_maincpu_hex.py roms/gundhara.zip gundhara -o sim/maincpu_tb/rom.hex

The interleave is taken from each driver's ROM_START, not guessed. Every entry
below is transcribed from src/mame/seta/seta.cpp and mirrors MAME's own load
semantics; nothing here reasons about byte order.

LESSONS_LEARNED, "Prove the interleave against MAME's disassembly offline,
before building": run --check to score the reset vector and the first
instructions before trusting any of this. On the Psikyo core every interleave
DERIVED by reasoning was wrong and every one SCORED against disassembly was
right, in seconds, with no hardware.

seta.cpp uses three forms for the 68000 program, and they are not
interchangeable:

  load16_byte   the common case -- two ROMs, one at even addresses and one at
                odd, so big-endian word N = { even[N], odd[N] }.
  continue      jjsquawk and friends: the SECOND half of a ROM loads to a
                different destination offset. Written as ROM_CONTINUE in the
                driver and easy to miss, because the file size alone looks
                like a plain load of twice the length.
  load16_wswap  msgundam: ONE ROM already holding whole words, byte-swapped.
                No pairing at all.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from romset import RomSet

# name -> list of load records. GENERATED, do not hand-edit:
#     python scripts/extract_romstart.py --emit
# reads them out of seta.cpp's ROM_START blocks. Hand transcription across 43
# sets, four load forms, and offsets that differ by one between the even and
# odd ROM of a pair is exactly the work that produces a plausible wrong answer
# (LESSONS_LEARNED, "Prove the interleave ... offline, before building").
#   ("load16_byte",  file, dest, length)   dest & 1 selects the byte lane
#   ("load",         file, dest, length)   plain, byte for byte
#   ("load16_wswap", file, dest, length)   whole words, byte-swapped
#   ("continue",     None, dest, length)   the rest of the PREVIOUS file
SETS = {
    "thunderl": [
        ("load16_byte", "m4"                                  , 0x000000, 0x08000, 0x1e6b9462),
        ("load16_byte", "m5"                                  , 0x000001, 0x08000, 0x7e82793e),
    ],
    "thunderla": [
        ("load16_byte", "tl-1-1.u1"                           , 0x000000, 0x08000, 0x3d4b1888),
        ("load16_byte", "tl-1-2.u4"                           , 0x000001, 0x08000, 0x974dddda),
    ],
    "wits": [
        ("load16_byte", "un001001.u1"                         , 0x000000, 0x08000, 0x416c567e),
        ("load16_byte", "un001002.u4"                         , 0x000001, 0x08000, 0x497a3fa6),
    ],
    "blockcar": [
        ("load16_byte", "u1.a1"                               , 0x000000, 0x20000, 0x4313fb00),
        ("load16_byte", "u4.a3"                               , 0x000001, 0x20000, 0x2237196d),
    ],
    "umanclub": [
        ("load16_byte", "uw001006.u48"                        , 0x000000, 0x20000, 0x3dae1e9d),
        ("load16_byte", "uw001007.u49"                        , 0x000001, 0x20000, 0x5c21e702),
    ],
    "neobattl": [
        ("load16_byte", "bp923001.u45"                        , 0x000000, 0x20000, 0x0d0aeb73),
        ("load16_byte", "bp923002.u46"                        , 0x000001, 0x20000, 0x9731fbbc),
    ],
    "atehate": [
        ("load16_byte", "fs001001.evn"                        , 0x000000, 0x80000, 0x4af1f273),
        ("load16_byte", "fs001002.odd"                        , 0x000001, 0x80000, 0xc7ca7a85),
    ],
    "pairlove": [
        ("load16_byte", "ut2-001-001.1a"                      , 0x000000, 0x10000, 0x083338b7),
        ("load16_byte", "ut2-001-002.3a"                      , 0x000001, 0x10000, 0x39d88aae),
    ],
    "orbs": [
        ("load16_byte", "orbs.u10"                            , 0x000000, 0x80000, 0x10f079c8),
        ("load16_byte", "orbs.u9"                             , 0x000001, 0x80000, 0xf269d16f),
    ],
    "keroppi": [
        ("load16_byte", "keroppi jr. code =u10= v1.0.u10"     , 0x000000, 0x40000, 0x1fc2e895),
        ("load16_byte", "keroppi jr. code =u9= v1.0.u9"       , 0x000001, 0x40000, 0xe0599e7b),
    ],
    "keroppij": [
        ("load16_byte", "ft-001-001.u10"                      , 0x000000, 0x80000, 0x37861e7d),
        ("load16_byte", "ft-001-002.u9"                       , 0x000001, 0x80000, 0xf531d4ef),
    ],
    "krzybowl": [
        ("load16_byte", "fv001.002"                           , 0x000000, 0x40000, 0x8c03c75f),
        ("load16_byte", "fv001.001"                           , 0x000001, 0x40000, 0xf0630beb),
    ],
    "drgnunit": [
        ("load16_byte", "prg-e.bin"                           , 0x000000, 0x20000, 0x728447df),
        ("load16_byte", "prg-o.bin"                           , 0x000001, 0x20000, 0xb2f58ecf),
    ],
    "stg": [
        ("load16_byte", "att01003.u27"                        , 0x000000, 0x20000, 0x7a640a93),
        ("load16_byte", "att01001.u9"                         , 0x000001, 0x20000, 0x4fa88ad3),
        ("load16_byte", "att01004.u33"                        , 0x040000, 0x20000, 0xbbd45ca1),
        ("load16_byte", "att01002.u17"                        , 0x040001, 0x20000, 0x2f8fd80c),
    ],
    "qzkklogy": [
        ("load16_byte", "3.u27"                               , 0x000000, 0x20000, 0xb8c27cde),
        ("load16_byte", "1.u9"                                , 0x000001, 0x20000, 0xce01cd54),
        ("load16_byte", "4.u33"                               , 0x040000, 0x20000, 0x4f5c554c),
        ("load16_byte", "2.u17"                               , 0x040001, 0x20000, 0x65fa1b8d),
    ],
    "qzkklgy2": [
        ("load16_wswap", "fn001001.106"                        , 0x000000, 0x80000, 0x7bf8eb17),
        ("load16_wswap", "fn001003.107"                        , 0x080000, 0x40000, 0xee6ef111),
    ],
    "rezon": [
        ("load16_byte", "us001001.u3"                         , 0x000000, 0x20000, 0xab923052),
        ("load16_byte", "rezon_1_p.u4"                        , 0x000001, 0x20000, 0x9ed32f8c),
        ("load16_byte", "us001004.103"                        , 0x100000, 0x20000, 0x54871c7c),
        ("load16_byte", "us001003.102"                        , 0x100001, 0x20000, 0x1ac3d272),
    ],
    "rezono": [
        ("load16_byte", "us001001.u3"                         , 0x000000, 0x20000, 0xab923052),
        ("load16_byte", "us001002.u4"                         , 0x000001, 0x20000, 0x3dafa0d5),
        ("load16_byte", "us001004.103"                        , 0x100000, 0x20000, 0x54871c7c),
        ("load16_byte", "us001003.102"                        , 0x100001, 0x20000, 0x1ac3d272),
    ],
    "daioh": [
        ("load16_byte", "fg001001.u3"                         , 0x000000, 0x80000, 0xe1ef3007),
        ("load16_byte", "fg001002.u4"                         , 0x000001, 0x80000, 0x5e3481f9),
    ],
    "daioha": [
        ("load16_byte", "fg-001-001.u3"                       , 0x000000, 0x80000, 0x104ae74a),
        ("load16_byte", "fg-001-002.u4"                       , 0x000001, 0x80000, 0xe39a4e67),
    ],
    "daiohc": [
        ("load16_byte", "15.u3"                               , 0x000000, 0x40000, 0x14616abb),
        ("continue", None                                  , 0x100000, 0x40000, None),
        ("load16_byte", "14.u4"                               , 0x000001, 0x40000, 0xa029f991),
        ("continue", None                                  , 0x100001, 0x40000, None),
    ],
    "daiohp": [
        ("load16_byte", "prg_even.u3"                         , 0x000000, 0x40000, 0x3c97b976),
        ("load16_byte", "prg_odd.u4"                          , 0x000001, 0x40000, 0xaed2b87e),
        ("load16_byte", "data_even.u103"                      , 0x100000, 0x40000, 0xe07776ef),
        ("load16_byte", "data_odd.u102"                       , 0x100001, 0x40000, 0xb75b9a5c),
    ],
    "daiohp2": [
        ("load16_byte", "prg_even.u3"                         , 0x000000, 0x20000, 0x0079c08f),
        ("load16_byte", "prg_odd.u4"                          , 0x000001, 0x20000, 0xd2a843ad),
        ("load16_byte", "data_even.u103"                      , 0x100000, 0x40000, 0xa76139bb),
        ("load16_byte", "data_odd.u102"                       , 0x100001, 0x40000, 0x075c4b30),
    ],
    "msgundam": [
        ("load16_wswap", "fa003002.u25"                        , 0x000000, 0x80000, 0x1cc72d4c),
        ("load16_wswap", "fa001001.u20"                        , 0x100000, 0x100000, 0xfca139d0),
    ],
    "msgundam1": [
        ("load16_wswap", "fa002002.u25"                        , 0x000000, 0x80000, 0xdee3b083),
        ("load16_wswap", "fa001001.u20"                        , 0x100000, 0x100000, 0xfca139d0),
    ],
    "kamenrid": [
        ("load16_wswap", "fj001003.25"                         , 0x000000, 0x80000, 0x9b65d1b9),
    ],
    "eightfrc": [
        ("load16_byte", "uy2-u4.u3"                           , 0x000000, 0x40000, 0xf1f249c5),
        ("load16_byte", "uy2-u3.u4"                           , 0x000001, 0x40000, 0x6f2d8618),
    ],
    "oisipuzl": [
        ("load16_wswap", "ss1u200.v10"                         , 0x000000, 0x80000, 0xf5e53baf),
        ("load16_wswap", "ss1u201.v10"                         , 0x100000, 0x80000, 0x7a7ff5ae),
    ],
    "wrofaero": [
        ("load16_byte", "u3.bin"                              , 0x000000, 0x40000, 0x9b896a97),
        ("load16_byte", "u4.bin"                              , 0x000001, 0x40000, 0xdda84846),
    ],
    "magspeed": [
        ("load16_byte", "fu001002.201"                        , 0x000000, 0x40000, 0xbdeb3fcc),
        ("load16_byte", "fu001001.200"                        , 0x000001, 0x40000, 0x9b873d46),
    ],
    "zingzip": [
        ("load16_byte", "uy001001.3"                          , 0x000000, 0x40000, 0x1a1687ec),
        ("load16_byte", "uy001002.4"                          , 0x000001, 0x40000, 0x62e3b0c4),
    ],
    "extdwnhl": [
        ("load16_byte", "fw001002.201"                        , 0x000000, 0x80000, 0x24d21924),
        ("load16_byte", "fw001001.200"                        , 0x000001, 0x80000, 0xfb12a28b),
    ],
    "sokonuke": [
        ("load16_byte", "001-001.bin"                         , 0x000000, 0x80000, 0x9d0aa3ca),
        ("load16_byte", "001-002.bin"                         , 0x000001, 0x80000, 0x96f2ef5f),
    ],
    "gundhara": [
        ("load16_byte", "bpgh-003.u3"                         , 0x000000, 0x80000, 0x14e9970a),
        ("load16_byte", "bpgh-004.u4"                         , 0x000001, 0x80000, 0x96dfc658),
        ("load16_byte", "bpgh-002.103"                        , 0x100000, 0x80000, 0x312f58e2),
        ("load16_byte", "bpgh-001.102"                        , 0x100001, 0x80000, 0x8d23a23c),
    ],
    "gundharac": [
        ("load16_byte", "4.u3"                                , 0x000000, 0x80000, 0x14e9970a),
        ("load16_byte", "2.u4"                                , 0x000001, 0x80000, 0x96dfc658),
        ("load16_byte", "3.u103"                              , 0x100000, 0x80000, 0x312f58e2),
        ("load16_byte", "1.u102"                              , 0x100001, 0x80000, 0x8d23a23c),
    ],
    "jjsquawk": [
        ("load16_byte", "fe2002001.u3"                        , 0x000000, 0x40000, 0x7b9af960),
        ("continue", None                                  , 0x100000, 0x40000, None),
        ("load16_byte", "fe2002002.u4"                        , 0x000001, 0x40000, 0x47dd71a3),
        ("continue", None                                  , 0x100001, 0x40000, None),
    ],
    "jjsquawko": [
        ("load16_byte", "fe2001001.u3"                        , 0x000000, 0x40000, 0x921c9762),
        ("continue", None                                  , 0x100000, 0x40000, None),
        ("load16_byte", "fe2001002.u4"                        , 0x000001, 0x40000, 0x0227a2be),
        ("continue", None                                  , 0x100001, 0x40000, None),
    ],
    "madshark": [
        ("load16_byte", "fq001002.201"                        , 0x000000, 0x80000, 0x4286a811),
        ("load16_byte", "fq001001.200"                        , 0x000001, 0x80000, 0x38bfa0ad),
    ],
    "blandia": [
        ("load16_byte", "ux001001.u3"                         , 0x000000, 0x40000, 0x2376a1f3),
        ("load16_byte", "ux001002.u4"                         , 0x000001, 0x40000, 0xb915e172),
        ("load16_wswap", "ux001003.u202"                       , 0x100000, 0x100000, 0x98052c63),
    ],
    "blandiap": [
        ("load16_byte", "prg-even.bin"                        , 0x000000, 0x40000, 0x7ecd30e8),
        ("load16_byte", "prg-odd.bin"                         , 0x000001, 0x40000, 0x42b86c15),
        ("load16_byte", "tbl0.bin"                            , 0x100000, 0x80000, 0x69b79eb8),
        ("load16_byte", "tbl1.bin"                            , 0x100001, 0x80000, 0xcf2fd350),
    ],
    "zombraid": [
        ("load16_byte", "fy001003.3"                          , 0x000000, 0x80000, 0x0b34b8f7),
        ("load16_byte", "fy001004.4"                          , 0x000001, 0x80000, 0x71bfeb1a),
        ("load16_byte", "fy001002.103"                        , 0x100000, 0x80000, 0x313fd68f),
        ("load16_byte", "fy001001.102"                        , 0x100001, 0x80000, 0xa0f61f13),
    ],
    "zombraidp": [
        ("load16_byte", "u3_master_usa_prg_e_l_dd28.u3"       , 0x000000, 0x80000, 0x0b34b8f7),
        ("load16_byte", "u4_master_usa_prg_o_l_5e2b.u4"       , 0x000001, 0x80000, 0x71bfeb1a),
        ("load16_byte", "u103_master_usa_prg_e_h_789e.u103"   , 0x100000, 0x80000, 0x313fd68f),
        ("load16_byte", "u102_master_usa_prg_o_h_1f25.u102"   , 0x100001, 0x80000, 0xa0f61f13),
    ],
    "zombraidpj": [
        ("load16_byte", "u3_master_usa_prg_e_l_dd28.u3"       , 0x000000, 0x80000, 0x0b34b8f7),
        ("load16_byte", "u4_master_jpn_prg_o_l_5e2c.u4"       , 0x000001, 0x80000, 0x3cb6bdf0),
        ("load16_byte", "u103_master_usa_prg_e_h_789e.u103"   , 0x100000, 0x80000, 0x313fd68f),
        ("load16_byte", "u102_master_usa_prg_o_h_1f25.u102"   , 0x100001, 0x80000, 0xa0f61f13),
    ],
}


def build(zippath, records, setname):
    # RomSet, not a basename dict: roms/ is MERGED, and two of the archives
    # hold different dumps under the same basename in different clone
    # directories (daiohp vs daiohp2, jjsquawkb vs simpsonjr). See romset.py.
    rs = RomSet(zippath, setname)
    out = bytearray()

    def ensure(n):
        if len(out) < n:
            out.extend(b"\xff" * (n - len(out)))

    blob = None       # the file the last real load came from
    consumed = 0      # how much of it a previous record already took
    for rec in records:
        kind, fname, dest, length, crc = rec
        if kind == "continue":
            if blob is None:
                sys.exit("ROM_CONTINUE with no preceding load")
        else:
            try:
                blob = rs.read(fname, crc)
            except KeyError as e:
                sys.exit(str(e))
            consumed = 0
        chunk = blob[consumed:consumed + length]
        if len(chunk) != length:
            sys.exit(f"{fname or 'continuation'}: wanted {length:#x} bytes at "
                     f"{consumed:#x}, got {len(chunk):#x}")
        consumed += length

        if kind in ("load16_byte", "continue"):
            # dest & 1 selects even or odd byte lane; dest & ~1 is the base.
            base, lane = dest & ~1, dest & 1
            ensure(base + length * 2)
            out[base + lane: base + length * 2: 2] = chunk
        elif kind == "load":
            # Plain ROM_LOAD. No set in scope currently uses it for maincpu,
            # but extract_romstart.py can emit it, and a kind the extractor
            # produces that build() cannot consume is a latent trap.
            ensure(dest + length)
            out[dest:dest + length] = chunk
        elif kind == "load16_wswap":
            ensure(dest + length)
            swapped = bytearray(chunk)
            swapped[0::2], swapped[1::2] = chunk[1::2], chunk[0::2]
            out[dest:dest + length] = swapped
        else:
            sys.exit(f"unknown record kind {kind}")
    return bytes(out)


def check(img):
    """Score the image against what a 68000 must find at reset.

    A wrong interleave usually still produces a plausible-looking file, so the
    test is whether the two reset vectors are sane -- not whether the bytes
    look like code.
    """
    if len(img) < 8:
        return ["image is shorter than the reset vectors"]
    sp = int.from_bytes(img[0:4], "big")
    pc = int.from_bytes(img[4:8], "big")
    problems = []
    print(f"  reset SP  {sp:#010x}")
    print(f"  reset PC  {pc:#010x}")
    if pc & 1:
        problems.append(f"reset PC {pc:#x} is ODD -- a 68000 cannot fetch there; "
                        f"the even/odd lanes are almost certainly swapped")
    if pc >= len(img):
        problems.append(f"reset PC {pc:#x} is past the end of the {len(img):#x}-byte image")
    if sp & 1:
        problems.append(f"reset SP {sp:#x} is odd")
    if not problems:
        print(f"  first words at PC: " +
              " ".join(f"{int.from_bytes(img[pc+i:pc+i+2],'big'):04X}"
                       for i in range(0, 12, 2)))
        print("  vectors look sane -- now disassemble at that PC and compare "
              "against MAME before trusting the map")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("zip")
    ap.add_argument("set", choices=sorted(SETS))
    ap.add_argument("-o", "--out", help="write a $readmemh file (one 16-bit "
                                        "big-endian word per line)")
    ap.add_argument("--bin", help="also write the raw image")
    ap.add_argument("--check", action="store_true",
                    help="score the reset vectors and stop")
    a = ap.parse_args()

    img = build(a.zip, SETS[a.set], a.set)
    print(f"{a.set}: {len(img):#x} bytes ({len(img)/1024:.0f} KB)")
    problems = check(img)
    for p in problems:
        print("  PROBLEM: " + p)
    if problems:
        sys.exit(1)
    if a.check:
        return

    if a.bin:
        open(a.bin, "wb").write(img)
        print(f"  wrote {a.bin}")
    if a.out:
        with open(a.out, "w", newline="\n") as f:
            for i in range(0, len(img) - 1, 2):
                f.write(f"{img[i]:02x}{img[i+1]:02x}\n")
        print(f"  wrote {a.out} ({len(img)//2} words)")


if __name__ == "__main__":
    main()
