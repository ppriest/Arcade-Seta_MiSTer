#!/usr/bin/env python3
"""Generate the `.mra` files, and prove each one byte-for-byte.

    python scripts/build_mra.py            # write releases/*.mra
    python scripts/build_mra.py --check    # verify only, write nothing

*** NOT YET PORTED TO SETA -- THIS SCRIPT REFUSES TO RUN. ***

It is here for its STRUCTURE, which is the part worth keeping: build each
region from ROM_START semantics, TEST candidate map digits against that rather
than deriving them, then re-read the finished file and compare byte-for-byte.
Everything below the header still describes Fuuki's two boards and would
happily emit confident, wrong `.mra` files for Seta sets.

Porting it needs two things that do not exist yet:
  1. rtl/memory/seta_sdram_top.sv, which is the authority for the region
     offsets -- see "THE ADDRESS MAP IS NOT DEFINED HERE" below.
  2. the per-set ROM_START tables. `scripts/build_maincpu_hex.py` already
     carries the maincpu ones for ten sets in exactly the right shape, and
     `scripts/decode_gfx.py --interleave 24` carries the 6bpp grouping, so
     both are transcribed and verified against real ROMs already.

HOW THIS AVOIDS THE CLASSIC .mra BUG
------------------------------------
docs/LESSONS_LEARNED.md is blunt: on the Psikyo core, *every* interleave that
was DERIVED by reasoning about byte order was wrong, and "it boots" is weak
evidence because a wrong map can boot far enough to look plausible. So nothing
here reasons about map digits. Instead:

  1. Each region's image is built DIRECTLY from the driver's ROM_START
     semantics -- rom_load, rom_load16_byte, rom_load16_word_swap,
     rom_load32_word_swap, rom_load32_byte -- implemented once, below. That is
     the ground truth.
  2. Candidate `.mra` forms are then TRIED against it, and the one that
     reproduces the ground truth exactly is the one emitted.
  3. The finished `.mra` is re-read with scripts/mra.py and the whole assembled
     image compared byte-for-byte with the concatenation of the ground truths.

Step 3 is only meaningful because mra.py's map convention was checked against
mra-tools-c itself rather than against this file -- see mra.py's
`pattern_from_map()` and its selftest. Two implementations sharing one wrong
assumption would agree with each other and still be wrong on hardware.

THE ADDRESS MAP IS NOT DEFINED HERE
-----------------------------------
It is parsed out of rtl/memory/fuuki_sdram_top.sv, which is the authority. A
`.mra` that loads to different offsets than the RTL reads from produces a
black screen with no other symptom, so the two must not be able to drift.
There are two tables there, one per board: `FG2_BASE_*` and `FG3_BASE_*`.
"""
import argparse
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from xml.sax.saxutils import escape
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mra as mra_lib

sys.exit(
    "scripts/build_mra.py is NOT yet ported to Seta -- it still holds Fuuki's "
    "board tables and would emit plausible-looking, WRONG .mra files. "
    "See the module docstring for what porting it needs. Remove this guard "
    "only together with the Fuuki tables below."
)

REPO = Path(__file__).resolve().parent.parent
SDRAM_SV = REPO / "rtl" / "memory" / "fuuki_sdram_top.sv"


# ---------------------------------------------------------------------------
# MAME ROM_START loaders. One implementation, used as ground truth.
# ---------------------------------------------------------------------------

def rom_load(z, names, part):
    return bytearray(z.read(names[part]))


def rom_load16_word_swap(z, names, part):
    d = bytearray(z.read(names[part]))
    for i in range(0, len(d) - 1, 2):
        d[i], d[i + 1] = d[i + 1], d[i]
    return d


def rom_load16_byte(z, names, even_part, odd_part):
    """Two ROMs supplying alternate bytes of a big-endian 16-bit word."""
    a = z.read(names[even_part])
    b = z.read(names[odd_part])
    out = bytearray(len(a) * 2)
    out[0::2] = a
    out[1::2] = b
    return out


def rom_load32_byte(z, names, p0, p1, p2, p3):
    """Four ROMs supplying successive bytes of a big-endian 32-bit long.

    FG-3's 68EC020 program ROMs. The parts are named in ROM_START order, so
    `p0` is the one loaded at offset 0 -- which is `pgm3`, the MOST significant
    byte. Naming them by offset rather than by label keeps that inversion from
    quietly reappearing here.
    """
    srcs = [z.read(names[p]) for p in (p0, p1, p2, p3)]
    out = bytearray(len(srcs[0]) * 4)
    for lane, s in enumerate(srcs):
        out[lane::4] = s
    return out


def rom_load32_word_swap(z, names, lo_part, hi_part):
    """A ROM_LOAD32_WORD_SWAP pair: `lo_part` at offset 0, `hi_part` at 2,
    each source word byte-swapped."""
    a = z.read(names[lo_part])
    b = z.read(names[hi_part])
    out = bytearray(len(a) * 2)
    for i in range(0, len(a), 2):
        out[2*i + 0] = a[i+1]; out[2*i + 1] = a[i+0]
        out[2*i + 2] = b[i+1]; out[2*i + 3] = b[i+0]
    return out


