#!/usr/bin/env python3
"""Known-pattern SDRAM write/read test through the real MiSTer download path.

    python scripts/sdram_pattern_test.py                # all patterns
    python scripts/sdram_pattern_test.py ones alt vec   # a subset
    python scripts/sdram_pattern_test.py --list

Each pattern becomes a tiny .mra whose index-0 payload is INLINE HEX (no ROM
zip), so MiSTer streams a known 512-byte page to SDRAM address 0 through the
same ioctl/download path a game uses. The core's SDRAM read-back walker
(trace source 3, rtl/fuuki_core.sv) then reads that page back through the
CPU's own path and the tracer shows it on screen (scripts/tracer_readout.py
reads it back). This diffs the readout against the pattern.

WHY THIS INSTRUMENT EXISTS
--------------------------
The first bring-up produced "corrupt ROM" symptoms that were consistent with
half a dozen causes -- interleave, download logic, cache staleness, refresh,
reset races, DQ timing. A game ROM cannot separate them: its data is
arbitrary. Known patterns can:

  zeros, ff, ramp   no or few bit transitions between adjacent words
  alt, inv          maximum transitions between adjacent words
  ones              walking ones -- identifies which DATA LANES are weak and
                    which neighbouring word each lane is really sampling
  vec               gogomile's real vector page, the case that actually fails

A fault that depends on ADDRESS shows up in every pattern at the same words.
A fault that depends on DATA TRANSITIONS leaves zeros/ff/ramp exact and mangles
alt/inv/ones. That signature WAS seen -- and it was the READOUT, not the memory: the
framework applies the user's gamma LUT (MiSTer.ini preset -> gamma_110.txt)
to the core's RGB before the screenshot, so 0x40 read back as 0x38 and 0x02
as 0x01, and only patterns whose bytes are fixed points of the curve (0x00,
0xFF) survived. A quarter-period SDRAM_CLK phase change did not alter it at
all, and JTAG-read values had agreed with the ROM throughout. Gamma is now
forced off under the overlay (Fuuki.sv) and the readout is banded and
self-checking (scripts/tracer_readout.py).

EVERY RUN IS GUARDED. A result is only reported if the probe shows the device
actually loaded the 4 KB test image (dl_writes_256 == 8). Without that guard
a failed launch quietly re-dumps whatever was loaded before -- which happened,
and produced four identical "results" from a game that was still running.

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs the SDRAM download path and probe, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import argparse
import json
import re
import struct
import subprocess
import sys
import time
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HW = REPO / "scripts" / "hw.py"
CFG = REPO / "scripts" / "cfg.py"
ISSP = REPO / "scripts" / "read_issp.tcl"
QUARTUS_STP = Path(r"C:\intelFPGA_lite\17.0\quartus\bin64\quartus_stp.exe")
OUT = REPO / "debug" / "hw" / "pattern"
REMOTE_ARCADE = "/media/fat/_Arcade/_Fuuki"


def w(*words):
    return b"".join(struct.pack(">H", x & 0xFFFF) for x in words)


def gogomile_page0():
    with zipfile.ZipFile(REPO / "roms" / "gogomile.zip") as z:
        n = {x.split("/")[-1]: x for x in z.namelist()}
        a = z.read(n["fp2n.rom2"]); b = z.read(n["fp1n.rom1"])
    img = bytearray(len(a) * 2); img[0::2] = a; img[1::2] = b
    return bytes(img[:512])


PATTERNS = {
    "zeros": lambda: bytes(512),
    "ff":    lambda: w(0xFFFF) * 256,
    "ramp":  lambda: w(*range(256)),
    "alt":   lambda: w(0x0040, 0xFFFC) * 128,
    "inv":   lambda: w(0x0000, 0xFFFF) * 128,
    "ones":  lambda: w(*[1 << (k % 16) for k in range(256)]),
    "g1":    lambda: w(0x0040, 0x0000, 0x0000, 0x0000) * 64,
    "g2":    lambda: w(0x0040, 0xFFFC, 0x0000, 0x0000) * 64,
    "vec":   gogomile_page0,
    # Zero words between walking ones. Written to separate memory damage from
    # a capture-path transform: a transform touches the ones and leaves the
    # zeros alone (0x00 is a fixed point of the gamma curve), memory damage
    # would not respect that distinction.
    "ones_gap": lambda: w(*[(1 << ((k // 2) % 16)) if k % 2 == 0 else 0 for k in range(256)]),
}


def env():
    e = {}
    for line in (REPO / "mister.env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1); e[k.strip()] = v.strip()
    return e


def mra_for(name, payload):
    hexs = " ".join(f"{x:02X}" for x in payload)
    return f"""<misterromdescription>
