#!/usr/bin/env python3
"""Generate the `.mra` files, and prove each one byte-for-byte.

    python scripts/build_mra.py                # write releases/*.mra
    python scripts/build_mra.py --check        # verify only, write nothing
    python scripts/build_mra.py thunderl       # just these sets

HOW THIS AVOIDS THE CLASSIC .mra BUG
------------------------------------
docs/LESSONS_LEARNED.md is blunt: on the Psikyo core, *every* interleave that
was DERIVED by reasoning about byte order was wrong, and "it boots" is weak
evidence because a wrong map can boot far enough to look plausible. So nothing
here reasons about map digits. Instead:

  1. Each region's image is built DIRECTLY from the driver's ROM_START
     semantics -- the same records scripts/extract_romstart.py reads and
     scripts/build_region.py assembles, which is already checked against MAME's
     own CPU fetches for all 43 in-scope sets.
  2. Candidate `.mra` forms are then TRIED against it, and the one that
     reproduces the ground truth exactly is emitted. If none does, that is an
     error, not a guess.
  3. The finished `.mra` is re-read with scripts/mra.py and the whole assembled
     image compared byte-for-byte against the concatenation of the ground
     truths, padding included.

Step 3 is only meaningful because mra.py's map convention was checked against
mra-tools-c itself rather than against this file -- see its `pattern_from_map()`
and `--selftest`. Two implementations sharing one wrong assumption would agree
with each other and still be wrong on hardware.

WHAT IS DERIVED, AND FROM WHERE
-------------------------------
Nothing below is transcribed by hand except the folder layout:

    region records   scripts/extract_romstart.py, from ROM_START
    address map      rtl/memory/seta_sdram_top.sv -- the RTL is the authority,
                     and a `.mra` that loads to different offsets than the core
                     reads from gives a black screen with no other symptom
    DIP switches     scripts/extract_dips.py, from INPUT_PORTS_START
    title, year,     the driver's own GAME() line
    maker, parent,
    rotation
    mod byte         rtl/seta_board_cfg.sv's game enum

THE PADDING IS REAL, AND IT IS THE PRICE OF A FIXED MAP. LAYOUT_A reserves
1 MB + 2 MB + 1 MB, so thunderl's 1.6 MB of ROM ships as a 4 MB `.rom` with
2.4 MB of zeros in the gaps. Making the bases per-game would remove it and is
recorded in docs/ROADMAP.md as an option; it costs an extra table the RTL and
this script would both have to agree on, and a second or two of load time is
not yet worth that.
"""
import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import mra as mra_lib
from extract_romstart import SRC, blocks, region_records
from build_region import region_image, region_inverted, region_size, zip_for
import extract_dips

SDRAM_SV = REPO / "rtl" / "memory" / "seta_sdram_top.sv"
CFG_SV = REPO / "rtl" / "seta_board_cfg.sv"
ROMS = REPO / "roms"
OUT_DIR = REPO / "releases"

# The order the regions occupy in the image. Their offsets come from the RTL.
# ONE ORDER AND ONE BASE TABLE PER LAYOUT, because the two differ in more than
# whether gfx2 exists: LAYOUT_B's x1snd sits at 0x400000 rather than 0x300000,
# since qzkklgy2's 2 MB of tiles pushes it up. A .mra built with the wrong
# layout loads every region after the first mismatch to the wrong address, and
# the symptom is a black screen with no other clue.
LAYOUTS = {
    "A": (["maincpu", "gfx1", "x1snd"],
          {"maincpu": "BASE_MAINCPU", "gfx1": "BASE_GFX1_AB",
           "x1snd": "BASE_X1SND_A"}),
    "B": (["maincpu", "gfx1", "gfx2", "x1snd"],
          {"maincpu": "BASE_MAINCPU", "gfx1": "BASE_GFX1_AB",
           "gfx2": "BASE_GFX2_B", "x1snd": "BASE_X1SND_B"}),
    "C": (["maincpu", "gfx1", "gfx2", "gfx3", "x1snd"],
          {"maincpu": "BASE_MAINCPU", "gfx1": "BASE_GFX1_C",
           "gfx2": "BASE_GFX2_C", "gfx3": "BASE_GFX3_C",
           "x1snd": "BASE_X1SND_C"}),
    # The 6bpp sets. D covers five of them; gundhara's 8 MB of sprites gets E
    # of its own rather than making every other 6bpp .mra ship the padding.
    "D": (["maincpu", "gfx1", "gfx2", "gfx3", "x1snd"],
          {"maincpu": "BASE_MAINCPU", "gfx1": "BASE_GFX1_D",
           "gfx2": "BASE_GFX2_D", "gfx3": "BASE_GFX3_D",
           "x1snd": "BASE_X1SND_D"}),
    "E": (["maincpu", "gfx1", "gfx2", "gfx3", "x1snd"],
          {"maincpu": "BASE_MAINCPU", "gfx1": "BASE_GFX1_E",
           "gfx2": "BASE_GFX2_E", "gfx3": "BASE_GFX3_E",
           "x1snd": "BASE_X1SND_E"}),
}

# Which layout a set uses is decided by the RTL's own game numbering: the Group
# B sets are the ones seta_board_cfg.sv gives a tile layer to. Listed by name
# rather than by mod byte so adding a game cannot silently renumber this.
LAYOUT_B_SETS = {"drgnunit", "stg", "qzkklogy", "qzkklgy2"}
LAYOUT_C_SETS = {"daioh", "daioha", "rezon", "rezono", "wrofaero",
                 "msgundam", "msgundam1", "eightfrc", "oisipuzl",
                 "kamenrid", "magspeed",
                 # blandia: 4 MB of sprites is what C sizes gfx1 for, and its
                 # 6bpp tile regions are 1.5 MB each -- D would not fit gfx1.
                 "blandia", "blandiap"}
LAYOUT_D_SETS = {"zingzip", "extdwnhl", "sokonuke", "jjsquawk", "jjsquawko",
                 "madshark"}
LAYOUT_E_SETS = {"gundhara", "gundharac"}


def layout_of(setname):
    if setname in LAYOUT_E_SETS:
        return "E"
    if setname in LAYOUT_D_SETS:
        return "D"
    if setname in LAYOUT_C_SETS:
        return "C"
    return "B" if setname in LAYOUT_B_SETS else "A"