# A region is a list of groups. Each group names its loader and its parts, and
# maps 1:1 onto one `<part>` or `<interleave>` in the emitted `.mra`.
def G(kind, *parts):
    return {"kind": kind, "parts": list(parts)}


def GAP(n):
    """A hole INSIDE a MAME ROM_REGION -- address space the region declares
    but no ROM fills.

    Filled with 0x00, which is what MAME's region actually contains there, and
    deliberately not the 0xFF used to pad BETWEEN regions. asurabld leaves the
    first 4 MB of its 32 MB sprite region empty and the sprite tile bank can
    still address it, so a mismatched fill byte draws pen 0xff instead of pen
    0x00 -- solid colour where there should be nothing.
    """
    return {"kind": "gap", "parts": [], "size": n}


# ---------------------------------------------------------------------------
# DIP switches, transcribed from each driver's INPUT_PORTS_START.
#
# Encoded as MAME encodes them -- mask, default, and the {value: label} map --
# so the `.mra`'s `bits` and `ids` are DERIVED mechanically below rather than
# hand-ordered. Hand-ordering an ids list is exactly the sort of silent
# transcription error that ships a game stuck in service mode.
#
# Each game carries a LIST of ports: FG-2 has one DSW word at $880000, FG-3 has
# a second at $890000. Port N occupies switch bits 16N..16N+15.
#
# pbancho uses PORT_MODIFY on gogomile's port, so it inherits bits 0 and 1;
# asurabus and asurabusa likewise inherit most of asurabld's two ports.
# ---------------------------------------------------------------------------
SERVICE = ("Service Mode", 0x0001, 0x0001, {0x0001: "Off", 0x0000: "On"})
DEMO    = ("Demo Music",   0x0002, 0x0002, {0x0000: "Off", 0x0002: "On"})


def U(mask, default):
    """A MAME PORT_DIPUNUSED bit.

    It contributes to the DEFAULT byte string but is not emitted as a user
    dip. Recording these is not optional: leaving them out silently produced
    a gogomile default of FF,1D instead of FF,FF, because the four unused SW2
    bits all default to 1. A wrong default is not a cosmetic problem -- a
    fresh .CFG is all zeroes, and on Psikyo a wrong DIP byte silently enabled
    service mode and another value hung a game outright.
    """
    return ("(unused)", mask, default, None)

GOGOMILE_DIPS = [[
    SERVICE,
    DEMO,
    ("Difficulty", 0x000C, 0x000C,
     {0x0000: "Easy", 0x000C: "Normal", 0x0008: "Hard", 0x0004: "Very Hard"}),
    ("Language", 0x0030, 0x0030,
     {0x0010: "Chinese", 0x0030: "Japanese", 0x0000: "Korean", 0x0020: "English"}),
    ("Lives", 0x00C0, 0x00C0,
     {0x0000: "2", 0x00C0: "3", 0x0080: "4", 0x0040: "5"}),
    ("Flip Screen", 0x0100, 0x0100, {0x0100: "Off", 0x0000: "On"}),
    ("Coinage", 0x1C00, 0x1C00,
     {0x0400: "4C 1C", 0x1400: "3C 1C", 0x0C00: "2C 1C", 0x1C00: "1C 1C",
      0x1800: "1C 2C", 0x0800: "1C 3C", 0x1000: "1C 4C", 0x0000: "Free Play"}),
    # PORT_DIPUNUSED_DIPLOC: SW2:2, and SW2:6,7,8. The driver notes the manual
    # calls SW2:2 unused, and that gogomile ignores Coin B entirely.
    U(0x0200, 0x0200),
    U(0x2000, 0x2000), U(0x4000, 0x4000), U(0x8000, 0x8000),
]]

PBANCHO_DIPS = [[
    SERVICE,
    DEMO,
    ("Difficulty", 0x001C, 0x001C,
     {0x0008: "Easiest", 0x0010: "Easy", 0x001C: "Normal", 0x0000: "Normal (dup)",
      0x000C: "Normal (dup)", 0x0014: "Normal (dup)", 0x0018: "Hard",
      0x0004: "Hardest"}),
    ("Lives (Vs Mode)", 0x0060, 0x0060,
     {0x0000: "1", 0x0060: "2", 0x0020: "2 (dup)", 0x0040: "3"}),
    ("? Senin Mode ?", 0x0080, 0x0080, {0x0080: "Off", 0x0000: "On"}),
    ("Flip Screen", 0x0100, 0x0100, {0x0100: "Off", 0x0000: "On"}),
    ("Allow Versus Mode", 0x0200, 0x0200, {0x0000: "No", 0x0200: "Yes"}),
    ("Coin A", 0x1C00, 0x1C00,
     {0x0C00: "4C 1C", 0x1400: "3C 1C", 0x0400: "2C 1C", 0x1C00: "1C 1C",
      0x1000: "1C 2C", 0x0800: "1C 3C", 0x1800: "1C 4C", 0x0000: "Free Play"}),
    ("Coin B", 0xE000, 0xE000,
     {0x6000: "4C 1C", 0xA000: "3C 1C", 0x2000: "2C 1C", 0xE000: "1C 1C",
      0x8000: "1C 2C", 0x4000: "1C 3C", 0xC000: "1C 4C", 0x0000: "Free Play"}),
]]


