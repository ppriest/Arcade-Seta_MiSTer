#!/usr/bin/env python3
"""Set OSD status bits in a MiSTer per-core .CFG by READ-MODIFY-WRITE.

    python scripts/cfg.py thunderl --show
    python scripts/cfg.py thunderl --set overlay=1 src=0 ring=1
    python scripts/cfg.py thunderl --clear-debug

WHY READ-MODIFY-WRITE, ALWAYS
-----------------------------
/media/fat/config/<setname>.CFG is the WHOLE 128-bit status word, little
endian (byte N holds status[8N+7:8N]). Anything else the core keeps in that
word -- aspect ratio, scandoubler FX, and on some cores the DIP switches --
lives in the same bytes. Writing a fresh 16 bytes with only a debug bit set
therefore silently clears everything else. The sibling Psikyo core did exactly
that twice, the second time zeroing two .CFG files during debug pokes and
booting the games into their RAM-check screen because a cleared DIP byte turns
Service Mode ON.

So this tool never builds a CFG from nothing: it pulls the existing file,
flips only the named bits, and pushes it back. If the file does not exist it
starts from all-zero, which is what MiSTer itself uses for a first run, and
says so.

BIT MAP -- keep in step with Seta.sv's CONF_STR. A bit that moves in one and
not the other reads as a plausible setting doing nothing.

*** PROVISIONAL: Seta.sv does not exist yet. ***
The framework bits below (fx, rotate, flip180, scale, vcrop, crop_off, crt,
aspect) follow the standard MiSTer layout both prior cores used and should
carry over unchanged. The Seta-specific debug bits are laid out to match
docs/ROADMAP.md's "Instrumentation this core needs", and must be checked
against the real CONF_STR the first time Seta.sv defines one. Validate the
whole map with https://agg23.github.io/mister-config/ rather than reasoning
about the ranges by hand -- collisions are silent, and the symptom is an
option that simply does not respond.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REMOTE_CFG = "/media/fat/config"

# name -> (low_bit, width). From Seta.sv's CONF_STR. See the PROVISIONAL note
# in the docstring: this is the planned map, not yet one read off the RTL.
BITS = {
    "reset":     (0, 1),

    # --- Seta-specific debug ------------------------------------------------
    # Forced X1-011 draw order. 0 = off (use the game's video register);
    # 1..8 = force order value 0..7. The eight orders ARE the whole priority
    # system on this hardware (seta_layers_update), so pinning one separates
    # "priority is wrong" from "an engine is wrong".
    "order":     (33, 4),
    # Sprite index limit: 0 = 512 (MAME's m_spritelimit default), 1 = 256,
    # 2 = 128, 3 = 64. MAME's own chip comment says the real limits are not
    # understood, so this is a switch rather than a constant.
    "spr_limit": (37, 2),

    # Render disable, one per element. "On,Off" in the OSD, so 1 = off.
    # The floating tilemap gets its own bit: it lives in the sprite chip but
    # behaves like a background layer, and separating it from the foreground
    # sprites is exactly the bisection a garbled screen needs.
    "no_l0":     (40, 1),   # X1-012 layer 0
    "no_l1":     (41, 1),   # X1-012 layer 1
    "no_float":  (42, 1),   # floating tilemap (sprite columns)
    "no_spr":    (43, 1),   # foreground sprites

    # --- framework ----------------------------------------------------------
    "fx":        (44, 3),   # scandoubler

    # --- trace overlay ------------------------------------------------------
    "overlay":   (50, 1),   # trace overlay on
    "src":       (51, 2),   # trace source select
    "window":    (53, 4),   # skip window*DEPTH events before recording
    "ring":      (57, 1),   # 0 = first N, 1 = ring (latest N)
    "rearm":     (58, 1),   # any CHANGE re-arms
    "trig":      (59, 1),   # ring mode: freeze on a chosen event
    "marker":    (60, 1),   # white pixels on the first and last active lines

    # --- framework video ----------------------------------------------------
    "rotate":    (63, 2),   # HDMI rotation: 0 off, 1 CW, 2 CCW
    "flip180":   (65, 1),
    "scale":     (66, 3),   # video_freak scale mode
    "vcrop":     (69, 2),
    "crop_off":  (71, 5),   # two's complement
    "crt":       (76, 1),   # CRT offset on
    "aspect":    (121, 2),
}
DEBUG_BITS = ("overlay", "src", "window", "ring", "rearm", "trig",
              "no_l0", "no_l1", "no_float", "no_spr", "marker",
              "order", "spr_limit")


def env():
    p = REPO / "mister.env"
    if not p.exists():
        sys.exit("mister.env not found")
    e = {}
    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            e[k.strip()] = v.strip()
    return e


def putty(name):
    for c in (name, os.path.join(r"C:\Program Files\PuTTY", name)):
        f = shutil.which(c) or (c if os.path.isfile(c) else None)
        if f:
            return f
    sys.exit(f"Couldn't find {name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("setname")
    ap.add_argument("--set", nargs="*", default=[], metavar="NAME=VALUE")
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--clear-debug", action="store_true",
                    help="zero every debug field, leaving everything else alone")
    a = ap.parse_args()

    e = env()
    pscp, plink = putty("pscp.exe"), putty("plink.exe")
    host = f"{e['MISTER_USER']}@{e['MISTER_HOST']}"
    remote = f"{REMOTE_CFG}/{a.setname}.CFG"
    local = REPO / "debug" / "hw" / f"{a.setname}.CFG"
    local.parent.mkdir(parents=True, exist_ok=True)

    r = subprocess.run([pscp, "-batch", "-pw", e["MISTER_PASSWORD"],
                        f"{host}:{remote}", str(local)],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        print(f"  no existing {a.setname}.CFG on the device -- starting from "
              f"all-zero, which is what MiSTer uses for a first run")
        raw = bytearray(16)
    else:
        raw = bytearray(local.read_bytes())
        if len(raw) < 16:
            raw += bytearray(16 - len(raw))

    word = int.from_bytes(raw[:16], "little")

    def get(name):
        lo, w = BITS[name]
        return (word >> lo) & ((1 << w) - 1)

    if a.show or not (a.set or a.clear_debug):
        print(f"{a.setname}.CFG ({len(raw)} bytes)")
        for n in BITS:
            print(f"  {n:9s} = {get(n)}")
        print(f"  raw[0:8] = {raw[:8].hex(' ')}")
        if not (a.set or a.clear_debug):
            return 0

    changes = []
    pairs = list(a.set)
    if a.clear_debug:
        pairs += [f"{n}=0" for n in DEBUG_BITS]
    for kv in pairs:
        if "=" not in kv:
            sys.exit(f"expected NAME=VALUE, got {kv!r}")
        n, v = kv.split("=", 1)
        if n not in BITS:
            sys.exit(f"unknown field {n!r}. Known: {', '.join(BITS)}")
        lo, w = BITS[n]
        v = int(v, 0)
        if v >= (1 << w):
            sys.exit(f"{n} is {w} bit(s); {v} does not fit")
        old = get(n)
        word = (word & ~(((1 << w) - 1) << lo)) | (v << lo)
        if old != v:
            changes.append(f"{n} {old} -> {v}")

    raw[:16] = word.to_bytes(16, "little")
    local.write_bytes(bytes(raw))

    subprocess.run([plink, "-ssh", "-batch", "-pw", e["MISTER_PASSWORD"],
                    host, f"mkdir -p {REMOTE_CFG}"], capture_output=True,
                   timeout=60)
    r = subprocess.run([pscp, "-batch", "-pw", e["MISTER_PASSWORD"],
                        str(local), f"{host}:{remote}"],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        sys.exit(f"failed to write {remote}: {r.stderr.strip()}")

    print(f"  {remote}: " + (", ".join(changes) if changes else "no change"))
    print("  (the CFG is read when the core LOADS -- relaunch to apply)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
