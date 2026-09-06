#!/usr/bin/env python3
"""Extract a game's DIP switches from seta.cpp's INPUT_PORTS_START blocks.

    python scripts/extract_dips.py thunderl
    python scripts/extract_dips.py --all           # every Group A game
    python scripts/extract_dips.py --selftest

Point MAME_SRC at the driver (default E:/mame/src/mame/seta/seta.cpp).

WHY EXTRACT RATHER THAN TYPE
----------------------------
The same argument as scripts/extract_romstart.py, and with a sharper edge: a
wrong DIP default is not cosmetic. A fresh `.CFG` on MiSTer is all zeroes, so
whatever the `.mra` declares as the default is what the game boots with -- and
on the Psikyo core a wrong DIP byte silently enabled service mode, while
another value hung a game outright. Group A has 61 PORT_DIPNAME entries with
250 settings between them; transcribing those by hand is a coin flip repeated
sixty-one times.

WHAT IS PARSED, and what each contributes:

    PORT_DIPNAME(mask, default, name)   a user-visible switch
    PORT_DIPSETTING(value, label)       one of its settings
    PORT_DIPUNUSED_DIPLOC(mask, dflt)   NOT emitted, but its default IS kept
    PORT_SERVICE_DIPLOC(mask, dflt)     the standard Service Mode switch
    PORT_BIT(mask, ...)                 ignored; it is a control, not a switch

The unused ones matter and are the easy thing to drop. Fuuki's hand-written
table left four of them out of gogomile and produced a default of FF,1D
instead of FF,FF, because all four default to 1.

DEF_STR
-------
MAME's DEF_STR(x) expands to a shared string. The table below carries only the
values this driver actually uses -- checked by --selftest, which fails if a
game references one that is missing rather than quietly emitting the raw
token.
"""
import argparse
import os
import re
import sys

SRC = os.getenv("MAME_SRC", "E:/mame/src/mame/seta/seta.cpp")

# From MAME's src/emu/inpttype.ipp. Only the strings seta.cpp's in-scope input
# ports reference; --selftest checks nothing else is needed.
DEF_STR = {
    "Off": "Off", "On": "On", "Yes": "Yes", "No": "No",
    "None": "None", "Unknown": "Unknown", "Unused": "Unused",
    "Upright": "Upright", "Cocktail": "Cocktail", "Cabinet": "Cabinet",
    "Flip_Screen": "Flip Screen", "Demo_Sounds": "Demo Sounds",
    "Difficulty": "Difficulty", "Lives": "Lives", "Bonus_Life": "Bonus Life",
    "Coinage": "Coinage", "Coin_A": "Coin A", "Coin_B": "Coin B",
    "Free_Play": "Free Play", "Controls": "Controls",
    "Easy": "Easy", "Normal": "Normal", "Hard": "Hard", "Hardest": "Hardest",
    "Easiest": "Easiest", "Very_Hard": "Very Hard",
    "Allow_Continue": "Allow Continue", "Service_Mode": "Service Mode",
    "1C_1C": "1 Coin/1 Credit", "1C_2C": "1 Coin/2 Credits",
    "1C_3C": "1 Coin/3 Credits", "1C_4C": "1 Coin/4 Credits",
    "1C_5C": "1 Coin/5 Credits", "1C_6C": "1 Coin/6 Credits",
    "2C_1C": "2 Coins/1 Credit", "2C_2C": "2 Coins/2 Credits",
    "2C_3C": "2 Coins/3 Credits", "2C_4C": "2 Coins/4 Credits",
    "3C_1C": "3 Coins/1 Credit", "3C_2C": "3 Coins/2 Credits",
    "3C_3C": "3 Coins/3 Credits", "3C_4C": "3 Coins/4 Credits",
    "4C_1C": "4 Coins/1 Credit", "4C_2C": "4 Coins/2 Credits",
    "4C_3C": "4 Coins/3 Credits", "4C_4C": "4 Coins/4 Credits",
    "5C_1C": "5 Coins/1 Credit", "5C_3C": "5 Coins/3 Credits",
    "6C_1C": "6 Coins/1 Credit", "8C_3C": "8 Coins/3 Credits",
}