# ---- FG-3 -----------------------------------------------------------------
# Two 16-bit DIP ports, DSW1 at $880000 and DSW2 at $890000.
#
# Note DSW1's "Coinage Mode" defaults to 0x0000, not to its mask. It is the one
# port in either driver whose default is not all-ones, and it is precisely the
# sort of thing that is invisible until a coin does nothing.
#
# The two `0x0000` coinage settings carry PORT_CONDITION in MAME -- Coin A
# reads Free Play only when Coin B is also 0. A `.mra` has no conditionals, so
# the label says both and the condition is stated here rather than lost.
def _coinage(shift):
    v = lambda x: x << shift
    return {
        v(0x8): "8C 1C",  v(0x9): "7C 1C",  v(0xA): "6C 1C",  v(0xB): "5C 1C",
        v(0xC): "4C 1C",  v(0xD): "3C 1C",  v(0xE): "2C 1C",  v(0x1): "2C 1C (dup)",
        v(0xF): "1C 1C",  v(0x6): "1C 2C",  v(0x5): "1C 3C",  v(0x4): "1C 4C",
        v(0x3): "1C 5C",  v(0x2): "2C Start / 1C Continue",
        v(0x7): "Error!!",
        v(0x0): "1C 1C / Free Play if both 0",
    }

ASURA_DSW2 = [
    ("Flip Screen", 0x0001, 0x0001, {0x0001: "Off", 0x0000: "On"}),
    ("Difficulty", 0x000E, 0x000E,
     {0x0000: "Easiest", 0x0008: "Very Easy", 0x0004: "Easier", 0x000C: "Easy",
      0x000E: "Normal", 0x0002: "Hard", 0x000A: "Very Hard", 0x0006: "Hardest"}),
    ("Damage", 0x0030, 0x0030,
     {0x0020: "75%", 0x0030: "100%", 0x0010: "125%", 0x0000: "150%"}),
    ("Max Rounds", 0x00C0, 0x00C0,
     {0x0000: "1", 0x00C0: "3", 0x0080: "5", 0x0040: "Error!!"}),
    ("Coin B", 0x0F00, 0x0F00, _coinage(8)),
    ("Coin A", 0xF000, 0xF000, _coinage(12)),
]


def _asura_dsw1(demo):
    return [
        SERVICE,
        ("Blood Color", 0x0002, 0x0002, {0x0002: "Red", 0x0000: "Green"}),
        ("Demo Sounds & Music", 0x000C, 0x000C, demo),
        ("Timer", 0x0030, 0x0030,
         {0x0000: "Slow", 0x0030: "Medium", 0x0010: "Fast", 0x0020: "Very Fast"}),
        # Defaults to Joint (0x0000), NOT to the mask.
        ("Coinage Mode", 0x00C0, 0x0000, {0x00C0: "Split", 0x0000: "Joint"}),
        # The whole SW2 bank is unused by both games.
        U(0x0100, 0x0100), U(0x0200, 0x0200), U(0x0400, 0x0400), U(0x0800, 0x0800),
        U(0x1000, 0x1000), U(0x2000, 0x2000), U(0x4000, 0x4000), U(0x8000, 0x8000),
    ]

ASURABLD_DIPS = [
    _asura_dsw1({0x000C: "Both On", 0x0008: "Music Off",
                 0x0004: "Both Off", 0x0000: "Both Off (dup)"}),
    ASURA_DSW2,
]
ASURABUS_DIPS = [
    _asura_dsw1({0x000C: "Both On", 0x0008: "Sounds Off",
                 0x0004: "Music Off", 0x0000: "Both Off"}),
    ASURA_DSW2,
]


# ---------------------------------------------------------------------------
# Board select, delivered as the index-1 mod byte.
#
#   bit 0   0 = FG-2 (M68000)          1 = FG-3 (M68EC020)
#   bit 1   SYSTEM ($800000) layout:
#           0 = gogomile   bit 1 = SERVICE1, bit 8 = COIN2
#           1 = pbancho    bit 1 = COIN2,    bit 8 = SERVICE1
#
# The second bit exists because pbancho does a PORT_MODIFY that SWAPS service
# and coin 2 against gogomile's layout -- and asurabld happens to use pbancho's
# arrangement, so one bit covers all six sets. Two games on the same board with
# different input wiring is not something a board-select bit alone can express.
# ---------------------------------------------------------------------------
MOD_FG3    = 0x01
MOD_SYSALT = 0x02

