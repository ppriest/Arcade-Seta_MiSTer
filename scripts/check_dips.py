#!/usr/bin/env python3
"""Check every .mra's DIP switches and button count against MAME's -listxml.

    python scripts/check_dips.py [releases/...mra ...]

Independent of build_mra.py / extract_dips.py: the switches are read the way
Main_MiSTer's support/arcade/mra_loader.cpp reads them (bits="first,last", a
range; option i puts i in that range; default="b0,b1,b2" is the switch
vector's bytes), carried through the core's wiring, and compared with the
dipswitch masks, values and defaults MAME's own XML gives:

    DSW  bits 15-8  sw[0]  (seta_dsw_r / dsw1_r offset 0)  mra bits 0-7
    DSW  bits  7-0  sw[1]  (offset 1)                      mra bits 8-15
    COINS bits 7-4  sw[2][7:4]                             mra bits 20-23

Reports, per set: a MAME switch with no mra dip covering exactly its bits, a
setting whose mra option is missing or named differently, a wrong default,
mra dips MAME does not have, and the button count against MAME's <control>.
"""
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import MAME_DIR, MAME_EXE, NO_WINDOW  # noqa: E402


def mra_bit(tag, k):
    if tag == "DSW":
        return k - 8 if k >= 8 else k + 8
    if tag == "COINS" and 4 <= k <= 7:
        return 16 + k
    return None


def norm(s):
    return re.sub(r"\s+", " ", s.strip().lower())


def check(path, xml_cache):
    root = ET.parse(path).getroot()
    setname = root.findtext("setname")
    if setname not in xml_cache:
        out = subprocess.run([str(MAME_EXE), "-listxml", setname], cwd=str(MAME_DIR),
                             capture_output=True, text=True, **NO_WINDOW).stdout
        xml_cache[setname] = ET.fromstring(out).find(f"machine[@name='{setname}']")
    m = xml_cache[setname]
    probs, notes = [], []

    sw = root.find("switches")
    defaults = [int(b, 16) for b in sw.get("default").split(",")] if sw is not None else []
    vec = sum(b << (8 * i) for i, b in enumerate(defaults))
    dips = {}
    for d in (sw.findall("dip") if sw is not None else []):
        r = [int(x) for x in d.get("bits").split(",")]
        if len(r) > 2:
            probs.append(f"dip '{d.get('name')}': bits=\"{d.get('bits')}\" is a list; "
                         f"MiSTer reads only {r[0]},{r[1]}")
        lo, hi = r[0], r[1] if len(r) > 1 else r[0]
        dips[(lo, hi)] = (d.get("name"), d.get("ids").split(","))

    used = set()
    for ds in m.findall("dipswitch"):
        name, tag, mask = ds.get("name"), ds.get("tag"), int(ds.get("mask"))
        ks = [k for k in range(16) if mask >> k & 1]
        bits = [mra_bit(tag, k) for k in ks]
        if None in bits:
            probs.append(f"'{name}': MAME {tag} mask {mask:#x} is not wired to a switch byte")
            continue
        lo, hi = min(bits), max(bits)
        if sorted(bits) != list(range(lo, hi + 1)):
            probs.append(f"'{name}': mask {mask:#x} is not contiguous in the switch vector")
            continue
        if (lo, hi) not in dips:
            dv = ds.find("dipvalue[@default='yes']")
            want = 0
            for k, b in zip(ks, bits):
                if int(dv.get("value")) >> k & 1:
                    want |= 1 << (b - lo)
            got = (vec >> lo) & ((1 << (hi - lo + 1)) - 1)
            if got != want:
                probs.append(f"'{name}': not in the mra, default bits {got:#x}, MAME {want:#x}")
            elif name == "Unused" or re.match(r"unknown\b", name, re.I):
                # build_mra comments these out; the default must still hold
                pass
            else:
                probs.append(f"'{name}': no mra dip at bits {lo},{hi}")
            continue
        used.add((lo, hi))
        dname, ids = dips[(lo, hi)]
        # the OSD's 28 columns (build_mra.py osd_fit): past them the value
        # is drawn off the screen
        for i in ids:
            if 1 + len(dname.rstrip()) + 1 + len(i) > 28:
                probs.append(f"'{dname}' = '{i}': {1 + len(dname.rstrip()) + 1 + len(i)} "
                             f"columns, the OSD shows 28")
                break
        if norm(dname) != norm(name):
            notes.append(f"'{name}': mra name '{dname}'")
        dflt_idx = None
        for dv in ds.findall("dipvalue"):
            v = int(dv.get("value"))
            idx = 0
            for k, b in zip(ks, bits):
                if v >> k & 1:
                    idx |= 1 << (b - lo)
            if dv.get("default") == "yes":
                dflt_idx = idx
            if idx >= len(ids):
                probs.append(f"'{name}' = '{dv.get('name')}': option {idx} missing "
                             f"({len(ids)} ids)")
            elif norm(ids[idx]) != norm(dv.get("name")):
                notes.append(f"'{name}' option {idx}: mra '{ids[idx]}', MAME '{dv.get('name')}'")
        got = (vec >> lo) & ((1 << (hi - lo + 1)) - 1)
        if dflt_idx is not None and got != dflt_idx:
            probs.append(f"'{name}': default option {got} ('{ids[got] if got < len(ids) else '?'}'),"
                         f" MAME {dflt_idx} ('{ids[dflt_idx] if dflt_idx < len(ids) else '?'}')")
    for key, (dname, _) in dips.items():
        # sw[3] bit 0: the core's Flip Screen (build_mra.py CORE_FLIP_SETS)
        if key == (24, 24) and dname == "Flip Screen":
            continue
        if key not in used:
            probs.append(f"mra dip '{dname}' at bits {key[0]},{key[1]} is not a MAME switch")

    btn = root.find("buttons")
    ctl = m.find("input/control[@player='1']")
    mame_b = int(ctl.get("buttons", 0)) if ctl is not None else 0
    mra_b = int(btn.get("count")) if btn is not None else 0
    names = btn.get("names").split(",")[:mra_b] if btn is not None else []
    if mra_b != mame_b:
        notes.append(f"buttons: mra {mra_b} ({', '.join(names)}), MAME control buttons={mame_b}")
    return setname, probs, notes


def main():
    paths = [Path(p) for p in sys.argv[1:]] or sorted((REPO / "releases").rglob("*.mra"))
    cache, bad = {}, 0
    for p in paths:
        s, probs, notes = check(p, cache)
        print(f"{s:12s} {'FAIL' if probs else 'ok  '}  {p.relative_to(REPO)}")
        for x in probs:
            print(f"    PROBLEM {x}")
        for x in notes:
            print(f"    note    {x}")
        bad += bool(probs)
    print(f"\n{len(paths)} mra files, {bad} with problems")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
