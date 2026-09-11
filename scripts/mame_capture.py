#!/usr/bin/env python3
"""Drive MAME headlessly to capture reference frames for the RTL to be checked against.

    python scripts/mame_capture.py thunderl --frame 900 --name title
    python scripts/mame_capture.py gundhara --frame 3000 --name play --wlog

Writes into debug/<name>/ (gitignored -- this is ROM-derived data and is never
committed): a binary dump of every region the video hardware reads, the
screenshot MAME rendered from exactly that state, and optionally a log of every
write to the video and layer-control registers, tagged with the scanline.

Why this exists: the renderer is being built against MAME's output as the
accuracy target, and "compare against MAME" is only cheap if capturing a
reference frame is one command. Capturing by hand through the debugger is
several commands, easy to get subtly wrong, and impossible to repeat exactly.

The screenshot is the point as much as the dumps. Preloading the dumps in
simulation, rendering one frame and diffing against the screenshot validates
the whole tilemap and sprite path with no hardware involved.
"""
import argparse, os, shutil, subprocess, sys
from pathlib import Path

MAME_DIR = Path(os.getenv("MAME_DIR", r"C:\Emulation\Emulators\MAME"))
MAME_EXE = MAME_DIR / os.getenv("MAME_EXE", "arcade64.exe")


def rompath(repo):
    """This repo's gitignored roms/ FIRST, then whatever mame.ini already had.

    Captures are reference data the RTL gets checked against, so which ROM
    image produced one has to be answerable. Leaving it to mame.ini means the
    answer is "whatever that machine's rompath pointed at on the day", which
    can be an external drive that is not always mounted.

    -rompath REPLACES the ini value rather than adding to it, so the ini's own
    entries are read and appended -- otherwise a set that was deliberately not
    copied into roms/ would stop being findable, and MAME's "ROM not found"
    would be blamed on the capture script.
    """
    paths = [str(repo / "roms")]
    ini = MAME_DIR / "mame.ini"
    if ini.exists():
        for line in ini.read_text(errors="replace").splitlines():
            if line.strip().startswith("rompath"):
                for part in line.split(None, 1)[1].split(";"):
                    part = part.strip()
                    if not part:
                        continue
                    # ini paths are relative to MAME_DIR, absolute ones stay put
                    q = Path(part)
                    paths.append(str(q if q.is_absolute() else MAME_DIR / q))
                break
    seen, out = set(), []
    for q in paths:
        if q not in seen:
            seen.add(q)
            out.append(q)
    return ";".join(out)

# ---------------------------------------------------------------------------
# Per-game region map.
#
# seta.cpp has many distinct memory maps and they are NOT interchangeable --
# msgundam puts the sprite chip where rezon puts the tilemap VRAM. Each family
# below is transcribed from ONE `*_map` function in src/mame/seta/seta.cpp,
# named in its comment. A game that is not listed fails loudly rather than
# dumping zeros from a plausible-looking wrong address: read its map function
# and add it.
#
# Entries are name -> (address, byte length). The tap ranges are the video/mix
# register and both layer control blocks, because those are what a
# per-scanline renderer has to follow.
# ---------------------------------------------------------------------------
_TWO_LAYER = {                      # seta.cpp rezon_map / zingzip_map / wrofaero_map
    "workram":   (0x200000, 0x20000),   # 0x200000-0x21ffff, two declared blocks
    "workram2":  (0x300000, 0x10000),   # "nvram" on zombraid; wrofaero's stack
    "palette":   (0x700400, 0x000c00),
    "l0vram":    (0x800000, 0x004000),
    "l1vram":    (0x880000, 0x004000),
    "l0ctrl":    (0x900000, 0x000006),
    "l1ctrl":    (0x980000, 0x000006),
    "sprylow":   (0xa00000, 0x000600),
    "sprctrl":   (0xa00600, 0x000008),
    "sprcode":   (0xb00000, 0x004000),
    "x1snd":     (0xc00000, 0x004000),
}
# The X1-010 channel registers are the first 0x80 words; tapping them gives the
# register write log the Phase 0 sound spike is checked against.
_TWO_LAYER_TAPS = ((0x500000, 0x500007), (0x900000, 0x900005),
                   (0x980000, 0x980005), (0xc00000, 0xc000ff))