# <category> for the MiSTer menu, per family; clones inherit their parent's.
CATEGORY = {"gogomile": "Maze", "pbancho": "Puzzle", "asurabld": "Fight", "asurabus": "Fight"}

# One slot count for every game, so Start / Coin / Pause always land on the
# same joystick bits (8, 9, 10) whatever the game's button count. Unused slots
# are named "-", which is the convention the Psikyo `.mra` files use and the
# reason rtl/pause_control.sv can hard-code PAUSE_BIT = 10.
BUTTON_SLOTS = 4


# ---------------------------------------------------------------------------
# The games.
# ---------------------------------------------------------------------------
GAMES = {
    # ---- FG-2 ----
    "gogomile": dict(
        board="fg2", mod=0x00, buttons=1,
        parent=None, zipname="gogomile",
        title="Susume! Mile Smile / Go Go! Mile Smile (newer)",
        year="1995", region="Japan", dips=GOGOMILE_DIPS,
        regions={
            "maincpu":  [G("load16_byte", "fp2n.rom2", "fp1n.rom1")],
            "audiocpu": [G("load", "fs1.rom24")],
            "tiles_l0": [G("swap16", "lh5370h6.rom3")],
            "tiles_l1": [G("pair32", "lh5370h7.rom15", "lh5370h8.rom11"),
                         G("pair32", "lh5370h9.rom16", "lh5370ha.rom12")],
            "tiles_l2": [G("swap16", "lh5370hb.rom19")],
            "sprites":  [G("swap16", "lh537k2r.rom20")],
            "oki":      [G("load", "lh538n1d.rom25")],
        }),
    "gogomileo": dict(
        board="fg2", mod=0x00, buttons=1,
        parent="gogomile", zipname="gogomileo",
        title="Susume! Mile Smile / Go Go! Mile Smile (older)",
        year="1995", region="Japan", dips=GOGOMILE_DIPS,
        regions={
            "maincpu":  [G("load16_byte", "fp2.rom2", "fp1.rom1")],
            "audiocpu": [G("load", "fs1.rom24")],
            "tiles_l0": [G("swap16", "lh5370h6.rom3")],
            "tiles_l1": [G("pair32", "lh5370h7.rom15", "lh5370h8.rom11"),
                         G("pair32", "lh5370h9.rom16", "lh5370ha.rom12")],
            "tiles_l2": [G("swap16", "lh5370hb.rom19")],
            "sprites":  [G("swap16", "lh537k2r.rom20")],
            "oki":      [G("load", "lh538n1d.rom25")],
        }),
    "pbancho": dict(
        board="fg2", mod=MOD_SYSALT, buttons=1,
        parent=None, zipname="pbancho",
        title="Gyakuten!! Puzzle Bancho (Japan, set 1)",
        year="1996", region="Japan", dips=PBANCHO_DIPS,
        regions={
            "maincpu":  [G("load16_byte", "no1..rom2", "no2..rom1")],
            "audiocpu": [G("load", "no4.rom23")],
            "tiles_l0": [G("swap16", "60.rom3")],
            "tiles_l1": [G("pair32", "59.rom15", "61.rom11")],
            # MAME loads 60.rom3 here too, commented "?maybe?" -- see the
            # roadmap's open item. Reproduced as the driver has it.
            "tiles_l2": [G("swap16", "60.rom3")],
            "sprites":  [G("swap16", "58.rom20")],
            "oki":      [G("load", "n03.rom25")],
        }),
    "pbanchoa": dict(
        board="fg2", mod=MOD_SYSALT, buttons=1,
        parent="pbancho", zipname="pbanchoa",
        title="Gyakuten!! Puzzle Bancho (Japan, set 2)",
        year="1996", region="Japan", dips=PBANCHO_DIPS,
        regions={
            "maincpu":  [G("load16_byte", "no1.rom2", "no2.rom1")],
            "audiocpu": [G("load", "no4.rom23")],
            "tiles_l0": [G("swap16", "60.rom3")],
            "tiles_l1": [G("pair32", "59.rom15", "61.rom11")],
            "tiles_l2": [G("swap16", "60.rom3")],
            "sprites":  [G("swap16", "58.rom20")],
            "oki":      [G("load", "n03.rom25")],
        }),

    # ---- FG-3 ----
    # asurabld's sprite region declares 32 MB but loads only banks 2..d, so it
    # opens AND closes with a 4 MB hole; see GAP().
    "asurabld": dict(
        board="fg3", mod=MOD_FG3 | MOD_SYSALT, buttons=3,
        parent=None, zipname="asurabld",
        title="Asura Blade - Sword of Dynasty (Japan)",
        year="1998", region="Japan", dips=ASURABLD_DIPS,
        regions={
            "maincpu":  [G("load32_byte", "pgm3.u1", "pgm2.u2", "pgm1.u3", "pgm0.u4")],
            "audiocpu": [G("load", "srom.u7")],
            "tiles_l0": [G("pair32", "bg1113.u23", "bg1012.u22")],
            "tiles_l1": [G("pair32", "bg2123.u24", "bg2022.u25")],
            "tiles_l2": [G("swap16", "map.u5")],
            "sprites":  [GAP(0x400000),
                         G("swap16", "sp23.u14"), G("swap16", "sp45.u15"),
                         G("swap16", "sp67.u16"), G("swap16", "sp89.u17"),
                         G("swap16", "spab.u18"), G("swap16", "spcd.u19"),
                         GAP(0x400000)],
            "oki":      [G("load", "pcm.u6")],
        }),
    "asurabus": dict(
        board="fg3", mod=MOD_FG3 | MOD_SYSALT, buttons=3,
        parent=None, zipname="asurabus",
        title="Asura Buster - Eternal Warriors (USA)",
        year="2001", region="USA", dips=ASURABUS_DIPS,
        regions={
            "maincpu":  [G("load32_byte", "uspgm3.u1", "uspgm2.u2", "uspgm1.u3", "uspgm0.u4")],
            "audiocpu": [G("load", "srom.u7")],
            "tiles_l0": [G("pair32", "bg1113.u23", "bg1012.u22")],
            "tiles_l1": [G("pair32", "bg2123.u24", "bg2022.u25")],
            "tiles_l2": [G("swap16", "map.u5")],
            "sprites":  [G("swap16", "sp01.u13"), G("swap16", "sp23.u14"),
                         G("swap16", "sp45.u15"), G("swap16", "sp67.u16"),
                         G("swap16", "sp89.u17"), G("swap16", "spab.u18"),
                         G("swap16", "spcd.u19"), G("swap16", "spef.u20")],
            "oki":      [G("load", "opm.u6")],
        }),
    "asurabusj": dict(
        board="fg3", mod=MOD_FG3 | MOD_SYSALT, buttons=3,
        parent="asurabus", zipname="asurabusj",
        title="Asura Buster - Eternal Warriors (Japan, set 1)",
        year="2000", region="Japan", dips=ASURABUS_DIPS,
        regions={
            "maincpu":  [G("load32_byte", "pgm3.u1", "pgm2.u2", "pgm1.u3", "pgm0.u4")],
            "audiocpu": [G("load", "srom.u7")],
            "tiles_l0": [G("pair32", "bg1113.u23", "bg1012.u22")],
            "tiles_l1": [G("pair32", "bg2123.u24", "bg2022.u25")],
            "tiles_l2": [G("swap16", "map.u5")],
            "sprites":  [G("swap16", "sp01.u13"), G("swap16", "sp23.u14"),
                         G("swap16", "sp45.u15"), G("swap16", "sp67.u16"),
                         G("swap16", "sp89.u17"), G("swap16", "spab.u18"),
                         G("swap16", "spcd.u19"), G("swap16", "spef.u20")],
            "oki":      [G("load", "opm.u6")],
        }),
    "asurabusja": dict(
        board="fg3", mod=MOD_FG3 | MOD_SYSALT, buttons=3,
        parent="asurabus", zipname="asurabusja",
        title="Asura Buster - Eternal Warriors (Japan, set 2)",
        year="2000", region="Japan", dips=ASURABUS_DIPS,
        regions={
            "maincpu":  [G("load32_byte", "pgm3_583a.u1", "pgm2_0ff4.u2",
                           "pgm1_bac7.u3", "pgm0_193a.u4")],
            "audiocpu": [G("load", "srom.u7")],
            "tiles_l0": [G("pair32", "bg1113.u23", "bg1012.u22")],
            "tiles_l1": [G("pair32", "bg2123.u24", "bg2022.u25")],
            "tiles_l2": [G("swap16", "map.u5")],
            "sprites":  [G("swap16", "sp01.u13"), G("swap16", "sp23.u14"),
                         G("swap16", "sp45.u15"), G("swap16", "sp67.u16"),
                         G("swap16", "sp89.u17"), G("swap16", "spab.u18"),
                         G("swap16", "spcd.u19"), G("swap16", "spef.u20")],
            "oki":      [G("load", "opm.u6")],
        }),
    # The ARCADIA review build is the only set with a fourth button
    # (PORT_MODIFY on INPUTS, "has pause function on P1 button 4").
    "asurabusjr": dict(
        board="fg3", mod=MOD_FG3 | MOD_SYSALT, buttons=4,
        parent="asurabus", zipname="asurabusjr",
        title="Asura Buster - Eternal Warriors (Japan) (ARCADIA review build)",
        year="2000", region="Japan", dips=ASURABUS_DIPS,
        regions={
            "maincpu":  [G("load32_byte", "24-31.pgm3", "16-23.pgm2",
                           "8-15.pgm1", "0-7.pgm0")],
            "audiocpu": [G("load", "srom.u7")],
            "tiles_l0": [G("pair32", "bg1113.u23", "bg1012.u22")],
            "tiles_l1": [G("pair32", "bg2123.u24", "bg2022.u25")],
            "tiles_l2": [G("swap16", "map.u5")],
            "sprites":  [G("swap16", "sp01.u13"), G("swap16", "sp23.u14"),
                         G("swap16", "sp45.u15"), G("swap16", "sp67.u16"),
                         G("swap16", "sp89.u17"), G("swap16", "spab.u18"),
                         G("swap16", "spcd.u19"), G("swap16", "spef.u20")],
            "oki":      [G("load", "opm.u6")],
        }),
}

