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
from build_region import region_image, region_size, zip_for
import extract_dips

SDRAM_SV = REPO / "rtl" / "memory" / "seta_sdram_top.sv"
CFG_SV = REPO / "rtl" / "seta_board_cfg.sv"
ROMS = REPO / "roms"
OUT_DIR = REPO / "releases"

# The order the regions occupy in the image. Their offsets come from the RTL.
REGION_ORDER = ["maincpu", "gfx1", "x1snd"]
BASE_NAME = {"maincpu": "BASE_MAINCPU", "gfx1": "BASE_GFX1", "x1snd": "BASE_X1SND"}


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
    missing = [BASE_NAME[r] for r in REGION_ORDER if BASE_NAME[r] not in bases]
    if missing:
        sys.exit(f"{SDRAM_SV.name} does not define {', '.join(missing)}")
    return bases


def read_game_enum():
    """setname -> mod byte, from seta_board_cfg.sv's game_t."""
    txt = CFG_SV.read_text(encoding="utf-8", errors="replace")
    out = {}
    for m in re.finditer(r"GAME_(\w+)\s*=\s*4'd(\d+)", txt):
        out[m.group(1).lower()] = int(m.group(2))
    if not out:
        sys.exit(f"{CFG_SV.name} defines no GAME_* enum")
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
# MAME ROM_START loaders, used as ground truth. One implementation.
# ---------------------------------------------------------------------------
def rom_load(z, name):
    return bytearray(z.read(name))


def rom_load16_word_swap(z, name):
    d = bytearray(z.read(name))
    d[0::2], d[1::2] = d[1::2], d[0::2]
    return d


def rom_load16_byte(z, even, odd):
    a, b = z.read(even), z.read(odd)
    if len(a) != len(b):
        sys.exit(f"{even} and {odd} differ in length ({len(a)} vs {len(b)})")
    out = bytearray(len(a) * 2)
    out[0::2] = a
    out[1::2] = b
    return out


def group_truth(rs, g):
    if g["kind"] == "load":
        return rom_load(rs, g["parts"][0])
    if g["kind"] == "swap16":
        return rom_load16_word_swap(rs, g["parts"][0])
    if g["kind"] == "load16_byte":
        return rom_load16_byte(rs, g["parts"][0], g["parts"][1])
    raise ValueError(g["kind"])


# Candidate `.mra` forms per group kind, tried in order until one reproduces
# the ground truth. Deliberately includes the wrong ones: if the right answer
# were obvious there would be no need to search, and the search is the point.
CANDIDATES = {
    "load":        [None],
    "swap16":      [("12",), ("21",)],
    "load16_byte": [("01", "10"), ("10", "01")],
}
OUTPUT_BITS = {"swap16": 16, "load16_byte": 16}


def pick_map(rs, g, truth):
    if g["kind"] == "load":
        return None
    datas = [rs.zip.read(f) for f in g["files"]]
    bits = OUTPUT_BITS[g["kind"]]
    for maps in CANDIDATES[g["kind"]]:
        if mra_lib.interleave(list(zip(datas, maps)), bits) == bytes(truth):
            return maps
    sys.exit(f"no candidate map reproduces {g['kind']} {g['parts']} -- add the "
             f"right form to CANDIDATES rather than guessing")