REGION_ORDER = LAYOUTS["A"][0]
BASE_NAME = LAYOUTS["A"][1]


# ---------------------------------------------------------------------------
# The RTL is the authority for both the address map and the game numbering.
# ---------------------------------------------------------------------------
def read_sdram_map():
    txt = SDRAM_SV.read_text(encoding="utf-8", errors="replace")
    bases = {}
    for m in re.finditer(
            r"localparam\s+logic\s*\[\d+:\d+\]\s*(BASE_\w+)\s*=\s*\d+'h([0-9a-fA-F_]+)",
            txt):
        bases[m.group(1)] = int(m.group(2).replace("_", ""), 16)
    missing = sorted({n for _, tbl in LAYOUTS.values() for n in tbl.values()}
                     - set(bases))
    if missing:
        sys.exit(f"{SDRAM_SV.name} does not define {', '.join(missing)}")
    return bases


# Clones that run on a PARENT'S board config unchanged, so they need no enum
# value and no RTL arm of their own -- only a .mra that selects the parent's
# mod byte.
#
# The board config's set-specific content is the ROM geometry: rom_end,
# code_mask and gfx_half_words all come from the declared region sizes. Each
# clone below declares byte-for-byte the same ROM_REGION sizes as its parent
# AND the same machine config in its GAME() line, so nothing the config carries
# can differ. The check below asserts the region sizes rather than trusting
# this comment.
#
# Deliberately NOT here:
#   daiohc      machine=wrofaero but daioh-sized graphics -- gfx_half_words
#               differs from both, so it needs its own arm.
#   daiohp/p2   machine=daiohp, a config this core does not implement.
#   thunderlbl, thunderlbl2, blockcarb, msgundamb, triplfun, triplfunk
#               bootlegs with their own hardware (Z80 + Tetris sound, OKI).
CLONE_OF = {
    "daioha":    "daioh",
    "rezono":    "rezon",
    "msgundam1": "msgundam",
    # Phase 4. gundharac is the Chinese set on gundhara's machine config and
    # jjsquawko the older revision on jjsquawk's; the size check below is what
    # says their regions really are identical to their parents'.
    "gundharac": "gundhara",
    "jjsquawko": "jjsquawk",
}


def clone_regions_match(child, parent, all_blocks):
    """Every ROM_REGION the two sets declare, name and size, must be equal."""
    def sizes(g):
        body = all_blocks.get(g)
        if body is None:
            sys.exit(f"{g}: no ROM_START in the driver")
        return {n: int(sz, 16) for sz, n in re.findall(
            r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]+)"', body)}
    # ONLY THE REGIONS THE CORE LOADS. gundhara declares a `plds` region for
    # its undumped PLDs and gundharac does not; nothing in the board config
    # can depend on that, and refusing over it would hold up a clone whose
    # graphics and program are identical.
    want = set(LAYOUTS[layout_of(parent)][0])
    a = {k: v for k, v in sizes(child).items() if k in want}
    b = {k: v for k, v in sizes(parent).items() if k in want}
    return a == b, a, b


def read_game_enum():
    """setname -> mod byte, from seta_board_cfg.sv's game_t."""
    txt = CFG_SV.read_text(encoding="utf-8", errors="replace")
    out = {}
    # Four or five bits: game_t widened when Group C filled the enum.
    for m in re.finditer(r"GAME_(\w+)\s*=\s*[45]'d(\d+)", txt):
        out[m.group(1).lower()] = int(m.group(2))
    if not out:
        sys.exit(f"{CFG_SV.name} defines no GAME_* enum")
    for child, parent in CLONE_OF.items():
        if parent not in out:
            sys.exit(f"{child} is declared a clone of {parent}, which has no "
                     f"GAME_* entry")
        out[child] = out[parent]
    return out


def read_game_lines():
    """The driver's own GAME() lines: year, parent, inputs, rotation, maker, title."""
    txt = open(SRC, encoding="utf8", errors="replace").read()
    out = {}
    pat = re.compile(
        r'^GAME\w*\(\s*(\d{4})\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,'
        r'\s*(\w+)\s*,\s*(\w+)\s*,\s*(ROT\d+)\s*,\s*"((?:[^"\\]|\\.)*)"\s*,'
        r'\s*"((?:[^"\\]|\\.)*)"', re.M)
    for m in pat.finditer(txt):
        out[m.group(2)] = dict(
            year=m.group(1), parent=m.group(3), machine=m.group(4),
            inputs=m.group(5), rot=m.group(8),
            maker=m.group(9).replace("\\", ""),
            title=m.group(10).replace("\\", ""))
    return out


# ---------------------------------------------------------------------------
# Candidate `.mra` forms per group kind, tried in order until one reproduces
# the ground truth. Deliberately includes the wrong ones: if the right answer
# were obvious there would be no need to search, and the search is the point.
CANDIDATES = {
    "load":        [None],
    "swap16":      [("12",), ("21",)],
    "load16_byte": [("01", "10"), ("10", "01")],
    # The 6bpp pair. Every arrangement of "one byte here, a swapped word
    # there" over three output bytes is offered; the search picks the one
    # that reproduces the region.
    "load24":      [("001", "120"), ("001", "210"), ("100", "021"),
                    ("100", "012"), ("010", "102"), ("010", "201")],
    # gundharac's three-ROM form: one lane each, in dest order.
    "load24x3":    [("001", "010", "100"), ("100", "010", "001")],
}
OUTPUT_BITS = {"swap16": 16, "load16_byte": 16, "load24": 24,
               "load24x3": 24}


def pick_map(rs, g, truth):
    if g["kind"] == "load":
        return None
    # THE SAME SLICING THE GROUND TRUTH USES. A sliced pair takes half the
    # group's length out of each file, and a 24-bit group carries a per-part
    # offset; feeding pick_map the whole file instead makes every candidate
    # miss and reads as "no map reproduces this".
    datas = [group_part(rs, g, i) for i in range(len(g["files"]))]
    bits = OUTPUT_BITS[g["kind"]]
    for maps in CANDIDATES[g["kind"]]:
        if mra_lib.interleave(list(zip(datas, maps)), bits) == bytes(truth):
            return maps
    sys.exit(f"no candidate map reproduces {g['kind']} {g['parts']} -- add the "
             f"right form to CANDIDATES rather than guessing")