# Region order in the image. The localparam that fixes each offset is
# `FG2_BASE_<NAME>` for FG-2 and `FG3_BASE_<NAME>` for FG-3.
REGION_ORDER = ["maincpu", "audiocpu", "tiles_l0", "tiles_l1",
                "tiles_l2", "sprites", "oki"]
BASE_PREFIX = {"fg2": "FG2_BASE_", "fg3": "FG3_BASE_"}
SOURCE_FILE = {"fg2": "MAME fuukifg2.cpp", "fg3": "MAME fuukifg3.cpp"}


def base_name(board, region):
    return BASE_PREFIX[board] + region.upper()


def read_sdram_map():
    """Parse the BASE_ offsets out of the RTL, which is the authority."""
    txt = SDRAM_SV.read_text(encoding="utf-8", errors="replace")
    bases = {}
    for m in re.finditer(
            r"localparam\s+logic\s*\[\d+:\d+\]\s*(FG[23]_BASE_\w+)\s*=\s*\d+'h([0-9a-fA-F_]+)",
            txt):
        bases[m.group(1)] = int(m.group(2).replace("_", ""), 16)
    missing = [base_name(b, r) for b in BASE_PREFIX for r in REGION_ORDER
               if base_name(b, r) not in bases]
    if missing:
        sys.exit(f"{SDRAM_SV.name} does not define {', '.join(missing)}")
    return bases