\t<about author="Paul Priest" source="scripts/sdram_pattern_test.py -- inline pattern, no ROM"/>
\t<name>zz sdt_{name}</name>
\t<setname>sdt_{name}</setname>
\t<rbf>Arcade-Fuuki</rbf>
\t<rom index="1"><part>00</part></rom>
\t<rom index="0" md5="none">
\t\t<part>{hexs}</part>
\t\t<part repeat="0xE00">FF</part>
\t</rom>
\t<switches default="FF,FF"></switches>
</misterromdescription>
"""


def probe(field):
    p = subprocess.run([str(QUARTUS_STP), "-t", str(ISSP)], capture_output=True,
                       text=True, timeout=180, cwd=str(REPO))
    m = re.search(rf"^\s+{field}\s+(\S+)", p.stdout, re.M)
    return m.group(1) if m else None


def wait_download_done(limit=40):
    for _ in range(limit):
        time.sleep(2)
        if probe("ioctl_download") == "no":
            return True
    return False


def run_one(name, e, keep_mra=False):
    payload = PATTERNS[name]()
    exp = [struct.unpack(">H", payload[2*k:2*k+2])[0] for k in range(256)]
    OUT.mkdir(parents=True, exist_ok=True)
    mra = OUT / f"sdt_{name}.mra"
    mra.write_text(mra_for(name, payload), encoding="utf-8")
    host = f"{e['MISTER_USER']}@{e['MISTER_HOST']}"
    subprocess.run([r"C:\Program Files\PuTTY\pscp.exe", "-batch", "-pw", e["MISTER_PASSWORD"],
                    str(mra), f"{host}:{REMOTE_ARCADE}/zz sdt_{name}.mra"],
                   capture_output=True, timeout=60)
    subprocess.run([sys.executable, str(CFG), f"sdt_{name}", "--set", "overlay=1",
                    "ring=0", "src=3", "window=0"], capture_output=True, cwd=str(REPO))
    r = subprocess.run([sys.executable, str(HW), "launch", f"zz sdt_{name}"],
                       capture_output=True, text=True, cwd=str(REPO))
    if "launching" not in r.stdout:
        return dict(name=name, void=f"launch failed: {r.stdout.strip()[-120:]}")
    if not wait_download_done():
        return dict(name=name, void="download never finished")
    time.sleep(4)
    dl = probe("dl_writes_256")
    if dl != "8":
        return dict(name=name, void=f"device did not load the test image (dl_writes_256={dl})")
    # Banded, self-checking readout (scripts/tracer_readout.py). Each walker
    # entry is {word index, data}; the embedded index is checked against the
    # entry's position as a second guard against mis-attribution.
    from tracer_readout import read_buffer
    ents, probs = read_buffer(tag=f"sdt_{name}")
    got, misidx = {}, 0
    for pos, v in enumerate(ents):
        if v is None:
            continue
        idx, data = v >> 16, v & 0xFFFF
        if idx != pos:
            misidx += 1; continue
        got[idx] = data
    bad = [(k, got[k], exp[k]) for k in sorted(got) if got[k] != exp[k]]
    if misidx:
        probs.append(f"{misidx} entries whose embedded index disagreed with position")
    return dict(name=name, recovered=len(got), bad=bad, exp=exp, got=got, problems=probs)


def report(res):
    if "void" in res:
        print(f"\n{res['name']:6s}: VOID -- {res['void']}"); return
    n, bad = res["name"], res["bad"]
    # EXACT means all 256 words came back and every one matched. A partial
    # recovery with no mismatches is a readout problem, not a pass.
    verdict = ("  <-- EXACT" if (not bad and res["recovered"] == 256) else
               "  <-- INCOMPLETE READOUT" if not bad else "")
    print(f"\n{n:6s}: {res['recovered']}/256 recovered, {len(bad)} wrong{verdict}")
    for pr in res.get("problems", [])[:4]:
        print(f"         readout: {pr}")
    for k, g, e in bad[:6]:
        print(f"         word {k:03X}: got {g:04X} exp {e:04X}")
    if n == "ones" and bad:
        print("         walking one -> read back as (bit set: value):")
        for k, g, e in bad[:16]:
            print(f"           bit{e.bit_length()-1:<2d} -> {g:04X}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("patterns", nargs="*")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--json", help="also write results here")
    a = ap.parse_args()
    if a.list:
        print("\n".join(PATTERNS)); return 0
    names = a.patterns or list(PATTERNS)
    unknown = [n for n in names if n not in PATTERNS]
    if unknown:
        sys.exit(f"unknown pattern(s): {unknown}; --list shows them")
    e = env()
    results = []
    for n in names:
        r = run_one(n, e); results.append(r); report(r)
    if a.json:
        json.dump([{k: v for k, v in r.items() if k != "exp"} for r in results],
                  open(a.json, "w"), default=str)
    exact = [r["name"] for r in results
             if "void" not in r and not r["bad"] and r["recovered"] == 256]
    print(f"\nexact: {exact}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
