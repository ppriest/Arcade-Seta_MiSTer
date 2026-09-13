#!/usr/bin/env python3
"""Launch every parent set on the MiSTer in turn, screenshot each, collate.

    python scripts/parent_shots.py                     # all parents, 20 s each
    python scripts/parent_shots.py --wait 30 Daioh "Mad Shark"
    python scripts/parent_shots.py --sheet-only        # re-collate existing shots

A parent is a .mra at the top of releases/; clones live in _alternatives/ and
are skipped. Each set is launched through scripts/hw.py's Mister.launch, which
bounces through menu.rbf so the FPGA and the ROM are really reloaded, then left
for --wait seconds after the launch call before the screenshot is triggered.
The wait runs from the launch, so it includes the ROM load.

Shots land in debug/hw/parents/<mra stem>.png, and the contact sheet in
debug/hw/parents/sheet.png, each tile labelled with the set name. A set that
produced no screenshot gets a labelled blank tile rather than being dropped, so
the sheet always shows every set that was asked for.

Holds the board for roughly (wait + 15 s) per set. Tell other sessions sharing
the MiSTer first.
"""
import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hw import Mister, load_env, REMOTE_ARCADE  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "debug" / "hw" / "parents"
DEVICE_DIR = f"{REMOTE_ARCADE}/_Seta"


def parents():
    return sorted(p.stem for p in (REPO / "releases").glob("*.mra"))


def sheet(names, out, cols=5, tile_w=384):
    from PIL import Image, ImageDraw, ImageFont
    try:
        font = ImageFont.truetype("arial.ttf", 14)
    except OSError:
        font = ImageFont.load_default()
    label_h = 22
    tiles = []
    for n in names:
        p = OUT / f"{n}.png"
        if p.exists():
            im = Image.open(p).convert("RGB")
            im = im.resize((tile_w, round(im.height * tile_w / im.width)), Image.NEAREST)
        else:
            im = None
        tiles.append((n, im))
    tile_h = max((im.height for _, im in tiles if im), default=tile_w * 3 // 4)
    rows = (len(tiles) + cols - 1) // cols
    W, H = cols * tile_w, rows * (tile_h + label_h)
    img = Image.new("RGB", (W, H), (24, 24, 24))
    d = ImageDraw.Draw(img)
    for i, (n, im) in enumerate(tiles):
        x, y = (i % cols) * tile_w, (i // cols) * (tile_h + label_h)
        d.text((x + 4, y + 3), n[:48], fill=(230, 230, 230), font=font)
        if im:
            img.paste(im, (x, y + label_h + (tile_h - im.height) // 2))
        else:
            d.text((x + 8, y + label_h + tile_h // 2), "no screenshot",
                   fill=(220, 80, 80), font=font)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*", help=".mra stems (default: every parent)")
    ap.add_argument("--wait", type=float, default=20,
                    help="seconds from launch to screenshot (default 20)")
    ap.add_argument("--cols", type=int, default=5)
    ap.add_argument("--sheet-only", action="store_true")
    a = ap.parse_args()

    names = a.sets or parents()
    missing = [n for n in names if not (REPO / "releases" / f"{n}.mra").exists()]
    if missing:
        sys.exit("not a parent .mra in releases/: " + ", ".join(missing))

    if not a.sheet_only:
        m = Mister(load_env())
        for i, n in enumerate(names, 1):
            print(f"[{i}/{len(names)}] {n}")
            path = f"{DEVICE_DIR}/{n}.mra"
            if m.sh(f'test -f "{path}" && echo yes || echo no', check=False).strip() != "yes":
                print(f"  not on the device: {path} -- skipped")
                continue
            dst = OUT / f"{n}.png"
            if dst.exists():
                dst.unlink()                 # a stale shot must not pass for this run's
            t0 = time.time()
            m.launch(path)
            # Mister.screenshot sleeps `settle` before triggering; make the
            # total from the launch call equal --wait.
            settle = max(0.0, a.wait - (time.time() - t0))
            m.screenshot(dst, settle=settle)
        m.post("/launch", {"path": "/media/fat/menu.rbf"})

    print("sheet ->", sheet(names, OUT / "sheet.png", cols=a.cols))
    return 0


if __name__ == "__main__":
    sys.exit(main())