def build_group(z, names, g):
    k, p = g["kind"], g["parts"]
    if k == "gap":          return bytearray(g["size"])
    if k == "load":         return rom_load(z, names, p[0])
    if k == "swap16":       return rom_load16_word_swap(z, names, p[0])
    if k == "load16_byte":  return rom_load16_byte(z, names, p[0], p[1])
    if k == "load32_byte":  return rom_load32_byte(z, names, p[0], p[1], p[2], p[3])
    if k == "pair32":       return rom_load32_word_swap(z, names, p[0], p[1])
    raise ValueError(f"unknown group kind {k}")


# Candidate `.mra` forms per group kind, tried in order until one reproduces
# the ground truth. Deliberately includes the WRONG ones: if the right answer
# were obvious there would be no need to search, and the search is the point.
CANDIDATES = {
    "load":        [None],                                   # bare <part>
    "gap":         [None],
    "swap16":      [("12",), ("21",)],
    "load16_byte": [("01", "10"), ("10", "01")],
    "load32_byte": [("0001", "0010", "0100", "1000"),
                    ("1000", "0100", "0010", "0001"),
                    ("0002", "0020", "0200", "2000")],
    "pair32":      [("0012", "1200"), ("1200", "0012"),
                    ("0021", "2100"), ("2100", "0021"),
                    ("0034", "3400"), ("3400", "0034")],
}
OUTPUT_BITS = {"swap16": 16, "load16_byte": 16,
               "load32_byte": 32, "pair32": 32}


def pick_map(z, names, g, truth):
    """Find the `.mra` form that reproduces `truth` exactly."""
    if g["kind"] in ("load", "gap"):
        return None
    datas = [z.read(names[p]) for p in g["parts"]]
    bits = OUTPUT_BITS[g["kind"]]
    for maps in CANDIDATES[g["kind"]]:
        got = mra_lib.interleave(list(zip(datas, maps)), bits)
        if got == bytes(truth):
            return maps
    raise SystemExit(
        f"no candidate map reproduces {g['kind']} {g['parts']} -- "
        f"add the right form to CANDIDATES rather than guessing")


