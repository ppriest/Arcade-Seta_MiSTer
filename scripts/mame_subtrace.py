#!/usr/bin/env python3
"""Which instructions a 6502-family CPU actually executes, from MAME's trace.

    python scripts/mame_subtrace.py downtown --cpu sub --seconds 30

Runs MAME headless with the debugger's `trace` on one CPU (`noloop`: every
instruction, loops not folded),
started from a Lua hook (`-debugger none` ignores -debugscript), then counts
mnemonic + addressing mode and flags the 65C02-only forms. Written to decide
whether T65's incomplete 65C02 mode can run a game's program. The trace is
deleted afterwards unless --keep.
"""
import argparse
import collections
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import MAME_DIR, MAME_EXE, NO_WINDOW, rompath  # noqa: E402

LUA = """local started = false
emu.register_frame_done(function()
    if started then return end
    started = true
    local dbg = manager.machine.debugger
    dbg:command("trace " .. os.getenv("TRACE_FILE") .. "," .. os.getenv("TRACE_CPU") .. os.getenv("TRACE_OPTS"))
    dbg:command("go")
end)
"""


def mode(operand):
    o = re.sub(r"\s+", "", operand.split(";")[0]).lower()
    if not o:
        return "imp"
    if o == "a":
        return "acc"
    if o.startswith("#"):
        return "imm"
    pats = [
        (r"^\(\$[0-9a-f]{2}\)$", "(zp)"), (r"^\(\$[0-9a-f]{2}\),y$", "(zp),y"),
        (r"^\(\$[0-9a-f]{2},x\)$", "(zp,x)"), (r"^\(\$[0-9a-f]{4}\)$", "(abs)"),
        (r"^\(\$[0-9a-f]{4},x\)$", "(abs,x)"), (r"^\$[0-9a-f]{2},x$", "zp,x"),
        (r"^\$[0-9a-f]{2},y$", "zp,y"), (r"^\$[0-9a-f]{4},x$", "abs,x"),
        (r"^\$[0-9a-f]{4},y$", "abs,y"), (r"^\$[0-9a-f]{2}$", "zp"),
        (r"^\$[0-9a-f]{4}$", "abs"), (r"^\$[0-9a-f]{2},\s*\$[0-9a-f]{4}$", "zp,rel"),
    ]
    for p, m in pats:
        if re.match(p, o):
            return m
    return "?" + o


C02_MNEM = {"bra", "stz", "tsb", "trb", "phx", "plx", "phy", "ply", "wai", "stp"}


def c02_only(mn, md):
    if mn in C02_MNEM or mn[:3] in ("bbr", "bbs", "rmb", "smb"):
        return True
    if md == "(zp)":
        return True
    if mn in ("inc", "dec") and md in ("acc", "imp"):
        return True
    if mn == "bit" and md in ("imm", "zp,x", "abs,x"):
        return True
    if mn == "jmp" and md == "(abs,x)":
        return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--cpu", default="sub")
    ap.add_argument("--seconds", type=int, default=30)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    out = REPO / "debug" / "subtrace"
    out.mkdir(parents=True, exist_ok=True)
    log = out / f"{a.game}-{a.cpu}.log"
    lua = out / "trace.lua"
    lua.write_text(LUA)
    env = dict(os.environ, TRACE_FILE=log.as_posix(), TRACE_CPU=a.cpu,
               TRACE_OPTS=",noloop")
    cmd = [str(MAME_EXE), a.game, "-skip_gameinfo", "-nothrottle",
           "-sound", "none", "-video", "none", "-nowindow",
           "-debug", "-debugger", "none", "-autoboot_delay", "0",
           "-autoboot_script", lua.as_posix(),
           "-rompath", rompath(REPO), "-seconds_to_run", str(a.seconds)]
    subprocess.run(cmd, cwd=str(MAME_DIR), env=env, **NO_WINDOW, capture_output=True,
                   text=True, timeout=7200)
    if not log.exists():
        sys.exit(f"no trace written: {log}")
    seen = collections.Counter()
    for line in log.open(errors="replace"):
        m = re.match(r"\s*([0-9A-Fa-f]{4}):\s+(\w+)\s*(.*)$", line)
        if m:
            seen[(m.group(2).lower(), mode(m.group(3)))] += 1
    if not a.keep:
        log.unlink()
    only = {k: v for k, v in seen.items() if c02_only(*k)}
    print(f"{a.game} {a.cpu}, {a.seconds} s: {sum(seen.values())} instructions, "
          f"{len(seen)} forms, {len(only)} 65C02-only")
    for (mn, md), v in sorted(only.items()):
        print(f"  65C02  {mn:5s} {md:8s} {v}")
    odd = sorted(k for k in seen if k[1].startswith("?"))
    if odd:
        print("  unparsed operands:", odd[:10])


if __name__ == "__main__":
    main()