# ---------------------------------------------------------------------------
# ROM_START records -> .mra groups
# ---------------------------------------------------------------------------
def copy_group(rec, region, setname, body):
    """A ROM_COPY as a group: a SLICE of a group in the source region.

    kamenrid and magspeed both carve their two tile regions out of one
    "user1" that a single ROM_LOAD16_WORD_SWAP fills, so the .mra can express
    each as offset/length on that file -- which is what the shipped sets that
    use those attributes do (see mra.py's note). The source region is parsed
    here rather than assumed: if the copy ever straddles two loads, or the
    source is itself a copy, this refuses instead of writing a plausible file.
    """
    _kind, src_region, dest, length, _crc, src_ofs = rec
    src_recs, unknown = region_records(body, src_region)
    if unknown:
        sys.exit(f"{setname}/{src_region}: unrecognised load line(s): {unknown[:2]}")
    if any(r[0] == "copy" for r in src_recs):
        sys.exit(f"{setname}/{region}: ROM_COPY from {src_region}, which is "
                 f"itself built by ROM_COPY -- not resolved here")

    src_groups = groups_for(src_recs, src_region, setname, body)
    hit = [g for g in src_groups
           if g["dest"] <= src_ofs and src_ofs + length <= g["dest"] + g["size"]]
    if len(hit) != 1:
        sys.exit(f"{setname}/{region}: ROM_COPY of {length:#x} bytes at "
                 f"{src_ofs:#x} of {src_region} does not lie inside exactly one "
                 f"load ({len(hit)} candidates)")
    g = dict(hit[0])
    off = src_ofs - g["dest"]

    # A 24-BIT GROUP SLICES BOTH WAYS AT ONCE. madshark builds a 3 MB "user1"
    # from one 24-bit pair and then ROM_COPYs its two halves into gfx2 and
    # gfx3, so each copy takes a window of the byte ROM and twice as much of
    # the word ROM: every three destination bytes consume one and two.
    if g["kind"] == "load24":
        if off % 3:
            sys.exit(f"{setname}/{region}: a ROM_COPY from a 24-bit group must "
                     f"start on a 3-byte group boundary, not {off:#x}")
        units = off // 3
        g["offs"] = [g["offs"][0] + units, g["offs"][1] + units * 2]
        g["sizes"] = [length // 3, (length // 3) * 2]
        g["dest"] = dest
        g["size"] = length
        return g

    # A group's byte offset is a FILE offset only when one file feeds it. A
    # load16_byte pair interleaves two, so a slice of the group is a slice of
    # each at half the offset -- correct but untested, so refused until a set
    # needs it.
    if g["kind"] not in ("load", "swap16"):
        sys.exit(f"{setname}/{region}: ROM_COPY from a {g['kind']} group is "
                 f"not supported")
    # ROM_LOAD16_WORD_SWAP swaps every pair, so slicing the file and swapping
    # gives the same bytes as swapping and slicing ONLY on an even boundary.
    if g["kind"] == "swap16" and ((off | length) & 1):
        sys.exit(f"{setname}/{region}: ROM_COPY at an odd offset or length out "
                 f"of a word-swapped region")

    g["dest"] = dest
    g["size"] = length
    g["off"] = off
    return g


def groups_for(records, region, setname, body):
    """Pair the driver's records into the groups a `.mra` can express.

    Two ROM_LOAD16_BYTE records at dest d and d+1 of the same length are one
    interleave; anything else stands alone. Ordering is by DEST, not by the
    order the records appear, because the driver writes them in whatever order
    reads best.
    """
    copies = [r for r in records if r[0] == "copy"]

    # RESOLVE ROM_CONTINUE FIRST, in the driver's own order -- it binds to the
    # load ABOVE it, and the sort by dest below would break that pairing.
    # gundhara's samples are the only case in scope: one 1 MB ROM whose second
    # half belongs at 0 ("swapped halves"), written as a load at 0x80000 plus a
    # ROM_CONTINUE at 0. Each piece becomes a SLICE of the same file, which is
    # what a .mra offset/length pair says.
    resolved = []
    prev, prev_used = None, 0
    for r in records:
        if r[0] == "copy":
            continue
        kind, name, dest, ln, crc = r[:5]
        if kind == "continue":
            if prev is None:
                sys.exit(f"{setname}/{region}: ROM_CONTINUE with no load "
                         f"before it")
            # WITH ITS LOAD'S KIND. jjsquawk's program is two ROM_LOAD16_BYTE
            # halves each continued at 0x100000, so the continuations pair into
            # a second interleave; calling them plain loads would emit one file
            # twice at full length and fail the ground-truth check.
            resolved.append((prev[2], prev[0], dest, ln, prev[1], prev_used))
            prev_used += ln
        else:
            # A load that a ROM_CONTINUE follows is itself a slice: it takes
            # the FIRST `ln` bytes of the file and the continue takes the rest.
            # Without the explicit offset the part would claim the whole file.
            chained = any(x[0] == "continue" for x in records[records.index(r) + 1:
                                                             records.index(r) + 2])
            resolved.append((kind, name, dest, ln, crc, 0 if chained else None))
            prev, prev_used = (name, crc, kind), ln

    recs = sorted(resolved, key=lambda r: (r[2] & ~1, r[2] & 1))
    out = []
    i = 0
    while i < len(recs):
        kind, name, dest, ln, crc = recs[i][:5]
        if kind == "load16_byte":
            if i + 1 >= len(recs):
                sys.exit(f"{setname}/{region}: an unpaired ROM_LOAD16_BYTE at "
                         f"{dest:#x}")
            k2, n2, d2, l2, c2 = recs[i + 1][:5]
            if k2 != "load16_byte" or d2 != dest + 1 or l2 != ln:
                sys.exit(f"{setname}/{region}: {name} at {dest:#x} has no matching "
                         f"odd half")
            g = {"kind": "load16_byte", "parts": [name, n2],
                 "crcs": [crc, c2], "size": ln * 2, "dest": dest}
            # Both halves are sliced the same way when the pair came from a
            # ROM_CONTINUE -- jjsquawk's program is two 0x80000 files each
            # loaded as 0x40000 at 0 and 0x40000 more at 0x100000.
            if recs[i][5] is not None:
                if recs[i + 1][5] != recs[i][5]:
                    sys.exit(f"{setname}/{region}: {name} and {n2} are sliced "
                             f"differently ({recs[i][5]:#x} vs "
                             f"{recs[i + 1][5]:#x})")
                g["off"] = recs[i][5]
            out.append(g)
            i += 2
            continue
        if kind in ("load24_byte", "load24_wswap"):
            # ONE GROUP PER WORD RECORD. The byte half carries one byte of each
            # 3-byte unit and the word half two, so a word ROM of L bytes
            # covers 3*L/2 of the region -- and where two word ROMs share one
            # byte ROM, as jjsquawk's do, the byte ROM is SLICED between them.
            # THREE BYTE ROMS, ONE PER LANE -- gundharac. No word half at
            # all, so the pair logic below does not apply.
            lanes = sorted((r for r in recs if r[0] == "load24_byte"),
                           key=lambda r: r[2])
            if not any(r[0] == "load24_wswap" for r in recs):
                # ONE TRIPLE PER DESTINATION. gundharac's gfx3 is two of them,
                # at 0x000000 and 0x180000, each three ROMs at +0, +1 and +2.
                if len(lanes) % 3:
                    sys.exit(f"{setname}/{region}: {len(lanes)} ROM_LOAD24_BYTE "
                             f"records with no word half; they come in threes")
                for t in range(0, len(lanes), 3):
                    tri = lanes[t:t + 3]
                    if [r[2] - tri[0][2] for r in tri] != [0, 1, 2]:
                        sys.exit(f"{setname}/{region}: the 24-bit lanes at "
                                 f"{tri[0][2]:#x} are not at consecutive "
                                 f"destinations")
                    if len({r[3] for r in tri}) != 1:
                        sys.exit(f"{setname}/{region}: the 24-bit lanes at "
                                 f"{tri[0][2]:#x} are not the same length")
                    out.append({"kind": "load24x3",
                                "parts": [r[1] for r in tri],
                                "crcs":  [r[4] for r in tri],
                                "size": tri[0][3] * 3, "dest": tri[0][2]})
                i = len(recs)
                continue
            if kind == "load24_byte":
                bn, bc, bl, bdest = name, crc, ln, dest
                j, words = i + 1, []
            else:
                # The driver writes the word half first on jjsquawk.
                bytes_rec = next((r for r in recs if r[0] == "load24_byte"),
                                 None)
                if bytes_rec is None:
                    sys.exit(f"{setname}/{region}: a 24-bit word load with no "
                             f"byte half")
                bn, bc, bl, bdest = (bytes_rec[1], bytes_rec[4], bytes_rec[3],
                                     bytes_rec[2])
                j, words = i, []
            for r in recs:
                if r[0] == "load24_wswap":
                    words.append(r)
            wtot = sum(w[3] for w in words)
            # blandia's gfx2: a 0x80000 byte ROM against a 0x80000 word ROM,
            # so the word lanes of the top half of the region were never
            # loaded and hold MAME's zero fill, while the byte ROM's second
            # half is uniform (0xFF). That tail is a plain repeated 3-byte
            # literal -- mra-tools-c does not apply `repeat` inside an
            # <interleave>, so it cannot be a filler lane. The value is taken
            # from the ground truth, not assumed, and checked to be uniform.
            short_tail = (wtot == bl and len(words) == 1)
            if wtot != bl * 2 and not short_tail:
                sys.exit(f"{setname}/{region}: the 24-bit word halves total "
                         f"{wtot:#x} against a byte half of {bl:#x}; they "
                         f"must be twice it (or equal it, blandia's form)")
            for wk, wn, wdest, wl, wc, _woff in words:
                # Every three destination bytes take one from the byte ROM.
                boff = (wdest - 1 - bdest) // 3
                out.append({"kind": "load24", "parts": [bn, wn],
                            "crcs": [bc, wc], "size": (wl // 2) * 3,
                            "dest": wdest - 1,
                            "offs": [boff, 0], "sizes": [wl // 2, wl]})
                if short_tail:
                    covered = (wl // 2) * 3
                    out.append({"kind": "fill24", "parts": [bn], "crcs": [bc],
                                "size": (bl - wl // 2) * 3,
                                "dest": wdest - 1 + covered,
                                "offs": [wl // 2], "sizes": [bl - wl // 2]})
            # Both kinds of record for this region are consumed together.
            i = len(recs)
            continue
        if kind == "load":
            g = {"kind": "load", "parts": [name], "crcs": [crc],
                 "size": ln, "dest": dest}
            if recs[i][5] is not None:
                g["off"] = recs[i][5]
            out.append(g)
        elif kind == "load16_wswap":
            out.append({"kind": "swap16", "parts": [name], "crcs": [crc],
                        "size": ln, "dest": dest})
        else:
            sys.exit(f"{setname}/{region}: unhandled record kind {kind}")
        i += 1

    for rec in copies:
        out.append(copy_group(rec, region, setname, body))
    out.sort(key=lambda g: g["dest"])
    return out


# ---------------------------------------------------------------------------
# XML
# ---------------------------------------------------------------------------
def esc(s):
    """XML-escape a value that came from MAME.

    Not defensive padding: several of this driver's titles contain a bare
    ampersand ("Thunder & Lightning"), and an `.mra` MiSTer cannot parse loads
    nothing and shows no DIPs, with every symptom pointing at the RTL.
    """
    return escape(str(s), {'"': "&quot;"})


def dip_xml(ports):
    """Derive `bits`, `ids` and the default bytes from MAME's encoding.

    A MiSTer `<dip>`'s ids are indexed by the value assembled from the listed
    bits, LSB first. Deriving that from the {value: label} map is what keeps
    the ordering honest -- writing the ids by hand is how a game ends up
    booting into service mode.
    """
    out = []
    default_bytes = []
    for byte_index, dips in enumerate(ports):
        # A BIT NO DIP COVERS READS AS 1, not 0. Every port in this driver is
        # IP_ACTIVE_LOW and every switch line is pulled up, so an undeclared
        # bit is "open" -- and the core feeds sw[2][7:4] straight into the
        # COINS port, so starting the byte at zero handed a game four asserted
        # switches it never had. Building the default up with OR left sw[2] at
        # 0x00 for thirteen of the nineteen sets.
        default = 0xFF
        for name, mask, dflt, settings in dips:
            default = (default & ~mask) | (dflt & mask)
            if settings is None:      # PORT_DIPUNUSED: default only
                continue
            bit_positions = [i for i in range(8) if mask & (1 << i)]
            n = len(bit_positions)
            ids = []
            for idx in range(1 << n):
                value = 0
                for j, bp in enumerate(bit_positions):
                    if idx & (1 << j):
                        value |= (1 << bp)
                ids.append(settings.get(value, "-"))
            for label in ids:
                if "," in label:
                    sys.exit(f"dip '{name}': label {label!r} contains a comma")
            bits = [8 * byte_index + b for b in bit_positions]
            out.append((esc(name), ",".join(str(b) for b in bits),
                        esc(",".join(ids))))
        default_bytes.append(default & 0xFF)
    return out, default_bytes


def split_ports(ports, setname):
    """Turn the driver's ports into the three switch BYTES the core expects.

    Seta.sv wires them as:
        sw[0]  the byte seta_dsw_r returns at OFFSET 0 -- the HIGH half of the
               driver's 16-bit DSW port, "SW1" in its DIPLOCATION names
        sw[1]  the byte at offset 1 -- the LOW half, "SW2"
        sw[2]  the DIP bits several games put in the COINS port's top nibble
    Getting sw[0] and sw[1] the wrong way round makes the game read the other
    DIP bank, which misbehaves in ways that look like anything but a byte order.
    """
    dsw = ports.get("DSW", [])
    coins = ports.get("COINS", [])
    hi, lo = [], []
    for label, mask, dflt, settings in dsw:
        if mask & 0xFF00:
            hi.append((label, (mask >> 8) & 0xFF, (dflt >> 8) & 0xFF,
                       None if settings is None
                       else {(v >> 8) & 0xFF: l for v, l in settings.items()}))
        elif mask & 0x00FF:
            lo.append((label, mask & 0xFF, dflt & 0xFF, settings))
        else:
            sys.exit(f"{setname}: DSW switch '{label}' has an empty mask")
    # Only the COINS bits that are DIPs, which are always in the top nibble.
    cn = [(l, m & 0xFF, d & 0xFF, s) for (l, m, d, s) in coins if (m & 0xF0)]
    return [hi, lo, cn]


# The six P1/P2 layouts seta.cpp uses across the sets in scope, and the button
# names that go with each. The code is Seta.sv's input_layout, which assembles
# the port word; the names are positional -- entry i is joystick bit 4 + i --
# so the two lists ARE the same mapping written twice and have to agree.
#
#   0 JOY2    LRUD at 0-3, B1 B2 at 4-5
#   1 JOY1    one button
#   2 JOY3    BUTTON3 at bit 6
#   3 PANEL4  B3 B4 B1 B2 at 0-3: atehate's default panel, and qzkklgy2
#   4 PANEL5  PANEL4 plus BUTTON5 at 4, qzkklogy's pause cheat
#   5 CARDS   magspeed: Card 1-4 at 0-3, B1 B2 at 4-5
BUTTON_LAYOUTS = {
    0: ["Button 1", "Button 2"],
    1: ["Button 1"],
    2: ["Button 1", "Button 2", "Button 3"],
    3: ["Button 1", "Button 2", "Button 3", "Button 4"],
    4: ["Button 1", "Button 2", "Button 3", "Button 4", "Pause (Cheat)"],
    5: ["Button 1", "Button 2", "Card 1", "Card 2", "Card 3", "Card 4"],
    6: ["Button 1", "Button 2", "Button 3",
        "Button 4", "Button 5", "Button 6"],
}


def input_layout(setname, block, all_blocks, depth=0):
    """Which layout a set's P1 port is, read out of the driver.

    Derived rather than tabulated: a hand table is one more thing to keep in
    step with seta.cpp, and the macros say it outright.
    """
    if depth > 4:
        sys.exit("PORT_INCLUDE nested too deep")
    if "JOY_TYPE1_1BUTTON" in block:
        return 1
    if "JOY_TYPE1_3BUTTONS" in block:
        # daioh reads buttons 4-6 from a port of its own at 0x500006, so it
        # is a six-button game with a three-button P1 word.
        return 6 if 'PORT_START("EXTRA")' in block and "IPT_BUTTON6" in block             else 2
    if "JOY_TYPE1_2BUTTONS" in block:
        return 0
    if "JOY_TYPE2" in block:
        sys.exit(f"{setname}: JOY_TYPE2 reverses the direction bits and no "
                 f"in-scope set used it when Seta.sv was written")

    p1 = block.split('PORT_START("P2")')[0]
    if "PORT_INCLUDE" in block and "IPT_BUTTON" not in p1:
        m = re.search(r"PORT_INCLUDE\(\s*(\w+)\s*\)", block)
        if m and m.group(1) in all_blocks:
            got = input_layout(setname, all_blocks[m.group(1)], all_blocks,
                               depth + 1)
            # PORT_MODIFY can take a button away again. qzkklgy2 includes
            # qzkklogy and then makes bit 4 -- its BUTTON5 pause cheat --
            # IPT_UNKNOWN, which is the difference between PANEL5 and PANEL4.
            mod = re.search(r'PORT_MODIFY\(\s*"P1"\s*\)(.*?)(?:PORT_MODIFY|$)',
                            block, re.S)
            if got == 4 and mod and re.search(
                    r"PORT_BIT\(\s*0x0010\s*,[^)]*IPT_UNKNOWN", mod.group(1)):
                return 3
            return got
    if 'PORT_NAME("P1 Card 1")' in p1:
        return 5
    # extdwnhl and sokonuke write JOY_TYPE1_1BUTTON's shape out by hand, with
    # a PORT_2WAY stick and IPT_UNKNOWN where up and down would be. The core
    # drives those two bits from the pad's up and down; the games read them as
    # unknown, which is what they read when nothing is pressed.
    if "IPT_BUTTON1" in p1 and "IPT_BUTTON2" not in p1:
        return 1
    if "IPT_BUTTON5" in p1:
        return 4
    if "IPT_BUTTON4" in p1:
        return 3
    sys.exit(f"{setname}: cannot tell the input layout from its P1 port")


def buttons_xml(layout):
    """The <buttons> element, with Start and Coin at FIXED joystick bits.

    THE NAME LIST IS POSITIONAL: entry i is joystick bit 4 + i. Writing the
    names in the order a game happens to use them therefore MOVES Start and
    Coin, and the core reads fixed bits -- so a two-button game put "Start" on
    the bit the core reads as COIN1, and Coin on a bit nothing read at all.
    Measured on hardware: pressing Start inserted a coin, and Coin did nothing.

    So the list is padded to keep the positions fixed, which is what
    Arcade-Psikyo_MiSTer does and why its six-button and three-button sets
    both work:

        bit  4  5  6  7  8  9  10     11    12     13
             B1 B2 -  -  -  -  Start  Coin  Pause  Service

    Seta.sv reads exactly those bits. Keep the two in step.
    """
    have = BUTTON_LAYOUTS[layout]
    n = len(have)
    names = have + ["-"] * (6 - n) + ["Start", "Coin", "Pause", "Service"]
    default = ["A", "B", "X", "Y", "L", "R"][:n] + ["Start", "Select", "L", "R"]
    return (f'<buttons names="{esc(",".join(names))}" '
            f'default="{esc(",".join(default))}" count="{n}"/>')


def mra_filename(title):
    """From the MAME description, which is what the user sees in the menu.

    Characters a filesystem will not take are REPLACED rather than dropped:
    blockcar's description is "Block Carnival / Thunder & Lightning 2", and
    deleting the slash leaves a double space in the middle of the name.
    """
    out = title.replace(" / ", " - ").replace("/", "-")
    for c in '<>:"\\|?*':
        out = out.replace(c, "")
    return " ".join(out.split()) + ".mra"


# ---------------------------------------------------------------------------
def build_one(setname, mod, bases, gl, all_blocks, dip_blocks, out_dir, write):
    # THE LAYOUT IS PER SET. Group B has a gfx2 region and its x1snd sits a
    # megabyte higher, so the region list and the base table both change.
    REGION_ORDER, BASE_NAME = LAYOUTS[layout_of(setname)]
    if setname not in gl:
        sys.exit(f"{setname}: no GAME() line in the driver")
    info = gl[setname]
    zippath, key = zip_for(setname, all_blocks)
    body = all_blocks[setname]

    # A clone borrowing a parent's mod byte gets the parent's ROM geometry in
    # the RTL. Prove the geometry is the same rather than assuming it.
    if setname in CLONE_OF:
        parent = CLONE_OF[setname]
        same, a, b = clone_regions_match(setname, parent, all_blocks)
        if not same:
            sys.exit(f"{setname} borrows {parent}'s board config but their "
                     f"ROM_REGIONs differ: {a} vs {b}")
        if gl[setname]["machine"] != gl[parent]["machine"]:
            sys.exit(f"{setname} borrows {parent}'s board config but the driver "
                     f"gives it a different machine config "
                     f"({gl[setname]['machine']} vs {gl[parent]['machine']})")

    # ---- ground truth, region by region ----------------------------------
    import zipfile
    from romset import RomSet
    rs = RomSet(zippath, key)

    truths = {}
    all_groups = {}
    for region in REGION_ORDER:
        recs, unknown = region_records(body, region)
        if unknown:
            sys.exit(f"{setname}/{region}: unrecognised load line(s): {unknown[:2]}")
        if not recs and region_size(body, region) is None:
            sys.exit(f"{setname}: no {region} region")
        gs = groups_for(recs, region, setname, body)
        blob = bytearray()
        for g in gs:
            # A GAP BETWEEN GROUPS IS REAL PADDING, not an error. rezon's
            # maincpu is two ROM_LOAD16_BYTE pairs at 0x000000 and 0x100000
            # with nothing between, and without this the groups concatenate
            # and every byte after the gap lands 0xc0000 early.
            if len(blob) < g["dest"]:
                # A HOLE IS 0xFF, the tail is 0x00. build_region.py pads holes
                # the way an unprogrammed EPROM reads and the tail the way
                # MAME zero-fills a region it allocates; both have to match or
                # the cross-check fails on the padding rather than the data.
                blob += bytes([0xFF]) * (g["dest"] - len(blob))
            elif len(blob) > g["dest"]:
                sys.exit(f"{setname}/{region}: {g['parts']} starts at "
                         f"{g['dest']:#x} but {len(blob):#x} bytes are already "
                         f"placed -- overlapping groups")
            # Resolve by CRC -- roms/ is merged, and a basename can appear in
            # more than one set's directory. romset.py refuses to guess.
            g["files"] = [rs.resolve(n, c) for n, c in zip(g["parts"], g["crcs"])]
            # A `.mra` names its parts by BASENAME -- that is what mra-tools
            # matches, and it is what mra.py's reader matches too. In a MERGED
            # collection a basename can appear in more than one clone's
            # directory, so check the ones this set uses are unambiguous
            # rather than letting a last-one-wins lookup pick silently.
            g["names"] = [check_basename(rs, f) for f in g["files"]]
            t = group_truth_from(rs, g)
            if len(t) != g["size"]:
                sys.exit(f"{setname}/{region}: {g['parts']} gave {len(t)} bytes, "
                         f"ROM_START says {g['size']}")
            blob += t
        declared = region_size(body, region)
        if len(blob) < declared:
            blob += bytes(declared - len(blob))
        elif len(blob) > declared:
            sys.exit(f"{setname}/{region}: groups total {len(blob):#x} but "
                     f"ROM_REGION declares {declared:#x}")
        # Cross-check against the independent assembler.
        ref, _, _ = region_image(setname, region, all_blocks)
        # A .mra ships the ROM data as dumped. ROMREGION_INVERT is a property
        # of the region, not of the file, so the CORE applies it at download
        # and this cross-check compares against the UNinverted assembly.
        if region_inverted(body, region):
            ref = bytes(b ^ 0xFF for b in ref)
        if bytes(blob) != ref:
            sys.exit(f"{setname}/{region}: this file's grouping disagrees with "
                     f"build_region.py -- one of the two is wrong")
        truths[region] = bytes(blob)
        all_groups[region] = gs

    # ---- the image the .mra must reproduce, padding included --------------
    image = bytearray()
    for region in REGION_ORDER:
        base = bases[BASE_NAME[region]]
        if len(image) > base:
            sys.exit(f"{setname}: {region} would start at {len(image):#x}, past "
                     f"its base {base:#x} -- LAYOUT_{layout_of(setname)} is too small for this set")
        image += bytes(base - len(image))
        image += truths[region]

    # ---- XML --------------------------------------------------------------
    lines = []
    lines.append('<misterromdescription>')
    lines.append(f'    <name>{esc(info["title"])}</name>')
    lines.append(f'    <setname>{esc(setname)}</setname>')
    lines.append('    <rbf>Seta</rbf>')
    lines.append(f'    <mameversion>0286</mameversion>')
    lines.append(f'    <year>{esc(info["year"])}</year>')
    lines.append(f'    <manufacturer>{esc(info["maker"])}</manufacturer>')
    lines.append(f'    <category>Arcade</category>')
    lines.append(f'    <rotation>{"vertical" if info["rot"] in ("ROT90", "ROT270") else "horizontal"}</rotation>')
    lines.append('')
    # A clone's own zip first, then the parent's: a split collection has the
    # clone's ROMs in its own archive, a merged one has everything in the
    # parent's, and the loader tries them in order.
    zips = Path(zippath).name
    if info["parent"] != "0" and Path(zippath).stem != setname:
        zips = f"{setname}.zip|{zips}"
    # THE MOD BYTE COMES FIRST. The MiSTer loader sends the <rom> elements in
    # file order, and the core does not merely record which game it is -- it
    # PERMUTES THE SPRITE ROM WITH IT AS THE DATA ARRIVES. rtl/seta_board_cfg.sv
    # turns the mod byte into gfx_half_words, and seta_sdram_top applies the
    # swizzle to ioctl_addr during the download.
    #
    # With the data first, the whole sprite region was swizzled using the
    # board config's DEFAULTS, which are thunderl's (gfx_half_words 0x20000).
    # So thunderl, thunderla and wits -- the three sets whose value IS 0x20000
    # -- were laid out correctly and every other game's sprite ROM was laid out
    # wrong. On hardware that is exactly what it looked like: two games perfect,
    # the rest rendering the wrong tiles.
    #
    # Arcade-Psikyo_MiSTer emits index 1 first for the same reason.
    lines.append(f'    <!-- which game, for rtl/seta_board_cfg.sv. FIRST, '
                 f'because the download is permuted with it. -->')
    lines.append(f'    <rom index="1"><part>{mod:02X}</part></rom>')
    lines.append('')
    lines.append(f'    <rom index="0" zip="{esc(zips)}" md5="none">')
    pos = 0
    for region in REGION_ORDER:
        base = bases[BASE_NAME[region]]
        if base > pos:
            lines.append(f'        <!-- pad to {base:#08x} -->')
            lines.append(f'        <part repeat="{base - pos}">00</part>')
            pos = base
        lines.append(f'        <!-- {region} -->')
        rbase = bases[BASE_NAME[region]]
        for g in all_groups[region]:
            if pos - rbase < g["dest"]:
                lines.append(f'        <part repeat="{g["dest"] - (pos - rbase)}">FF</part>')
                pos = rbase + g["dest"]
            if g["kind"] == "fill24":
                tr = group_truth_from(rs, g)
                pat = bytes(tr[:3])
                if any(tr[i:i + 3] != pat for i in range(0, len(tr), 3)):
                    sys.exit(f"{setname}/{region}: the uncovered 24-bit tail "
                             f"is not a repeating 3-byte pattern")
                lines.append(f'        <part repeat="{g["size"] // 3}">'
                             f'{pat[0]:02X} {pat[1]:02X} {pat[2]:02X}</part>')
                pos += g["size"]
                continue
            maps = pick_map(rs, g, group_truth_from(rs, g))
            # A slice carries offset/length; mra.py applies them to the file
            # before the map, which is what mra-tools-c does.
            # A PART'S length is its own, not the group's: an interleaved
            # pair contributes half the group's bytes from each file.
            cut = (f' offset="{g["off"]:#x}" '
                   f'length="{g["size"] // len(g["parts"]):#x}"'
                   if "off" in g else "")
            # Per-part offsets, for a 24-bit group whose byte half is shared
            # between two word ROMs.
            cuts = ([f' offset="{o:#x}" length="{n:#x}"'
                     for o, n in zip(g["offs"], g["sizes"])]
                    if "offs" in g else None)
            # crc: the driver's CRC32 of the whole file, as the shipped .mra
            # files carry it (Arcade-Psikyo_MiSTer, MRA-Alternatives). It is
            # the FILE's CRC even on a sliced part -- mra.py checks it
            # before applying offset/length.
            if maps is None:
                lines.append(f'        <part name="{esc(g["names"][0])}" '
                             f'crc="{g["crcs"][0]:08x}"{cut}/>')
            else:
                lines.append(f'        <interleave output="{OUTPUT_BITS[g["kind"]]}">')
                for k, (fn, c, mp) in enumerate(
                        zip(g["names"], g["crcs"], maps)):
                    lines.append(f'            <part name="{esc(fn)}" '
                                 f'crc="{c:08x}"'
                                 f'{cuts[k] if cuts else cut} map="{mp}"/>')
                lines.append('        </interleave>')
            pos += g["size"]
        declared = region_size(body, region)
        gs = all_groups[region]
        got = (gs[-1]["dest"] + gs[-1]["size"]) if gs else 0
        if got < declared:
            lines.append(f'        <part repeat="{declared - got}">00</part>')
            pos += declared - got
    lines.append('    </rom>')
    lines.append('')

    ports = extract_dips.parse_ports(dip_blocks[info["inputs"]], dip_blocks, set())
    sw = split_ports(ports, setname)
    dips, defaults = dip_xml(sw)
    lines.append(f'    <switches default="{",".join(f"{b:02X}" for b in defaults)}" base="0">')
    for name, bits, ids in dips:
        lines.append(f'        <dip name="{name}" bits="{bits}" ids="{ids}"/>')
    lines.append('    </switches>')
    lines.append('')
    lines.append('    ' + buttons_xml(
        input_layout(setname, dip_blocks[info["inputs"]], dip_blocks)))
    lines.append('</misterromdescription>')
    xml = "\n".join(lines) + "\n"

    # ---- where it goes ----------------------------------------------------
    # A parent sits directly in the Arcade folder; a clone goes into
    # _alternatives/_<parent>, so the top level lists one entry per game rather
    # than one per ROM revision.
    if info["parent"] != "0":
        pinfo = gl.get(info["parent"])
        folder = out_dir / "_alternatives" / ("_" + re.sub(r"\s*\(.*", "",
                                                           pinfo["title"] if pinfo else info["parent"]))
    else:
        folder = out_dir
    path = folder / mra_filename(info["title"])

    if write:
        folder.mkdir(parents=True, exist_ok=True)
        path.write_text(xml, encoding="utf8")

    # ---- prove it ---------------------------------------------------------
    tmp = path if write else (out_dir / ".check.mra")
    if not write:
        out_dir.mkdir(parents=True, exist_ok=True)
        tmp.write_text(xml, encoding="utf8")
    try:
        ET.parse(tmp)          # well-formedness, before anything else reads it
        got = mra_lib.build_image(tmp, zippath)
    finally:
        if not write:
            tmp.unlink(missing_ok=True)
    if got != bytes(image):
        n = min(len(got), len(image))
        first = next((i for i in range(n) if got[i] != image[i]), n)
        sys.exit(f"{setname}: the .mra assembles {len(got):#x} bytes, ground truth "
                 f"is {len(image):#x}; first difference at {first:#x}")
    return path, len(image), len(dips)


def check_basename(rs, path):
    """The basename of a resolved zip entry, if nothing else in the archive
    shares it with DIFFERENT content.

    romset.py resolves by CRC, which is unambiguous. A `.mra` cannot: it names
    a part by basename and the loader finds it however it finds it. Where a
    merged archive holds two different dumps under one basename -- which this
    collection does, for daiohp vs daiohp2 and jjsquawkb vs simpsonjr -- the
    `.mra` would be ambiguous, and the failure would be a game loading another
    revision's ROM and misbehaving in a way that points nowhere near the file.
    """
    base = path.split("/")[-1]
    crcs = {info.CRC for info in rs.zip.infolist()
            if info.filename.split("/")[-1] == base}
    if len(crcs) > 1:
        sys.exit(f"{base!r} appears in {rs.path} with {len(crcs)} different "
                 f"CRCs -- a .mra names parts by basename and cannot say which")
    return base


def sliced(rs, g, ix=0):
    """One of a group's files, cut down by `off`/`size` if the group is a slice.

    Applied to the FILE, which is what a .mra's offset/length do -- so this and
    the XML the writer emits are the same operation, and the cross-check
    against build_region.py is what says the operation is the right one.
    """
    d = bytearray(rs.zip.read(g["files"][ix]))
    if "off" not in g:
        return d
    return d[g["off"]:g["off"] + g["size"]]


def group_part(rs, g, ix):
    """One part's bytes, however the group is cut up."""
    if "offs" in g:
        return part_slice(rs, g, ix)
    if "off" in g and len(g["files"]) > 1:
        return sliced_n(rs, g, ix, g["size"] // len(g["files"]))
    return sliced(rs, g, ix)


def part_slice(rs, g, ix):
    """One part of a group that carries a per-PART offset and length."""
    d = bytearray(rs.zip.read(g["files"][ix]))
    off, n = g["offs"][ix], g["sizes"][ix]
    return d[off:off + n]


def sliced_n(rs, g, ix, n):
    d = bytearray(rs.zip.read(g["files"][ix]))
    return d[g["off"]:g["off"] + n]


def group_truth_from(rs, g):
    if g["kind"] == "load":
        return sliced(rs, g)
    if g["kind"] == "swap16":
        d = sliced(rs, g)
        d[0::2], d[1::2] = d[1::2], d[0::2]
        return d
    if g["kind"] == "fill24":
        # ONE part: the byte ROM's uncovered tail goes in lane 0, and the word
        # lanes were never loaded, so they hold the region's zero fill.
        a = group_part(rs, g, 0)
        out = bytearray(len(a) * 3)
        out[0::3] = a
        return out
    # A sliced pair takes the same window out of each file; `size` is the
    # INTERLEAVED length, so each side contributes half of it.
    a = group_part(rs, g, 0)
    b = group_part(rs, g, 1)
    if g["kind"] == "load24x3":
        # One lane per ROM, in destination order: files[0] at dest+0.
        c = group_part(rs, g, 2)
        out = bytearray(len(a) * 3)
        out[0::3] = a
        out[1::3] = b
        out[2::3] = c
        return out
    if g["kind"] == "load24":
        # files[0] is the byte half, files[1] the word half -- groups_for puts
        # them in that order whichever way round the driver writes them -- and
        # each carries its own offset and length.
        out = bytearray(len(a) * 3)
        out[0::3] = a
        out[1::3] = b[1::2]
        out[2::3] = b[0::2]
        return out

    out = bytearray(len(a) * 2)
    out[0::2] = a
    out[1::2] = b
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--check", action="store_true",
                    help="verify only; write nothing")
    ap.add_argument("--out", default=str(OUT_DIR))
    a = ap.parse_args()

    if not os.path.exists(SRC):
        sys.exit(f"driver not found at {SRC} (set MAME_SRC)")
    bases = read_sdram_map()
    mods = read_game_enum()
    gl = read_game_lines()
    all_blocks = blocks(open(SRC, encoding="utf8", errors="replace").read())
    dip_blocks = extract_dips.blocks(
        open(SRC, encoding="utf8", errors="replace").read())

    wanted = a.sets or sorted(mods, key=lambda k: mods[k])
    out_dir = Path(a.out)
    print(f"address map from {SDRAM_SV.name}: " +
          ", ".join(f"{k}={v:#x}" for k, v in sorted(bases.items())))
    print()

    fails = 0
    for setname in wanted:
        if setname not in mods:
            print(f"{setname:12s} SKIP  no GAME_* entry in seta_board_cfg.sv")
            continue
        try:
            path, size, ndips = build_one(setname, mods[setname], bases, gl,
                                          all_blocks, dip_blocks, out_dir,
                                          not a.check)
        except SystemExit as e:
            print(f"{setname:12s} FAIL  {e}")
            fails += 1
            continue
        rel = path.relative_to(out_dir) if path.is_relative_to(out_dir) else path
        print(f"{setname:12s} mod {mods[setname]:2d}  {size / 1048576:.2f} MB  "
              f"{ndips:2d} dips  {'->' if not a.check else 'ok:'} {rel}")

    print()
    print(f"{len(wanted) - fails} of {len(wanted)} verified byte-for-byte "
          f"against the ROM_START ground truth")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
