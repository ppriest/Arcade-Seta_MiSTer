#!/usr/bin/env python3
"""Check every `.mra`'s <buttons count> against MAME's own -listxml.

    python scripts/check_inputs.py

MAME's -listxml reports, per set, how many players it has and how many buttons
each control carries -- computed by MAME from the same INPUT_PORTS the .mra is
generated from, but through its own code. A count that disagrees means either
build_mra.py's layout derivation or Seta.sv's port assembly has drifted: the
two are the same mapping written twice (LAYOUTS in build_mra.py, seta_port()
in Seta.sv), and this is what keeps them honest.

The one deliberate difference is qzkklogy, where MAME counts five buttons
including the BUTTON5 "P1 Pause (Cheat)" that is not a cabinet button.
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


# Sets where the .mra deliberately exposes a different count from MAME's.
ACCEPTED = {
    # magspeed's four card buttons are IPT_OTHER, which MAME does not count as
    # buttons at all -- but they are the game's controls and have to be
    # mappable, so the .mra names six.
    "magspeed": 6,
}


def mame_input(setname):
    p = subprocess.run([str(MAME_EXE), setname, "-listxml"],
                       capture_output=True, text=True, cwd=str(MAME_DIR))
    if p.returncode != 0 or not p.stdout.strip():
        sys.exit("mame -listxml %s failed: %s" % (setname, p.stderr[:200]))
    inp = ET.fromstring(p.stdout).find(".//input")
    ctrls = inp.findall("control")
    return (int(inp.get("players")),
            max((int(c.get("buttons", 0)) for c in ctrls), default=0),
            sorted({c.get("type") for c in ctrls}))


def main():
    if not MAME_EXE.exists():
        sys.exit("no MAME at %s (set MAME_DIR / MAME_EXE)" % MAME_EXE)

    fails = 0
    for path in sorted((REPO / "releases").rglob("*.mra")):
        text = path.read_text(encoding="utf8", errors="replace")
        m = re.search(r"<setname>([^<]+)</setname>", text)
        b = re.search(r'<buttons names="([^"]*)"[^>]*count="(\d+)"', text)
        if not m or not b:
            continue
        setname, names, count = m.group(1), b.group(1).split(","), int(b.group(2))
        players, buttons, types = mame_input(setname)

        note = ""
        ok = count == buttons or ACCEPTED.get(setname) == count
        if not ok:
            note = "  MAME says %d button(s) %s" % (buttons, types)
        # The four-player set is the only one whose extra players the core
        # answers at all; P3/P4 live at in_base+8 and +0xa.
        if players > 2:
            note += "  (%d players)" % players
        print("%-10s count=%d %-28s %s%s"
              % (setname, count, ",".join(names[:count]),
                 "ok" if ok else "MISMATCH", note))
        fails += not ok
    print("\n%d mismatch(es)" % fails)
    return fails


if __name__ == "__main__":
    sys.exit(main())