def _variant(base, **over):
    d = dict(base)
    d.update(over)
    return d


FAMILIES = {
    # rezon_map / zingzip_map / wrofaero_map
    "two_layer": (_TWO_LAYER, _TWO_LAYER_TAPS),
    # daioh_map -- identical but work RAM at 0x100000
    "daioh": (_variant(_TWO_LAYER, workram=(0x100000, 0x10000)), _TWO_LAYER_TAPS),
    # extdwnhl_map -- palette moved to 0x600400
    "extdwnhl": (_variant(_TWO_LAYER, palette=(0x600400, 0xc00),
                          x1snd=(0xe00000, 0x4000)),
                 ((0x500000, 0x500007), (0x900000, 0x900005),
                  (0x980000, 0x980005), (0xe00000, 0xe000ff))),
    # kamenrid_map / madshark_map -- vregs at 0x600003, not 0x500003
    # oisipuzl_map: the standard two-layer video addresses, but the palette is
    # at 0xc00400 and the sound at 0x700000.
    "oisipuzl": (_variant(_TWO_LAYER, workram=(0x200000, 0x10000),
                          palette=(0xc00400, 0xc00),
                          x1snd=(0x700000, 0x4000)),
                 _TWO_LAYER_TAPS),
    # magspeed_map: work RAM at 0x200000, palette at 0x700400.
    # magspeed_map: work RAM at 0x200000, palette at 0x700400, and vregs at
    # 0x500015 -- past the 8 bytes _TWO_LAYER_TAPS logs, so this one taps wider.
    "magspeed": (_variant(_TWO_LAYER, workram=(0x200000, 0x10000),
                          palette=(0x700400, 0xc00)),
                 ((0x500000, 0x500017), (0x900000, 0x900005),
                  (0x100000, 0x1000ff))),
    "kamenrid": (_variant(_TWO_LAYER, x1snd=(0xd00000, 0x4000)),
                 ((0x600000, 0x600007), (0x900000, 0x900005),
                  (0x980000, 0x980005), (0xd00000, 0xd000ff))),
    # msgundam_map -- sprite chip and tilemaps swap places
    "msgundam": ({
        "workram": (0x200000, 0x10000),
        "palette": (0x700400, 0x000c00),
        "sprylow": (0x800000, 0x000600),
        "sprctrl": (0x800600, 0x000008),
        "sprcode": (0x900000, 0x004000),
        "l0vram":  (0xa00000, 0x004000),
        "l1vram":  (0xa80000, 0x004000),
        "l0ctrl":  (0xb00000, 0x000006),
        "l1ctrl":  (0xb80000, 0x000006),
        "x1snd":   (0xc00000, 0x004000),
    }, ((0x500004, 0x500005), (0xb00000, 0xb00005), (0xb80000, 0xb80005),
        (0xc00000, 0xc000ff))),
    # blandia_map -- second palette bank for the palette-offset effect
    "blandia": ({
        "workram":  (0x200000, 0x10000),
        "workram2": (0x300000, 0x10000),
        "palette":  (0x700400, 0x000c00),
        "palette2": (0x703c00, 0x000c00),
        "sprylow":  (0x800000, 0x000600),
        "sprctrl":  (0x800600, 0x000008),
        "sprcode":  (0x900000, 0x004000),
        "l0ctrl":   (0xa00000, 0x000006),
        "l1ctrl":   (0xa80000, 0x000006),
        "l0vram":   (0xb00000, 0x004000),
        "l1vram":   (0xb80000, 0x004000),
        "x1snd":    (0xc00000, 0x004000),
    }, ((0x500000, 0x500007), (0xa00000, 0xa00005), (0xa80000, 0xa80005),
        (0xc00000, 0xc000ff))),
    # blandiap_map -- the prototype board. NOT blandia_map: it uses the zingzip
    # arrangement, with the second palette and the extra work RAM added.
    "blandiap": (_variant(_TWO_LAYER,
                          workram2=(0x300000, 0x10000),
                          palette2=(0x703c00, 0x00c00)),
                 _TWO_LAYER_TAPS),
    # drgnunit_map -- one layer. TWO work RAM regions: 0xf00000 is used by
    # qzkklogy, 0xffc000 by drgnunit and stg, and the reset SP (0x00fffffc,
    # confirmed with build_maincpu_hex.py --check) is in the second. Capture
    # both or a dump silently omits the stack.
    "drgnunit": ({
        "workram":  (0xf00000, 0x10000),
        "workram2": (0xffc000, 0x04000),
        "palette": (0x700000, 0x000400),
        "l0ctrl":  (0x800000, 0x000006),
        "l0vram":  (0x900000, 0x004000),
        "sprylow": (0xd00000, 0x000600),
        "sprctrl": (0xd00600, 0x000008),
        "sprcode": (0xe00000, 0x004000),
        "x1snd":   (0x100000, 0x004000),
    }, ((0x500000, 0x500007), (0x800000, 0x800005), (0x100000, 0x1000ff))),
    # thunderl_map -- no layers at all
    "thunderl": ({
        "workram": (0xffc000, 0x4000),
        "palette": (0x700000, 0x0400),
        "sprylow": (0xd00000, 0x0600),
        "sprctrl": (0xd00600, 0x0008),
        "sprcode": (0xe00000, 0x4000),
        "x1snd":   (0x100000, 0x4000),
    }, ((0x100000, 0x1000ff),)),
    # umanclub_map -- work RAM at 0x200000, palette at 0x300000. Nothing like
    # thunderl_map despite both being sprites-only boards.
    "umanclub": ({
        "workram": (0x200000, 0x10000),
        "palette": (0x300000, 0x00400),
        "sprylow": (0xa00000, 0x00600),
        "sprctrl": (0xa00600, 0x00008),
        "sprcode": (0xb00000, 0x04000),
        "x1snd":   (0xc00000, 0x04000),
    }, ((0xc00000, 0xc000ff),)),
    # blockcar_map -- different again
    "blockcar": ({
        "workram": (0xf00000, 0x4000),
        "palette": (0xb00000, 0x0400),
        "sprcode": (0xc00000, 0x4000),
        "sprylow": (0xe00000, 0x0600),
        "sprctrl": (0xe00600, 0x0008),
        "x1snd":   (0xa00000, 0x4000),
    }, ((0xa00000, 0xa000ff),)),
    # wits_map -- thunderl_map plus a spare RAM block above the sprite codes
    "wits": ({
        "workram":  (0xffc000, 0x4000),
        "workram2": (0xe04000, 0x4000),
        "palette":  (0x700000, 0x0400),
        "sprylow":  (0xd00000, 0x0600),
        "sprctrl":  (0xd00600, 0x0008),
        "sprcode":  (0xe00000, 0x4000),
        "x1snd":    (0x100000, 0x4000),
    }, ((0x100000, 0x1000ff),)),
    # atehate_map -- no layers, everything somewhere else again
    "atehate": ({
        "workram": (0x900000, 0x100000),   # 0x900000-0x9fffff, a full MB
        "palette": (0x700000, 0x00400),
        "sprylow": (0xa00000, 0x00600),
        "sprctrl": (0xa00600, 0x00008),
        "sprcode": (0xe00000, 0x04000),
        "x1snd":   (0x100000, 0x04000),
    }, ((0x100000, 0x1000ff),)),
    # pairlove_map -- sprites-only like thunderl, but nothing shares an
    # address with it. 2048 palette entries (0x1000 bytes), and a 0x200-word
    # "protection" block at 0x900000 that is not protection in the usual sense:
    # prot_r returns the current value and then reverts that cell to the
    # PREVIOUS value written to it, so it is a one-deep write history. Two
    # small RAMs in RTL, no algorithm to work out.
    "pairlove": ({
        "workram": (0xf00000, 0x10000),
        "palette": (0xb00000, 0x01000),
        "protram": (0x900000, 0x00400),
        "sprcode": (0xc00000, 0x04000),
        "sprylow": (0xe00000, 0x00600),
        "sprctrl": (0xe00600, 0x00008),
        "x1snd":   (0xa00000, 0x04000),
    }, ((0xa00000, 0xa000ff),)),
}