# ---------------------------------------------------------------------------
# ROM_START records -> .mra groups
# ---------------------------------------------------------------------------
def groups_for(records, region, setname):
    """Pair the driver's records into the groups a `.mra` can express.

    Two ROM_LOAD16_BYTE records at dest d and d+1 of the same length are one
    interleave; anything else stands alone. Ordering is by DEST, not by the
    order the records appear, because the driver writes them in whatever order
    reads best.
    """
    recs = sorted(records, key=lambda r: (r[2] & ~1, r[2] & 1))
    out = []
    i = 0
    while i < len(recs):
        kind, name, dest, ln, crc = recs[i]
        if kind == "continue":
            sys.exit(f"{setname}/{region}: ROM_CONTINUE is not yet handled here "
                     f"(no Group A set uses one)")
        if kind == "load16_byte":
            if i + 1 >= len(recs):
                sys.exit(f"{setname}/{region}: an unpaired ROM_LOAD16_BYTE at "
                         f"{dest:#x}")
            k2, n2, d2, l2, c2 = recs[i + 1]
            if k2 != "load16_byte" or d2 != dest + 1 or l2 != ln:
                sys.exit(f"{setname}/{region}: {name} at {dest:#x} has no matching "
                         f"odd half")
            out.append({"kind": "load16_byte", "parts": [name, n2],
                        "crcs": [crc, c2], "size": ln * 2})
            i += 2
            continue
        if kind == "load":
            out.append({"kind": "load", "parts": [name], "crcs": [crc], "size": ln})
        elif kind == "load16_wswap":
            out.append({"kind": "swap16", "parts": [name], "crcs": [crc],
                        "size": ln})
        else:
            sys.exit(f"{setname}/{region}: unhandled record kind {kind}")
        i += 1
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
        default = 0
        for name, mask, dflt, settings in dips:
            default |= dflt
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


def buttons_xml(nbuttons):
    names = ["Button 1", "Button 2"][:nbuttons] + ["Start", "Coin", "Service"]
    default = ["A", "B"][:nbuttons] + ["Start", "Select", "R"]
    return (f'<buttons names="{esc(",".join(names))}" '
            f'default="{esc(",".join(default))}" count="{nbuttons + 3}"/>')


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
    if setname not in gl:
        sys.exit(f"{setname}: no GAME() line in the driver")
    info = gl[setname]
    zippath, key = zip_for(setname, all_blocks)
    body = all_blocks[setname]

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
        if not recs:
            sys.exit(f"{setname}: no {region} region")
        gs = groups_for(recs, region, setname)
        blob = bytearray()
        for g in gs:
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
                     f"its base {base:#x} -- LAYOUT_A is too small for this set")
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
    lines.append(f'    <rom index="0" zip="{esc(zips)}" md5="none">')
    pos = 0
    for region in REGION_ORDER:
        base = bases[BASE_NAME[region]]
        if base > pos:
            lines.append(f'        <!-- pad to {base:#08x} -->')
            lines.append(f'        <part repeat="{base - pos}">00</part>')
            pos = base
        lines.append(f'        <!-- {region} -->')
        for g in all_groups[region]:
            maps = pick_map(rs, g, group_truth_from(rs, g))
            if maps is None:
                lines.append(f'        <part name="{esc(g["names"][0])}"/>')
            else:
                lines.append(f'        <interleave output="{OUTPUT_BITS[g["kind"]]}">')
                for fn, mp in zip(g["names"], maps):
                    lines.append(f'            <part name="{esc(fn)}" map="{mp}"/>')
                lines.append('        </interleave>')
            pos += g["size"]
        declared = region_size(body, region)
        got = sum(g["size"] for g in all_groups[region])
        if got < declared:
            lines.append(f'        <part repeat="{declared - got}">00</part>')
            pos += declared - got
    lines.append('    </rom>')
    lines.append('')
    lines.append(f'    <!-- which game, for rtl/seta_board_cfg.sv -->')
    lines.append(f'    <rom index="1"><part>{mod:02X}</part></rom>')
    lines.append('')

    ports = extract_dips.parse_ports(dip_blocks[info["inputs"]], dip_blocks, set())
    sw = split_ports(ports, setname)
    dips, defaults = dip_xml(sw)
    lines.append(f'    <switches default="{",".join(f"{b:02X}" for b in defaults)}" base="0">')
    for name, bits, ids in dips:
        lines.append(f'        <dip name="{name}" bits="{bits}" ids="{ids}"/>')
    lines.append('    </switches>')
    lines.append('')
    nb = 1 if "JOY_TYPE1_1BUTTON" in dip_blocks[info["inputs"]] else 2
    lines.append('    ' + buttons_xml(nb))
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


def group_truth_from(rs, g):
    if g["kind"] == "load":
        return bytearray(rs.zip.read(g["files"][0]))
    if g["kind"] == "swap16":
        d = bytearray(rs.zip.read(g["files"][0]))
        d[0::2], d[1::2] = d[1::2], d[0::2]
        return d
    a = rs.zip.read(g["files"][0])
    b = rs.zip.read(g["files"][1])

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
