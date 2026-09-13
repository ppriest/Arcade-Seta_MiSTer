#!/usr/bin/env python3
"""Screenshot every parent set on the MiSTer with its flip DIP off and on.

    python scripts/flip_shots.py                         # every parent with a flip DIP
    python scripts/flip_shots.py --wait 25 "Eight Forces" Daioh
    python scripts/flip_shots.py --sheet-only

For each set: the flip setting comes from the .mra's <switches> -- its default
bytes and the "Flip Screen" (or zombraid's "Vertical Screen Flip") dip's bits
and ids -- and is written to the device as config/dips/<mra name>.dip, the
8-byte little-endian value Main_MiSTer loads and sends as ioctl index 254. The
set is launched off, then on, --wait seconds each, and screenshotted.

THE USER'S OWN DIP FILE IS RESTORED afterwards, byte for byte, or removed if
there was none -- including when the script is interrupted.

Output: debug/hw/flip/<stem>-off.png, -on.png, and sheet.png with each pair
side by side, the flipped shot rotated 180 degrees so the two should look alike.
"""
import argparse
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hw import Mister, load_env, REMOTE_ARCADE  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "debug" / "hw" / "flip"
DEVICE_DIR = f"{REMOTE_ARCADE}/_Seta"
DIPS_DIR = "/media/fat/config/dips"
FLIP_NAMES = ("Flip Screen", "Vertical Screen Flip")


def flip_setting(mra):
    """(default bytes, bytes with flip on), or None if the set has no flip DIP."""
    text = mra.read_text(encoding="utf-8")
    sw = re.search(r'<switches default="([^"]*)"', text)
    if not sw:
        return None
    default = bytes(int(b, 16) for b in sw.group(1).split(",") if b)
    for name in FLIP_NAMES:
        d = re.search(r'<dip name="%s" bits="([^"]*)" ids="([^"]*)"' % re.escape(name), text)
        if d:
            bits = [int(b) for b in d.group(1).split(",")]
            ids = d.group(2).split(",")
            if len(bits) != 1 or "On" not in ids:
                return None
            val = int.from_bytes(default.ljust(8, b"\0"), "little")
            bit = bits[0]
            val = (val & ~(1 << bit)) | (ids.index("On") << bit)
            return default.ljust(8, b"\0"), val.to_bytes(8, "little")
    return None


def sheet(stems, out):
    from PIL import Image, ImageDraw
    tw = 320
    rows = []
    for s in stems:
        pair = []
        for tag in ("off", "on"):
            p = OUT / f"{s}-{tag}.png"
            im = Image.open(p).convert("RGB") if p.exists() else None
            if im is not None and tag == "on":
                im = im.transpose(Image.ROTATE_180)
            if im is not None:
                im = im.resize((tw, round(im.height * tw / im.width)))
            pair.append(im)
        rows.append((s, pair))
    th = max((im.height for _, pr in rows for im in pr if im), default=240)
    img = Image.new("RGB", (2 * tw + 4, len(rows) * (th + 18)), (24, 24, 24))
    d = ImageDraw.Draw(img)
    for r, (s, pair) in enumerate(rows):
        y = r * (th + 18)
        d.text((4, y + 3), f"{s}   (left: flip off, right: flip on rotated 180)",
               fill=(230, 230, 230))
        for c, im in enumerate(pair):
            if im:
                img.paste(im, (c * (tw + 4), y + 18))
    img.save(out)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--wait", type=float, default=20)
    ap.add_argument("--sheet-only", action="store_true")
    a = ap.parse_args()

    mras = {p.stem: p for p in (REPO / "releases").glob("*.mra")}
    stems = a.sets or sorted(s for s, p in mras.items() if flip_setting(p))
    for s in stems:
        if s not in mras or not flip_setting(mras[s]):
            sys.exit(f"not a parent .mra with a flip DIP: {s}")

    if not a.sheet_only:
        m = Mister(load_env())
        OUT.mkdir(parents=True, exist_ok=True)
        for i, s in enumerate(stems, 1):
            off, on = flip_setting(mras[s])
            remote = f"{DIPS_DIR}/{s}.dip"
            backup = OUT / f"{s}.dip.orig"
            existed = m.sh(f'test -f "{remote}" && echo yes || echo no',
                           check=False).strip() == "yes"
            if existed:
                m.get_file(remote.replace(" ", "\\ ") if False else remote, backup)
            print(f"[{i}/{len(stems)}] {s}  (dip file {'backed up' if existed else 'absent'})")
            try:
                for tag, val in (("off", off), ("on", on)):
                    hexs = "".join(f"\\x{b:02x}" for b in val)
                    m.sh(f'mkdir -p {DIPS_DIR} && printf "{hexs}" > "{remote}"')
                    dst = OUT / f"{s}-{tag}.png"
                    if dst.exists():
                        dst.unlink()
                    t0 = time.time()
                    m.launch(f"{DEVICE_DIR}/{s}.mra")
                    m.screenshot(dst, settle=max(0.0, a.wait - (time.time() - t0)))
            finally:
                if existed:
                    orig = backup.read_bytes()
                    hexs = "".join(f"\\x{b:02x}" for b in orig)
                    m.sh(f'printf "{hexs}" > "{remote}"')
                else:
                    m.sh(f'rm -f "{remote}"', check=False)
                print("  dip file restored" if existed else "  dip file removed")
        m.post("/launch", {"path": "/media/fat/menu.rbf"})

    print("sheet ->", sheet(stems, OUT / "sheet.png"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