_DEFSTR_RE = re.compile(r"DEF_STR\(\s*([A-Za-z0-9_]+)\s*\)")
_NUM = r"(0x[0-9a-fA-F]+|\d+)"


def _num(s):
    s = s.strip()
    return int(s, 16) if s.lower().startswith("0x") else int(s)


def sanitise(label):
    """A `.mra` <dip> carries its settings as a COMMA-SEPARATED id list, so a
    label containing a comma shifts every later entry by one -- the OSD then
    shows one setting and the game reads another.

    Several of this driver's bonus-life labels are written "150k, 350k". The
    comma becomes a slash. That is a display change and nothing else: the mask,
    the value and the default are untouched, and it happens HERE, once, rather
    than being left for whoever writes the .mra to notice.
    """
    return label.replace(", ", "/").replace(",", "/")


def _label(raw, missing):
    """A PORT_DIPSETTING/PORT_DIPNAME label, which is a quoted string or a
    DEF_STR token."""
    raw = raw.strip()
    m = _DEFSTR_RE.fullmatch(raw)
    if m:
        if m.group(1) not in DEF_STR:
            missing.add(m.group(1))
            return m.group(1)
        return sanitise(DEF_STR[m.group(1)])
    m = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', raw)
    if m:
        return sanitise(m.group(1))
    # A concatenation of adjacent string literals, which the driver uses for
    # a few long labels.
    parts = re.findall(r'"((?:[^"\\]|\\.)*)"', raw)
    if parts:
        return sanitise("".join(parts))
    return raw


def blocks(text):
    out = {}
    for m in re.finditer(
            r"INPUT_PORTS_START\(\s*(\w+)\s*\)(.*?)INPUT_PORTS_END", text, re.S):
        out[m.group(1)] = m.group(2)
    return out


def parse_ports(body, all_blocks, missing, depth=0):
    """{port name: [(label, mask, default, {value: label} or None)]}.

    A settings map of None marks a switch that contributes only its DEFAULT --
    PORT_DIPUNUSED and friends. Dropping those is what produces a wrong
    default byte.
    """
    if depth > 4:
        sys.exit("PORT_INCLUDE nested too deep")
    ports = {}
    cur = None
    last = None

    for raw in body.split("\n"):
        line = raw.split("//")[0].strip()
        if not line:
            continue

        m = re.match(r'PORT_INCLUDE\(\s*(\w+)\s*\)', line)
        if m:
            if m.group(1) not in all_blocks:
                sys.exit(f"PORT_INCLUDE({m.group(1)}) but no such block")
            inc = parse_ports(all_blocks[m.group(1)], all_blocks, missing, depth + 1)
            for k, v in inc.items():
                ports.setdefault(k, []).extend(v)
            continue

        m = re.match(r'PORT_(?:START|MODIFY)\(\s*"([^"]+)"', line)
        if m:
            cur = m.group(1)
            ports.setdefault(cur, [])
            last = None
            continue

        if cur is None:
            continue

        m = re.match(rf'PORT_DIPNAME\(\s*{_NUM}\s*,\s*{_NUM}\s*,\s*(.*?)\s*\)\s*(?:PORT_\w+.*)?$',
                     line)
        if m:
            last = (_label(m.group(3), missing), _num(m.group(1)), _num(m.group(2)), {})
            ports[cur].append(last)
            continue

        m = re.match(rf'PORT_DIPSETTING\(\s*{_NUM}\s*,\s*(.*?)\s*\)\s*$', line)
        if m:
            if last is None:
                sys.exit(f"PORT_DIPSETTING with no preceding PORT_DIPNAME: {line}")
            last[3][_num(m.group(1))] = _label(m.group(2), missing)
            continue

        # Not emitted as a switch, but its default is part of the byte.
        m = re.match(rf'PORT_DIPUNUSED(?:_DIPLOC)?\(\s*{_NUM}\s*,\s*{_NUM}',
                     line)
        if m:
            ports[cur].append(("(unused)", _num(m.group(1)), _num(m.group(2)), None))
            last = None
            continue

        m = re.match(rf'PORT_SERVICE(?:_DIPLOC)?\(\s*{_NUM}\s*,\s*{_NUM}', line)
        if m:
            mask, dflt = _num(m.group(1)), _num(m.group(2))
            # MAME's PORT_SERVICE is active low: IP_ACTIVE_LOW means the
            # DEFAULT value is "off". Emitted as a real switch, because
            # reaching service mode without opening the cabinet is the whole
            # point of having it in the OSD.
            ports[cur].append(("Service Mode", mask, dflt,
                               {dflt: "Off", (~dflt) & mask: "On"}))
            last = None
            continue

    return ports


