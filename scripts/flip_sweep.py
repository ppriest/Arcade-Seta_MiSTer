#!/usr/bin/env python3
"""Flip screen, every game: MAME with the DIP off and on, the RTL against both.

    python scripts/flip_sweep.py                        # every parent with a flip DIP
    python scripts/flip_sweep.py --games eightfrc,daioh --frames 900
    python scripts/flip_sweep.py --no-capture           # re-run the RTL on existing captures

For each set and frame:

  1. scripts/mame_capture.py twice, the flip DIP set explicitly Off and On
     (debug/sweep-<set>-f<frame>, debug/flip-<set>-f<frame>), with the write
     log on so the video register value can be recovered.
  2. The capture's spritectrl[0] bit 6 -- the flip the chips actually see --
     must be 0 for Off and 1 for On. A DIP that did not reach the game fails
     here instead of passing a flip test with an unflipped picture.
  3. sim/seta_video_tb (Verilator) renders each capture, with the hardware
     line budget. Unflipped, the render is compared with MAME's snapshot.
     FLIPPED, it is compared with the unflipped snapshot ROTATED 180 DEGREES:
     that is what flip screen is, and MAME does not do it (its flipped layers
     are 128 px off and its flipped sprites 8 lines). The MAME count is still
     printed for reference.

A rotation mismatch can also be the game: the two captures are separate runs,
and a set that buffers or animates differently when flipped will not line up.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from video_sweep import find_bash  # noqa: E402

# Parent sets whose MAME input ports have a flip DIP. gundhara and oisipuzl
# have none. zombraid has separate vertical and horizontal switches.
SETS = ["atehate", "blandia", "blockcar", "daioh", "drgnunit", "eightfrc",
        "extdwnhl", "jjsquawk", "madshark", "magspeed", "kamenrid", "msgundam",
        "pairlove", "qzkklgy2", "qzkklogy", "rezon", "neobattl", "sokonuke",
        "stg", "thunderl", "umanclub", "wrofaero", "wits", "zingzip", "zombraid",
        "gundhara", "oisipuzl"]
FLIP_DIP = {"zombraid": "Vertical Screen Flip"}
# zombraid does not flip through the sprite chip's bit: its switches reach the
# game, which leaves spritectrl[0] bit 6 clear. Compared, not bit-checked.
GAME_FLIPS = {"zombraid"}
# No flip DIP at all: captured unflipped only, with Demo Sounds set to its
# default so the capture still gets its own clean cfg -- not Service Mode,
# whose name also matches the settings-less service button on these sets.
# oisipuzl is here for tilemaps_flip.
NO_FLIP_DIP = {"gundhara", "oisipuzl"}

# seta_vregs_w, per memory map (seta.cpp). Group A sets have no layers and no
# vregs; the bench ignores the value there.
VREGS_ADDR = {"kamenrid": 0x600003, "madshark": 0x600003,
              "msgundam": 0x500005, "magspeed": 0x500015}


def capture(game, frame, name, dip, setting):
    r = subprocess.run([sys.executable, str(REPO / "scripts" / "mame_capture.py"),
                        game, "--frame", str(frame), "--name", name, "--wlog",
                        "--dip", f"{dip}={setting}"],
                       cwd=REPO, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr)[-600:]


def sprctrl0(capdir, game):
    b = (capdir / f"{game}_sprctrl.bin").read_bytes()
    return (b[0] << 8) | b[1]


def vregs(capdir, game, frame):
    addr = VREGS_ADDR.get(game, 0x500003)
    log = capdir / f"{game}_writes.log"
    val = 0
    if not log.exists():
        return val
    for line in log.read_text().splitlines():
        if line.startswith("#"):
            continue
        f = line.split("\t")
        if len(f) < 4:
            continue
        a, d = int(f[2], 16), int(f[3], 16)
        if int(f[0]) <= frame and a in (addr, addr - 1):
            val = d & 0xff
    return val


def rotated_mismatches(off_rgb):
    got = (REPO / "sim" / "seta_video_tb" / "got.hex").read_text().split()
    if not off_rgb or len(got) != len(off_rgb):
        return None
    n = len(got)
    return sum(1 for k in range(n) if got[k] != off_rgb[n - 1 - k])


def render(bash, game, capdir, frame, lat, budget):
    v = vregs(capdir, game, frame)
    r = subprocess.run([sys.executable, str(REPO / "scripts" / "prep_video_tb.py"),
                        game, str(capdir), "--budget", str(budget), "--vregs", hex(v)],
                       cwd=REPO, capture_output=True, text=True)
    if r.returncode != 0:
        return None, f"prep failed: {(r.stdout + r.stderr)[-300:]}"
    p = subprocess.run([bash, "scripts/run_verilator.sh", "seta_video_tb",
                        f"+ROMLAT={lat}"], cwd=REPO, capture_output=True, text=True)
    log = p.stdout + p.stderr
    m = re.search(r"mismatches\s+(\d+)", log)
    return (int(m.group(1)) if m else None), log


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--games", default="")
    ap.add_argument("--frames", default="900,2000")
    ap.add_argument("--lat", type=int, default=12)
    ap.add_argument("--budget", type=int, default=6100)
    ap.add_argument("--no-capture", action="store_true")
    a = ap.parse_args()

    games = [g for g in a.games.split(",") if g] or SETS
    frames = [int(f) for f in a.frames.split(",")]
    bash = find_bash()
    rows = []
    for game in games:
        dip = FLIP_DIP.get(game, "Flip Screen")
        states = (("off", "Off", "sweep"), ("on", "On", "flip"))
        if game in NO_FLIP_DIP:
            dip, states = "Demo Sounds", (("off", "On", "sweep"),)
        for frame in frames:
            off_rgb = None
            for state, setting, prefix in states:
                capdir = REPO / "debug" / f"{prefix}-{game}-f{frame}"
                if not a.no_capture:
                    ok, out = capture(game, frame, capdir.name, dip, setting)
                    if not ok:
                        print(f"FAIL {game} f{frame} {state}: capture\n{out}")
                        rows.append((game, frame, state, None, None, "capture"))
                        continue
                c0 = sprctrl0(capdir, game)
                flip = (c0 >> 6) & 1
                note = ""
                if game not in GAME_FLIPS | NO_FLIP_DIP and flip != (state == "on"):
                    note = f"DIP did not reach the chip (spritectrl0 {c0:04x})"
                mism, log = render(bash, game, capdir, frame, a.lat, a.budget)
                if mism is None:
                    note = (note + "; " if note else "") + "render failed"
                    (capdir / "rtl.log").write_text(log if isinstance(log, str) else "")
                else:
                    (capdir / "rtl.log").write_text(log)
                rot = None
                if state == "off" and mism is not None:
                    off_rgb = (REPO / "sim" / "seta_video_tb" / "rgb.hex").read_text().split()
                    score = mism
                elif mism is not None:
                    rot = rotated_mismatches(off_rgb)
                    score = rot
                else:
                    score = None
                rows.append((game, frame, state, c0, score, note))
                print(f"{game:9s} f{frame:<5d} flip {state:3s} ctrl0 {c0:04x}  "
                      f"vs MAME {mism if mism is not None else '-':>6}  "
                      f"vs unflipped rotated {rot if rot is not None else '-':>6}  {note}",
                      flush=True)

    print()
    bad = [r for r in rows if r[4] != 0 or r[5]]
    print(f"{len(rows) - len(bad)} of {len(rows)} captures right: unflipped identical "
          f"to MAME, flipped identical to the unflipped frame rotated 180")
    for r in bad:
        print(f"  {r[0]} f{r[1]} flip {r[2]}: mismatches {r[4]} {r[5]}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
