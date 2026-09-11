#!/usr/bin/env python3
"""Check every `.mra`'s <switches> block against MAME's own -listxml.

    python scripts/check_dips.py                 # every .mra in releases/
    python scripts/check_dips.py kamenrid wits   # named sets

scripts/extract_dips.py builds the blocks by parsing INPUT_PORTS_START out of
seta.cpp. This checks the RESULT against a different source: MAME's -listxml,
which is the driver's port list after MAME itself has assembled it, defaults
included. A parser bug that drops a PORT_DIPSETTING or gets an order backwards
shows up here and cannot show up in a self-comparison.

What is compared, per DIP:

  * that it exists at all, by name and tag (COINS or DSW)
  * the BIT POSITIONS, through the sw[] convention Seta.sv and build_mra.py
    share -- sw[0] is the DSW's high byte, sw[1] its low byte, sw[2] the COINS
    port's top nibble, so `.mra` bit = 8 + b for DSW bits 0..7, b - 8 for DSW
    bits 8..15, and 16 + b for COINS bits 4..7
  * every SETTING, by the index the MiSTer OSD will use: the value assembled
    from the listed bits, LSB first
  * the DEFAULT, byte for byte against <switches default="..">

Exit code is the number of sets with a mismatch.
"""
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MAME_DIR = Path(os.getenv("MAME_DIR", r"C:\Emulation\Emulators\MAME"))
MAME_EXE = MAME_DIR / os.getenv("MAME_EXE", "arcade64.exe")

# The .mra file per setname, from the same table build_mra.py works off.
sys.path.insert(0, str(REPO / "scripts"))


def mame_dips(setname):
    """MAME's view: [(name, tag, mask, {value: label}, default_value)]."""
    p = subprocess.run([str(MAME_EXE), setname, "-listxml"],
                       capture_output=True, text=True, cwd=str(MAME_DIR))
    if p.returncode != 0 or not p.stdout.strip():
        sys.exit("mame -listxml %s failed: %s" % (setname, p.stderr[:200]))
    root = ET.fromstring(p.stdout)
    out = []
    for ds in root.iter("dipswitch"):
        tag = ds.get("tag")
        if tag not in ("COINS", "DSW"):
            continue
        mask = int(ds.get("mask"))
        vals, dflt = {}, None
        for dv in ds.findall("dipvalue"):
            v = int(dv.get("value"))
            vals[v] = dv.get("name")
            if dv.get("default") == "yes":
                dflt = v
        out.append((ds.get("name"), tag, mask, vals, dflt))
    return out


def mra_switches(path):
    """The .mra's view: (default bytes, [(name, [bits], [ids])])."""
    root = ET.parse(path).getroot()
    sw = root.find("switches")
    if sw is None:
        return None, []
    dflt = [int(b, 16) for b in sw.get("default", "").split(",") if b]
    dips = [(d.get("name"),
             [int(b) for b in d.get("bits").split(",")],
             d.get("ids").split(","))
            for d in sw.findall("dip")]
    return dflt, dips


def mra_bit(tag, b):
    """Where MAME's port bit b lands in the .mra's flat bit numbering."""
    if tag == "COINS":
        return 16 + b          # sw[2], and only the top nibble is wired
    return 8 + b if b < 8 else b - 8   # sw[1] is the low byte, sw[0] the high