GAMES = {
    "rezon": "two_layer", "rezono": "two_layer", "zingzip": "two_layer",
    # eightfrc runs zingzip_map, which is the plain two-layer map.
    "eightfrc": "two_layer",
    "oisipuzl": "oisipuzl",
    "gundharac": "two_layer", "jjsquawko": "two_layer",
    "zombraidp": "two_layer", "zombraidpj": "two_layer",
    "wrofaero": "two_layer", "gundhara": "two_layer", "gundharac": "two_layer",
    "jjsquawk": "two_layer", "jjsquawko": "two_layer", "zombraid": "two_layer",
    "daiohc": "two_layer",
    # daioh/daioha run daioh_map (work RAM at 0x100000); daiohp/daiohp2 run
    # daiohp_map and daiohc runs wrofaero_map, both of which put it at
    # 0x200000 -- so the prototypes are NOT in their parent's family.
    "daioh": "daioh", "daioha": "daioh",
    "daiohp": "two_layer", "daiohp2": "two_layer",
    "extdwnhl": "extdwnhl", "sokonuke": "extdwnhl",
    "kamenrid": "kamenrid", "madshark": "kamenrid",
    "magspeed": "magspeed",
    "msgundam": "msgundam", "msgundam1": "msgundam",
    "blandia": "blandia", "blandiap": "blandiap",
    "drgnunit": "drgnunit", "stg": "drgnunit",
    "qzkklogy": "drgnunit", "qzkklgy2": "drgnunit",
    "thunderl": "thunderl", "thunderla": "thunderl",
    "blockcar": "blockcar",
    "umanclub": "umanclub", "neobattl": "umanclub",
    "wits": "wits",
    "atehate": "atehate",
    "pairlove": "pairlove",
    # NOT YET TRANSCRIBED -- read the map function in seta.cpp and add them:
    #   eightfrc, oisipuzl, magspeed, krzybowl, orbs, keroppi, keroppij
    #
    # roms/ is a MERGED collection, so a clone is captured from its PARENT's
    # zip -- MAME resolves it from there. mame_capture.py passes the set name
    # to MAME directly, so nothing extra is needed here.
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--frame", type=int, default=600,
                    help="frame number to capture at (60 = 1 second)")
    ap.add_argument("--name", help="output subdirectory under debug/ (default: <game>-f<frame>)")
    ap.add_argument("--boot-trace", type=int, metavar="N",
                    help="instead of a frame capture, log the first N main-CPU "
                         "bus accesses from reset -- the ground truth the RTL's "
                         "own boot trace is diffed against. Needs no region map, "
                         "so it works for any set")
    ap.add_argument("--wlog", action="store_true",
                    help="also log every write to the video/mix register and "
                         "the layer control blocks, tagged with frame and the "
                         "SCANLINE in force -- the reference for the games "
                         "x1_012.cpp says MAME renders wrong")
    ap.add_argument("--dip", action="append", default=[], metavar="NAME=SETTING",
                    help="set a DIP switch by name before the game runs, e.g. "
                         "--dip 'Flip Screen=On'. Repeatable. A name or setting "
                         "the machine does not have is fatal, not ignored -- a "
                         "silently unapplied DIP produces a reference frame that "
                         "matches for the wrong reason.")
    ap.add_argument("--show", action="store_true",
                    help="render to a window instead of running headless")
    ap.add_argument("--tap", action="append", default=[], metavar="LO:HI",
                    help="an extra address range for --wlog, hex, e.g. "
                         "--tap 800000:803fff to see VRAM writes. Repeatable. "
                         "The family's own taps cover only the control "
                         "registers.")
    a = ap.parse_args()

    if not MAME_EXE.exists():
        sys.exit(f"MAME not found at {MAME_EXE} (set MAME_DIR / MAME_EXE)")

    # Boot tracing taps the whole address space, so it needs no region map and
    # works for sets that have not been transcribed yet.
    if a.boot_trace:
        regions, taps = "", ""
    else:
        # Resolve the region map BEFORE anything is deleted below, so an
        # unknown game fails without destroying a previous capture.
        if a.game not in GAMES:
            sys.exit(f"no region map for '{a.game}'. Read its *_map function in "
                     f"src/mame/seta/seta.cpp and add it to FAMILIES/GAMES -- a "
                     f"guessed address dumps zeros in silence. "
                     f"Known: {', '.join(sorted(GAMES))}")
        fam, tap_ranges = FAMILIES[GAMES[a.game]]
        regions = ",".join(f"{n}:{addr:x}:{ln:x}"
                           for n, (addr, ln) in sorted(fam.items()))
        extra = tuple(tuple(int(x, 16) for x in t.split(":")) for t in a.tap)
        taps = ",".join(f"{lo:x}:{hi:x}" for lo, hi in tap_ranges + extra)

    repo = Path(__file__).resolve().parent.parent
    out = repo / "debug" / (a.name or f"{a.game}-f{a.frame}")

    # START CLEAN. MAME numbers snapshots by finding the first free slot in the
    # directory, so re-running into an existing capture leaves a MIXTURE: dumps
    # from one run beside snapshots from several. Picking "the newest snapshot"
    # out of that pairs an image from one frame with memory from another, and
    # the resulting diff looks like a catastrophic rendering fault -- 1% pixel
    # match, with the RTL drawing a title screen while the reference showed a
    # combat scene. Nothing warns; the files all look plausible.
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    env = dict(os.environ)
    env.update(
        SETA_OUT=out.as_posix(),
        SETA_FRAME=str(a.frame),
        SETA_TAG=a.game,
        SETA_REGIONS=regions,
        SETA_TAPS=taps if a.wlog else "",
        SETA_DIPS=";".join(a.dip),
        SETA_TRACE_N=str(a.boot_trace or 0),
        SETA_SCRIPT=(repo / "scripts" / "mame" /
                     ("boottrace.lua" if a.boot_trace else "capture.lua")).as_posix(),
    )

    # PASS 1 of a --dip capture: let MAME author its own configuration file.
    #
    # MAME applies cfg/<set>.cfg at POWER-ON, before any autoboot script runs.
    # That is the only moment early enough: most of these games read the DIP
    # switches once during their own initialisation, so a switch set from the
    # capture script never reaches them. Measured -- with the DIP set from the
    # capture script only, thunderl came back flipped and wits, blockcar,
    # umanclub, neobattl, atehate and pairlove did not.
    #
    # The cfg directory is per-capture, so nothing here touches the user's own
    # MAME configuration, and the seed pass writes the file through MAME itself
    # rather than hand-authoring XML that would have to track MAME's format.
    cfg_dir = out / "cfg"
    if a.dip:
        cfg_dir.mkdir(parents=True, exist_ok=True)
        seed = [
            str(MAME_EXE), a.game, "-skip_gameinfo", "-nodebug", "-nothrottle",
            "-sound", "none", "-video", "none", "-nowindow",
            "-autoboot_delay", "0",
            "-autoboot_script", (repo / "scripts" / "mame" / "setdip.lua").as_posix(),
            "-cfg_directory", cfg_dir.as_posix(),
            "-rompath", rompath(repo),
            "-seconds_to_run", "10",
        ]
        sr = subprocess.run(seed, cwd=str(MAME_DIR), env=env,
                            capture_output=True, text=True, timeout=300)
        for line in (sr.stdout or "").splitlines():
            if line.startswith("SEED") or line.startswith("LUAFAIL"):
                print("  " + line)
        written = cfg_dir / f"{a.game}.cfg"
        info = out / "dipinfo.txt"
        if not written.exists() or not info.exists():
            print((sr.stdout or sr.stderr or "").strip()[-1200:])
            sys.exit(f"the DIP seed pass produced no {written.name} / "
                     f"{info.name}; nothing would be applied at power-on.")

        # MAME saves a DIPSWITCH entry only when the wanted value is non-zero.
        # thunderl's "On" is 0x200 and persisted; wits and blockcar have
        # "On" = 0 -- the same switch, opposite sense -- and nothing was
        # written. So build the <input> section from the port data setdip.lua
        # reported, and keep the mameconfig version out of the file MAME itself
        # just wrote rather than hardcoding one.
        text = written.read_text(encoding="utf-8-sig", errors="replace")
        ports = []
        for line in info.read_text().splitlines():
            f = line.split("\t")
            if len(f) == 4:
                tag, mask, defv, val = f[0], int(f[1]), int(f[2]), int(f[3])
                ports.append('            <port tag="%s" type="DIPSWITCH" '
                             'mask="%d" defvalue="%d" value="%d" />'
                             % (tag, mask, defv, val))
        if not ports:
            sys.exit("%s named no ports; the DIP was never applied." % info)

        block = "        <input>\n" + "\n".join(ports) + "\n        </input>\n"
        if "<input>" in text:
            head, _, rest = text.partition("        <input>\n")
            _, _, tail = rest.partition("        </input>\n")
            text = head + block + tail
        else:
            anchor = '<system name="%s">\n' % a.game
            text = text.replace(anchor, anchor + block, 1)
        written.write_text(text, encoding="utf8")

        if "DIPSWITCH" not in written.read_text(errors="replace"):
            sys.exit(f"no DIPSWITCH entry ended up in {written}. Without it the "
                     f"capture would run with default switches and look like a "
                     f"success.")

    cmd = [
        str(MAME_EXE), a.game,
        "-skip_gameinfo",
        # MUST be explicit: this MAME install has `debug 1` in its mame.ini, so
        # every launch otherwise opens the debugger and HALTS at startup. The
        # autoboot script still runs and prints, which makes it look like it is
        # working, but the machine never advances a frame and the capture's
        # frame notifier never fires -- it just sits there.
        "-nodebug",
        "-nothrottle",              # run as fast as the host allows
        "-sound", "none",
        "-autoboot_delay", "0",
        # Through the bootstrap, so a Lua syntax or runtime error is written to
        # a file instead of only appearing in a modal dialog nobody can see.
        "-autoboot_script", (repo / "scripts" / "mame" / "run.lua").as_posix(),
        # Snapshots land beside the dumps rather than in MAME's own snap/ tree.
        "-snapshot_directory", out.as_posix(),
        # NATIVE view: the screen's own bitmap, no cabinet rotation, no
        # scaling, no artwork. Without it MAME writes the snapshot through the
        # render pipeline, and over the seven Group A sets a ROT270 game's
        # snapshot came out 180 degrees from screen space while ROT0 and ROT90
        # came out unrotated. The file is 384x240 either way, so nothing about
        # it says which -- the first sweep read as a renderer bug in exactly
        # the games that happen to be vertical.
        #
        # The snapshot, not screen:pixels(), is the synchronised reference.
        # video:snapshot() re-renders from the state that is live when it is
        # called, which is the state the region dumps in the same notifier
        # read; scr:pixels() returns the bitmap MAME rendered at the end of the
        # VISIBLE area, one vblank earlier, before the game's vblank handler
        # rewrote sprite RAM. Measured: model-vs-snapshot 0 pixels on all 24
        # sweep frames, model-vs-pixels() up to 4.3% on frames where the game
        # writes during vblank.
        "-snapview", "native",
        # See rompath(): this repo's roms/ first, then mame.ini's own entries.
        "-rompath", rompath(repo),
        # A hard stop, so a script that never reaches its frame cannot leave
        # MAME running forever. Generous: at -nothrottle a frame is quick, but
        # the guard is wall-clock emulated time, not real time.
        "-seconds_to_run", str(max(30, a.frame // 60 + 20)),
    ]
    if a.dip:
        cmd += ["-cfg_directory", cfg_dir.as_posix()]
    # mame.ini also sets `window 1`, so the headless case overrides it
    # explicitly rather than relying on -video none alone.
    cmd += (["-window", "-nomaximize"] if a.show
            else ["-video", "none", "-nowindow"])

    print("  " + " ".join(cmd))
    # cwd matters: MAME resolves mame.ini, and therefore rompath, relative to it.
    r = subprocess.run(cmd, cwd=str(MAME_DIR), env=env,
                       capture_output=True, text=True, timeout=900)
    for line in (r.stdout or "").splitlines():
        if line.startswith("CAPTURE") or "rror" in line:
            print("  " + line)
    if r.returncode != 0:
        print((r.stderr or "").strip()[:1500])

    err = out / "lua_error.txt"
    if err.exists():
        print("--- LUA FAILURE ---")
        print(err.read_text().strip())
        sys.exit("the capture script failed; nothing was captured")

    got = sorted(p.name for p in out.iterdir())
    if a.boot_trace:
        tr = out / f"{a.game}_boot.trace"
        if not tr.exists():
            print((r.stdout or "").strip()[-2000:])
            sys.exit(f"no trace written to {out}")
        body = [l for l in tr.read_text().splitlines() if not l.startswith("#")]
        print(f"{tr}: {len(body)} accesses")
        for l in body[:8]:
            print("  " + l)
        return
    if not any(n.endswith(".bin") for n in got):
        # Show MAME's own output. A Lua SYNTAX error in the autoboot script
        # makes MAME pop a modal dialog and sit there -- headless, that looks
        # exactly like "the script ran and quietly did nothing", and the run
        # only ends when the timeout kills it. Printing what MAME said turns
        # that into a one-line diagnosis instead of a hunt.
        print("--- MAME stdout ---")
        print((r.stdout or "").strip()[-2000:])
        print("--- MAME stderr ---")
        print((r.stderr or "").strip()[-2000:])
        sys.exit(f"no dumps written to {out}")

    # MAME nests snapshots one level down, under the system name, and numbers
    # them 0000.png, 0001.png ... Search recursively and give the newest a
    # stable name so downstream tooling has something fixed to point at.
    snaps = sorted(out.rglob("[0-9][0-9][0-9][0-9].png"))
    if len(snaps) == 1:
        shutil.copyfile(snaps[0], out / "reference.png")
    elif len(snaps) > 1:
        # Cannot happen now the directory starts clean, but if it ever does,
        # refuse rather than guess which image goes with the dumps.
        sys.exit(f"{len(snaps)} snapshots in {out} -- cannot tell which frame "
                 f"the dumps belong to; delete the directory and re-capture")
    else:
        print("  WARNING: no snapshot was written")

    print(f"\n{out}:")
    for n in sorted(p.name for p in out.iterdir()):
        print(f"  {n:24s} {(out / n).stat().st_size:>8,} bytes")


main()
