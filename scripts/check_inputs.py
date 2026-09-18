#!/usr/bin/env python3
"""Check each set's player, coin and extra inputs against the fields MAME builds.

    python scripts/check_inputs.py [setname ...]

MAME side: scripts/mame/ports.lua lists every I/O port field of the running
set (port tag, mask, input token, name); cached in debug/ports/<set>.txt.
Core side: a transcription of Seta.sv's seta_port / dt_port / coins_in /
extra_in and each set's input_layout (rtl/seta_board_cfg.sv,
rtl/downtown/downtown_board_cfg.sv). Keep the tables below in step with those.

For every digital MAME field on P1-P4, COINS and EXTRA, the MiSTer joystick
bit the core puts on that port bit must be the one the token names
(MiSTer: 0 R, 1 L, 2 D, 3 U, buttons 1-6 at 4-9, Start 10, Coin 11, Service
13). The .mra's button names are positional (bit 4 + i) and are checked
against MAME's field names for the bits they land on.
"""
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import MAME_DIR, MAME_EXE, NO_WINDOW, rompath  # noqa: E402

# Seta.sv seta_port(j, layout): port bit -> MiSTer joystick bit, 7..0
SETA_PORT = {
    0: {7: 10, 5: 5, 4: 4, 3: 2, 2: 3, 1: 0, 0: 1},
    1: {7: 10, 4: 4, 3: 2, 2: 3, 1: 0, 0: 1},
    2: {7: 10, 6: 6, 5: 5, 4: 4, 3: 2, 2: 3, 1: 0, 0: 1},
    3: {7: 10, 3: 5, 2: 4, 1: 7, 0: 6},
    4: {7: 10, 4: 8, 3: 5, 2: 4, 1: 7, 0: 6},
    5: {7: 10, 5: 5, 4: 4, 3: 9, 2: 8, 1: 7, 0: 6},
}
# dt_port layout 1 (common_type2); layout 0 is seta_port 0
DT_PORT1 = {7: 10, 5: 5, 4: 4, 3: 0, 2: 1, 1: 2, 0: 3}

# (player, joystick bit)
SETA_COINS = {0: (1, 11), 1: (2, 11), 2: (1, 13)}
SETA_EXTRA = {0: (1, 7), 1: (1, 8), 2: (1, 9), 3: (2, 7), 4: (2, 8), 5: (2, 9)}
DT_COINS = {
    0: {0: (1, 11), 1: (2, 11), 2: (1, 10), 3: (2, 10), 4: (1, 13)},
    1: {7: (1, 11), 6: (2, 11), 5: (1, 13)},
}

# input_layout per set (seta_board_cfg.sv; unlisted sets keep the default 0)
SETA_LAYOUT = {
    "neobattl": 1, "drgnunit": 2, "stg": 2, "qzkklogy": 4, "qzkklgy2": 3,
    "daioh": 2, "daioha": 2, "rezon": 2, "rezono": 2, "gundhara": 2,
    "gundharac": 2, "wrofaero": 2, "magspeed": 5, "atehate": 3,
    "blandia": 2, "blandiap": 2,
}
DT_LAYOUT = {"twineagl": 0}      # others 1

# MAME inputs left unwired on purpose: (set, port, bit). jjsquawk's BUTTON3
# is read nowhere by the game (build_mra.py LAYOUT_OVERRIDE).
UNWIRED_OK = {(s, p, 6) for s in ("jjsquawk", "jjsquawko") for p in ("P1", "P2")}


def token_src(tok):
    m = re.fullmatch(r"P(\d)_JOYSTICK_(RIGHT|LEFT|DOWN|UP)", tok)
    if m:
        return int(m.group(1)), {"RIGHT": 0, "LEFT": 1, "DOWN": 2, "UP": 3}[m.group(2)]
    m = re.fullmatch(r"P(\d)_BUTTON(\d)", tok)
    if m:
        return int(m.group(1)), 3 + int(m.group(2))
    m = re.fullmatch(r"START(\d)", tok)
    if m:
        return int(m.group(1)), 10
    return {"COIN1": (1, 11), "COIN2": (2, 11), "SERVICE1": (1, 13)}.get(tok)