def check(setname, mra_path):
    bad, labels = [], []
    dflt, dips = mra_switches(mra_path)
    by_name = {}
    for name, bits, ids in dips:
        by_name.setdefault(name, []).append((bits, ids))

    want_default = [0xFF, 0xFF, 0xF0]   # a bit nobody drives reads as 1
    for name, tag, mask, vals, dv in mame_dips(setname):
        maskbits = [i for i in range(16) if mask & (1 << i)]
        bits = [mra_bit(tag, b) for b in maskbits]

        if tag == "COINS" and any(b < 4 for b in maskbits):
            bad.append("%s: COINS DIP %r uses bit(s) below 4, which the core "
                       "does not wire (it takes sw[2][7:4])" % (setname, name))
            continue

        cands = by_name.get(name, [])
        hit = next((c for c in cands if c[0] == bits), None)
        if hit is None:
            # PORT_DIPUNUSED / PORT_DIPUNKNOWN reach build_mra.py with no
            # settings and deliberately get no <dip> line -- an OSD entry
            # offering "Unused: On/Off" is noise. Their DEFAULT still has to
            # be right, and the <switches default> check below covers that.
            if name.lower() not in ("unused", "unknown"):
                bad.append("%s: %s %r mask %#06x -> bits %s not in the .mra%s"
                           % (setname, tag, name, mask, bits,
                              " (bits there: %s)" % [c[0] for c in cands]
                              if cands else ""))
            continue
        _, ids = hit

        if len(ids) != 1 << len(bits):
            bad.append("%s: %r has %d ids for %d bits"
                       % (setname, name, len(ids), len(bits)))
            continue

        for v, label in vals.items():
            idx = 0
            for i, b in enumerate(maskbits):
                if v & (1 << b):
                    idx |= 1 << i
            if ids[idx] != label:
                # A LABEL DIFFERENCE IS USUALLY VERSION SKEW, not a fault. The
                # .mra is generated from the seta.cpp in ../mame (0.289); the
                # arcade64.exe this runs is whatever is installed (0.286 here),
                # and MAME renamed several Coinage settings in between. Kept
                # apart from the structural checks for that reason.
                labels.append("%s: %r value %#x -> index %d is %r, MAME says %r"
                              % (setname, name, v, idx, ids[idx], label))

        if dv is None:
            bad.append("%s: %r has no default in MAME" % (setname, name))
            continue
        for b in maskbits:
            flat = mra_bit(tag, b)
            byte, bit = flat // 8, flat % 8
            if not (dv & (1 << b)):
                want_default[byte] &= ~(1 << bit) & 0xFF

    # sw[2]'s LOW nibble is not wired to anything -- Seta.sv takes sw[2][7:4]
    # -- so only the top nibble of the third byte is compared.
    got = list(dflt[:3])
    if len(got) == 3:
        got[2] &= 0xF0
        want_default[2] &= 0xF0
    if dflt and got != want_default:
        bad.append("%s: <switches default> is %s, MAME's defaults give %s"
                   % (setname, ",".join("%02X" % b for b in dflt),
                      ",".join("%02X" % b for b in want_default)))
    return bad, labels


def main():
    if not MAME_EXE.exists():
        sys.exit("no MAME at %s (set MAME_DIR / MAME_EXE)" % MAME_EXE)

    import build_mra
    names = sys.argv[1:]
    table = {}
    for p in sorted((REPO / "releases").glob("*.mra")):
        setname = re.search(r"<setname>([^<]+)</setname>", p.read_text(
            encoding="utf8", errors="replace"))
        if setname:
            table[setname.group(1)] = p
    if names:
        table = {k: v for k, v in table.items() if k in names}

    ver = subprocess.run([str(MAME_EXE), "-version"], capture_output=True,
                         text=True, cwd=str(MAME_DIR)).stdout.strip()
    print("reference: %s -listxml, against .mra files generated from "
          "../mame's seta.cpp\n" % (ver or MAME_EXE.name))

    fails, skew = 0, []
    for setname, path in sorted(table.items()):
        bad, labels = check(setname, path)
        print("%-10s %s%s"
              % (setname, "ok" if not bad else "%d PROBLEM(S)" % len(bad),
                 "  (%d label difference(s))" % len(labels) if labels else ""))
        for b in bad:
            print("   " + b)
        skew += labels
        fails += bool(bad)
    if skew:
        print("\nLabel differences -- check the two MAME versions before "
              "treating any of these as a fault:")
        for l in skew:
            print("   " + l)
    print("\n%d of %d sets structurally clean" % (len(table) - fails, len(table)))
    return fails


if __name__ == "__main__":
    sys.exit(main())