def dip_xml(ports):
    """Derive `bits`, `ids` and the default byte string from MAME's encoding.

    A MiSTer `<dip>`'s ids are indexed by the value assembled from the listed
    bits, LSB first. Deriving that from the {value: label} map is what keeps
    the ordering honest -- writing the ids by hand is how a game ends up
    booting into service mode.

    Port N is offset by 16 bits, so FG-3's DSW2 at $890000 lands on switch
    bits 16..31 and reaches the core as the second pair of DIP bytes.
    """
    out = []
    default_bytes = []
    for port_index, dips in enumerate(ports):
        default = 0
        for name, mask, dflt, settings in dips:
            default |= dflt
            if settings is None:      # PORT_DIPUNUSED: default only, not emitted
                continue
            bit_positions = [i for i in range(16) if mask & (1 << i)]
            n = len(bit_positions)
            ids = []
            for idx in range(1 << n):
                value = 0
                for j, bp in enumerate(bit_positions):
                    if idx & (1 << j):
                        value |= (1 << bp)
                ids.append(settings.get(value, "-"))
            # ids and bits are comma-separated lists: a comma inside a label
            # shifts every later entry by one and the game reads a different
            # setting than the OSD shows.
            for label in ids:
                if "," in label:
                    sys.exit(f"dip '{name}': label {label!r} contains a comma")
            bits = [16 * port_index + b for b in bit_positions]
            out.append((esc(name), ",".join(str(b) for b in bits),
                        esc(",".join(ids))))
        # Byte 0 is the low half of the port's word, byte 1 the high half;
        # the core wires them that way.
        default_bytes += [default & 0xFF, (default >> 8) & 0xFF]
    return out, default_bytes


def esc(s):
    """XML-escape a value that came from MAME.

    Not defensive padding: the driver's own dip name "Demo Sounds & Music"
    contains a bare ampersand, and the well-formedness gate below rejected the
    first FG-3 file because of it. A `.mra` MiSTer cannot parse loads nothing
    and shows no DIPs, with every symptom pointing at the RTL.
    """
    return escape(str(s), {'"': "&quot;"})


# ---------------------------------------------------------------------------
# Where each `.mra` goes, per the MiSTer MRA documentation
# (https://mister-devel.github.io/MkDocs_MiSTer/developer/mra/).
#
# A parent set sits directly in the Arcade folder; every CLONE goes in
# `_alternatives/_<parent>/`, so the top level lists one entry per game rather
# than one per ROM revision. Files are named from the MAME description -- the
# same string the `<name>` element carries -- not from the setname, because the
# filename is what the user sees in the menu.
#
# The parent FOLDER drops the parenthesised qualifier: "Gunbird (World)" gives
# `_Gunbird`, which is the grouping the sibling Psikyo core ships and what the
# folder is for.
# ---------------------------------------------------------------------------
_ILLEGAL = r'<>:"/\|?*'


def mra_filename(title):
    """MAME description -> a filename, keeping the description readable.

    gogomile's description contains a slash ("Susume! Mile Smile / Go Go! Mile
    Smile"), which is a path separator on every OS. It becomes " - ", matching
    how MAME itself joins dual titles elsewhere; the `<name>` element keeps the
    description verbatim.
    """
    name = title.replace(" / ", " - ")
    for ch in _ILLEGAL:
        name = name.replace(ch, "-")
    return name + ".mra"


def alt_folder(parent_title):
    base = parent_title.split(" (")[0]
    return "_" + mra_filename(base)[:-4]


def out_path_for(setname, game, out_dir):
    if not game["parent"]:
        return out_dir / mra_filename(game["title"])
    parent = GAMES[game["parent"]]
    return (out_dir / "_alternatives" / alt_folder(parent["title"])
            / mra_filename(game["title"]))


def buttons_xml(n):
    """One `<buttons>` line, padded to BUTTON_SLOTS so Pause is always bit 10."""
    names = [f"Button {i + 1}" for i in range(n)] + ["-"] * (BUTTON_SLOTS - n)
    names += ["Start", "Coin", "Pause"]
    default = ["Y", "B", "A", "X"][:n] + ["Start", "Select", "R"]
    return (f'<buttons names="{",".join(names)}" '
            f'default="{",".join(default)}" count="{n}"/>')