GROUP_A = ["thunderl", "wits", "blockcar", "umanclub", "neobattl",
           "atehate", "pairlove"]


def load():
    if not os.path.exists(SRC):
        sys.exit(f"driver not found at {SRC} (set MAME_SRC)")
    return blocks(open(SRC, encoding="utf8", errors="replace").read())


def selftest():
    all_blocks = load()
    missing = set()
    fails = []
    for g in GROUP_A:
        if g not in all_blocks:
            fails.append(f"{g}: no INPUT_PORTS_START")
            continue
        ports = parse_ports(all_blocks[g], all_blocks, missing)
        if "DSW" not in ports:
            fails.append(f"{g}: no DSW port")
        for pname, dips in ports.items():
            seen = 0
            for label, mask, dflt, settings in dips:
                # Two switches sharing a bit means one of them was misparsed.
                if seen & mask:
                    fails.append(f"{g}/{pname}: '{label}' mask {mask:#06x} "
                                 f"overlaps an earlier switch")
                seen |= mask
                if dflt & ~mask:
                    fails.append(f"{g}/{pname}: '{label}' default {dflt:#06x} "
                                 f"has bits outside its mask {mask:#06x}")
                if settings is None:
                    continue
                if not settings:
                    fails.append(f"{g}/{pname}: '{label}' has no settings")
                for value in settings:
                    if value & ~mask:
                        fails.append(f"{g}/{pname}: '{label}' setting {value:#06x} "
                                     f"outside mask {mask:#06x}")
                # A comma in a label shifts every later entry of the .mra's
                # comma-separated id list by one, so the OSD shows one setting
                # and the game reads another.
                for lab in settings.values():
                    if "," in lab:
                        fails.append(f"{g}/{pname}: label {lab!r} contains a comma")
    if missing:
        fails.append("DEF_STR entries missing from the table: "
                     + ", ".join(sorted(missing)))
    for f in fails[:15]:
        print("FAIL: " + f)
    if fails:
        print(f"FAIL: {len(fails)} problem(s)")
        return 1
    print(f"PASS: {len(GROUP_A)} games parsed, masks disjoint, defaults in range, "
          f"every DEF_STR known")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("games", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        return selftest()

    all_blocks = load()
    missing = set()
    for g in (GROUP_A if a.all else (a.games or GROUP_A)):
        if g not in all_blocks:
            print(f"{g}: no INPUT_PORTS_START", file=sys.stderr)
            continue
        print(f"=== {g} ===")
        for pname, dips in parse_ports(all_blocks[g], all_blocks, missing).items():
            real = [d for d in dips if d[3] is not None]
            if not real and not any(d[3] is None for d in dips):
                continue
            print(f"  {pname}:")
            for label, mask, dflt, settings in dips:
                if settings is None:
                    print(f"    {label:24s} mask {mask:#06x} default {dflt:#06x}")
                else:
                    vals = " ".join(f"{v:#x}={l}" for v, l in sorted(settings.items()))
                    print(f"    {label:24s} mask {mask:#06x} default {dflt:#06x}  {vals}")
    if missing:
        print("DEF_STR missing: " + ", ".join(sorted(missing)), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