def mame_fields(setname):
    cache = REPO / "debug" / "ports" / f"{setname}.txt"
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, PORTS_FILE=cache.as_posix())
        subprocess.run([str(MAME_EXE), setname, "-skip_gameinfo", "-nodebug", "-nothrottle",
                        "-sound", "none", "-video", "none", "-nowindow",
                        "-autoboot_delay", "0",
                        "-autoboot_script", (REPO / "scripts" / "mame" / "ports.lua").as_posix(),
                        "-rompath", rompath(REPO), "-seconds_to_run", "5"],
                       cwd=str(MAME_DIR), env=env, capture_output=True, timeout=300, **NO_WINDOW)
    out = []
    for line in cache.read_text().splitlines():
        tag, mask, _, tok, name, kind = line.split("\t")
        out.append((tag.lstrip(":"), int(mask), tok, name, kind))
    return out


def core_map(setname, downtown):
    """{(port, bit): (player, joystick bit)}"""
    m = {}
    if downtown:
        lay = DT_LAYOUT.get(setname, 1)
        port = DT_PORT1 if lay == 1 else SETA_PORT[0]
        coins = DT_COINS[lay]
    else:
        lay = SETA_LAYOUT.get(setname, 0)
        port = SETA_PORT[lay]
        coins = SETA_COINS
        for b, s in SETA_EXTRA.items():
            m[("EXTRA", b)] = s
    # P3/P4: Seta.sv p3_in/p4_in, joysticks 3 and 4 (read by wits_map only)
    for p in ((1, 2) if downtown else (1, 2, 3, 4)):
        for b, j in port.items():
            m[(f"P{p}", b)] = (p, j)
    for b, s in coins.items():
        m[("COINS", b)] = s
    return m, lay


def check(path):
    root = ET.parse(path).getroot()
    setname = root.findtext("setname")
    downtown = root.findtext("rbf") == "SetaDowntown"
    core, lay = core_map(setname, downtown)
    fields = mame_fields(setname)
    probs, notes = [], []
    by_bit = {}
    for tag, mask, tok, name, kind in fields:
        if tag not in ("P1", "P2", "P3", "P4", "COINS", "EXTRA") or kind == "analog":
            continue
        if mask & (mask - 1):
            continue
        by_bit.setdefault((tag, mask.bit_length() - 1), []).append((tok, name))
    for key, cands in sorted(by_bit.items()):
        srcs = [(t, n, token_src(t)) for t, n in cands]
        srcs = [s for s in srcs if s[2] is not None]
        if not srcs:
            continue
        got = core.get(key)
        if (setname,) + key in UNWIRED_OK and got is None:
            notes.append(f"{key[0]} bit {key[1]}: MAME {cands[0][0]}, unwired on purpose")
            continue
        if len(cands) > 1 and any(s[2] == got for s in srcs) is False and len(srcs) < len(cands):
            # PORT_CONDITION alternatives on one bit (atehate's debug panel,
            # off by default in MAME): not a wiring error on its own
            notes.append(f"{key[0]} bit {key[1]}: conditional "
                         f"{' / '.join(t for t, _ in cands)}, core "
                         f"{'joy%d bit %d' % got if got else 'nothing'}")
            continue
        if not any(s[2] == got for s in srcs):
            want = " or ".join(f"{t} (joy{p} bit {j})" for t, _, (p, j) in srcs)
            probs.append(f"{key[0]} bit {key[1]}: MAME {want}, core "
                         f"{'joy%d bit %d' % got if got else 'nothing'}")
    # .mra names: entry i is joystick bit 4 + i
    btn = root.find("buttons")
    if btn is not None:
        names = btn.get("names").split(",")
        for i, nm in enumerate(names[:int(btn.get("count"))]):
            j = 4 + i
            bits = [k for k, v in core.items() if v == (1, j) and k[0] in ("P1", "EXTRA")]
            mame = [n for k in bits for _, n in by_bit.get(k, [])]
            mame = [re.sub(r"^P1 ", "", n) for n in mame if not n.startswith("P2 ")]
            if not mame:
                if nm not in ("Rotate Left", "Rotate Right"):
                    probs.append(f".mra button '{nm}' (joystick bit {j}) reaches no MAME P1 input")
            elif not any(n.lower() == nm.lower() for n in mame):
                notes.append(f".mra button '{nm}': MAME calls that input {' / '.join(mame)}")
    return setname, lay, probs, notes


def main():
    want = set(sys.argv[1:])
    paths = sorted((REPO / "releases").rglob("*.mra"))
    bad = 0
    for p in paths:
        s = ET.parse(p).getroot().findtext("setname")
        if want and s not in want:
            continue
        s, lay, probs, notes = check(p)
        print(f"{s:12s} layout {lay}  {'FAIL' if probs else 'ok'}")
        for x in probs:
            print(f"    PROBLEM {x}")
        for x in notes:
            print(f"    note    {x}")
        bad += bool(probs)
    print(f"\n{bad} set(s) with problems")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