def emit(setname, game, bases, zip_dir, out_dir, check_only):
    zpath = zip_dir / f"{game['zipname']}.zip"
    if not zpath.exists() and game["parent"]:
        zpath = zip_dir / f"{game['parent']}.zip"
    if not zpath.exists():
        print(f"  {setname:11s} SKIP      no {game['zipname']}.zip -- not generated, "
              f"because it cannot be verified")
        return None

    board = game["board"]

    with zipfile.ZipFile(zpath) as z:
        names = {n.split("/")[-1]: n for n in z.namelist()}

        body, truth_image, cursor = [], bytearray(), 0
        for region in REGION_ORDER:
            base = bases[base_name(board, region)]
            if base < cursor:
                sys.exit(f"{setname}: {region} base 0x{base:X} overlaps the previous region")
            if base > cursor:
                # Space BETWEEN regions -- MAME has no region here at all, so
                # 0xFF marks it as unmapped rather than looking like real data
                # in a probe dump. Holes INSIDE a region use GAP(), which
                # fills 0x00 to match what MAME's region contains.
                pad = base - cursor
                body.append(f'\t\t<part repeat="0x{pad:X}">FF</part>')
                truth_image += b"\xFF" * pad
                cursor = base

            for g in game["regions"][region]:
                truth = build_group(z, names, g)
                maps = pick_map(z, names, g, truth)
                if g["kind"] == "gap":
                    body.append(f'\t\t<part repeat="0x{g["size"]:X}">00</part>')
                elif maps is None:
                    body.append(f'\t\t<part name="{g["parts"][0]}"/>')
                else:
                    bits = OUTPUT_BITS[g["kind"]]
                    body.append(f'\t\t<interleave output="{bits}">')
                    for p, m in zip(g["parts"], maps):
                        body.append(f'\t\t\t<part name="{p}" map="{m}"/>')
                    body.append("\t\t</interleave>")
                truth_image += truth
                cursor += len(truth)
            body.append("")

        dips, default_bytes = dip_xml(game["dips"])

        zipattr = game["zipname"] + ".zip"
        if game["parent"]:
            zipattr += "|" + game["parent"] + ".zip"

        # Flip Screen is left in the file but commented out: the core does not
        # implement flipping yet, so offering the switch would only mislead.
        sw = "\n".join(
            (f'\t\t<!-- <dip name="{n}" bits="{b}" ids="{i}"/> -->' if n == "Flip Screen"
             else f'\t\t<dip name="{n}" bits="{b}" ids="{i}"/>') for n, b, i in dips)
        dflt = ",".join(f"{b:02X}" for b in default_bytes)

        xml = f"""<misterromdescription>
\t<about author="Paul Priest" webpage="https://github.com/ppriest/Arcade-Fuuki_MiSTer" source="{SOURCE_FILE[board]}"/>
\t<name>{game['title']}</name>
\t<setname>{setname}</setname>
\t<rbf>Arcade-Fuuki</rbf>
\t<year>{game['year']}</year>
\t<manufacturer>Fuuki</manufacturer>
\t<category>{CATEGORY[game['parent'] or game['zipname']]}</category>
\t<rotation>horizontal</rotation>
\t<region>{game['region']}</region>
\t<players>2</players>
\t<joystick>8-way</joystick>

\t<!-- Board select: bit 0 = FG-2 / FG-3, bit 1 = SYSTEM port wiring (gogomile / pbancho+asura). -->
\t<rom index="1"><part>{game['mod']:02X}</part></rom>

\t<rom index="0" zip="{zipattr}" md5="none" address="0x30000000">
{chr(10).join(body).rstrip()}
\t</rom>

\t{buttons_xml(game['buttons'])}

\t<switches default="{dflt}">
{sw}
\t</switches>
</misterromdescription>
"""

        out_path = out_path_for(setname, game, out_dir)
        if not check_only:
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(xml, encoding="utf-8")

        # ---- the check that matters ----
        tmp = out_path if not check_only else out_dir / f".{setname}.check.mra"
        if check_only:
            tmp.parent.mkdir(parents=True, exist_ok=True)
            tmp.write_text(xml, encoding="utf-8")
        # Well-formedness gate. LESSONS_LEARNED: an edited comment block once
        # left stray character data containing a bare '<', MiSTer's parser
        # rejected the file, and the result was DIPs gone from the OSD, the ROM
        # never loaded, and a black screen -- with every symptom pointing at the
        # RTL. Cheap to check, so check it every time rather than before deploy.
        try:
            ET.parse(str(tmp))
        except ET.ParseError as e:
            sys.exit(f"  {setname}: generated .mra is not well-formed XML: {e}")
        rebuilt = mra_lib.build_image(str(tmp), str(zpath))
        if check_only:
            tmp.unlink()

        ok = rebuilt == bytes(truth_image)
        status = "OK " if ok else "MISMATCH"
        rel = out_path.relative_to(out_dir).as_posix()
        print(f"  {setname:11s}{status} {len(truth_image):>11,} bytes "
              f"({len(truth_image)/1048576:5.1f} MB)  mod {game['mod']:02X}  "
              f"DSW {dflt}\n              {rel}")
        if not ok:
            for i in range(min(len(rebuilt), len(truth_image))):
                if rebuilt[i] != truth_image[i]:
                    sys.exit(f"    first difference at 0x{i:X}: "
                             f"mra={rebuilt[i]:02X} truth={truth_image[i]:02X}")
            sys.exit(f"    length differs: mra={len(rebuilt)} truth={len(truth_image)}")
        return len(truth_image)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="verify only, write nothing")
    ap.add_argument("--roms", default=str(REPO / "roms"))
    ap.add_argument("--out", default=str(REPO / "releases"))
    ap.add_argument("--only", help="build just this setname")
    a = ap.parse_args()

    mra_lib._selftest()

    bases = read_sdram_map()
    print("SDRAM map, from rtl/memory/fuuki_sdram_top.sv:")
    for board in ("fg2", "fg3"):
        print(f"  {board.upper()}:")
        for region in REGION_ORDER:
            n = base_name(board, region)
            print(f"    {region:10s} {n:20s} 0x{bases[n]:07X}")
    print()

    for setname, game in GAMES.items():
        if a.only and setname != a.only:
            continue
        emit(setname, game, bases, Path(a.roms), Path(a.out), a.check)


main()
