#!/usr/bin/env python3
"""Build Quartus from a staged snapshot of HEAD, leaving the tree free.

Ported from the Fuuki core (D:\\Arcade-Fuuki_MiSTer), which had in turn ported it
from Psikyo. It exists for the reason Fuuki paid for by leaving it unported:
a Quartus compile takes about thirteen minutes, and for all of it the tree
has to be left alone. Editing sources during a run risks the build, and NOT
editing them means every unrelated task waits. See docs/WORKFLOW.md.

The compile runs in a dedicated git worktree at <repo>/build (gitignored),
so the main tree is free the moment the build starts, and every scrap of
Quartus scratch -- db/, incremental_db/, output_files/, the log -- lands
under build/ instead of the repo root.

The build is exactly HEAD:
  * a dirty tree is refused by default, so what is in the editor and what is
    compiled cannot silently diverge. --allow-dirty builds HEAD anyway,
    explicitly acknowledging the uncommitted edits are EXCLUDED.
  * the built commit is written to build/BUILT_COMMIT beside the log, so
    every .rbf maps to one commit.

    python scripts/build_staged.py                 # compile HEAD, Seta_stp
    python scripts/build_staged.py --rev Seta      # the release revision
    python scripts/build_staged.py --seed 12345    # try another placement
    python scripts/build_staged.py --allow-dirty   # HEAD, ignoring edits

TWO REVISIONS, one source. Seta_stp.qsf defines DEBUG_ISSP: the six ISSP
probes are built and the OSD's Debug page is visible. Seta.qsf does not, so
the release build compiles the probes, their ring buffer and their counters
out and hides the page. The default here is the instrumented one, because
that is what bring-up iterates on; ship the other.

Outputs, all inside the stage, named after the revision:
    build/q_staged.log                     the build log (deploy.py's gate reads it)
    build/output_files/Seta_stp.rbf        the bitstream
    build/output_files/Seta_stp.sta.summary
    build/BUILT_COMMIT                     commit, time and SEED

Deploy it by pointing deploy.py at the stage:
    python scripts/deploy.py --rbf-only --log build/q_staged.log \\
        --rbf build/output_files/Seta_stp.rbf \\
        --sta build/output_files/Seta_stp.sta.summary

The worktree persists between builds -- Quartus's db/ with it, which costs
nothing for full compiles and avoids re-checkout churn -- and each run
hard-resets it to HEAD. A .build_running marker refuses two overlapping
staged builds.

scripts/build.sh still exists and still builds in-tree; use it when you want
the compile to see uncommitted work and are willing to leave the tree alone.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

QUARTUS_BIN = os.environ.get(
    "QUARTUS_BIN", r"C:\intelFPGA_lite\17.0\quartus\bin64")
# The revision being built; main() replaces it from --rev. Every output path
# and the .qsf the seed is patched into are named after it.
REV = "Seta_stp"


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit("FAILED: %s\n%s%s" % (" ".join(cmd), r.stdout, r.stderr))
    return r.stdout.strip()


def read_slacks(summary):
    """Print every clock's setup slack; return the ones that fail.

    All of them, not clk_sys alone: a violation on any clock is a violation,
    and scripts/build.sh gates on exactly the same rule.
    """
    out = []
    if not os.path.exists(summary):
        print("no timing summary at %s -- treating as unverified" % summary)
        return out
    lines = open(summary, errors="replace").read().splitlines()
    for i, ln in enumerate(lines):
        if not ln.startswith("Type  : Setup ") or i + 2 >= len(lines):
            continue
        clk = ln.split("Setup ", 1)[1].strip().strip("'")
        try:
            slack = float(lines[i + 1].split(":", 1)[1])
        except (IndexError, ValueError):
            continue
        tns = lines[i + 2].split(":", 1)[1].strip()
        if "emu|pll" in clk:
            print("worst clk_sys setup: Slack : %.3f / TNS   : %s" % (slack, tns))
        if slack < 0:
            out.append((clk[-58:], slack, tns))
    return out


def report_resources(stage):
    fit = os.path.join(stage, "output_files", "%s.fit.summary" % REV)
    if not os.path.exists(fit):
        return
    keep = ("Logic utilization", "Total registers", "Total block memory bits",
            "Total RAM Blocks", "Total DSP Blocks", "Total pins", "Total PLLs")
    for ln in open(fit, errors="replace"):
        if any(ln.strip().startswith(k) for k in keep):
            print("  " + ln.strip())


# Every block that MUST survive to the fitted netlist, by the name Quartus
# writes into the fit report. A build that passes timing because part of the
# design was optimised away is the worst kind of green, and it has happened
# here once already: widening the PLL to a third output set number_of_clocks(3)
# and the frequency but left the altera_pll instance's `.outclk` concatenation
# two wide, so outclk_2 dangled. clk_video was undriven, every register in
# arcade_video went "Stuck at GND due to stuck port clock", the whole video
# chain vanished -- 4,000 ALMs, 35 RAM blocks and 9 DSPs lighter -- and the
# build reported +0.238 ns, TIMING MET.
#
# Slack alone cannot catch that. Presence has to be asserted separately.
REQUIRED_INSTANCES = (
    "TG68KdotC_Kernel",   # the CPU
    "x1_001",             # sprites
    "x1_010",             # sound
    "seta_video",         # palette, timing, the two scanline interrupts
    "sdram",              # the memory backend
    "arcade_video",       # the framework video chain...
    "Hq2x",               # ...including the scandoubler's blender
    "screen_rotate_two",  # HDMI rotation
)

# Macros the design needs defined, and what breaks without each.
#
# PRESENCE IS NOT CONNECTION. screen_rotate_two was in the fitted netlist of
# every build up to 20260910 -- 87 mentions in the fit report -- while HDMI
# rotation did nothing, because MISTER_FB was undefined, emu therefore had no
# FB_* ports, and the rotator's .FB_EN(FB_EN) and friends bound to implicitly
# declared wires. Its DDRAM side stayed connected, so it neither vanished nor
# went stuck-at, and REQUIRED_INSTANCES above could not have caught it.
REQUIRED_MACROS = {
    "MISTER_FB": "HDMI rotation and 180 flip; without it only the aspect "
                 "ratio changes",
}


def check_macros(stage):
    """Fail if a required VERILOG_MACRO is missing or commented out."""
    qsf = os.path.join(stage, "%s.qsf" % REV)
    try:
        with open(qsf, encoding="utf8", errors="replace") as f:
            live = [ln for ln in f if not ln.lstrip().startswith("#")]
    except OSError as e:
        return ["cannot read %s: %s" % (qsf, e)]
    text = "".join(live)
    return ['%s is not defined in %s -- %s' % (m, os.path.basename(qsf), why)
            for m, why in REQUIRED_MACROS.items()
            if 'VERILOG_MACRO "%s=' % m not in text]


def check_present(stage):
    """Fail if a block that must exist is missing from the fitted netlist."""
    rpt = os.path.join(stage, "output_files", "%s.fit.rpt" % REV)
    try:
        text = open(rpt, errors="replace").read()
    except OSError:
        print("  (no fit report at %s -- cannot check)" % rpt)
        return []
    missing = [n for n in REQUIRED_INSTANCES if n not in text]
    for n in REQUIRED_INSTANCES:
        print("  %-18s %s" % (n, "present" if n in text else "MISSING"))
    return missing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rev", default="Seta_stp",
                    help="Quartus revision: Seta_stp (default) builds the "
                         "ISSP probes and the Debug page, Seta is the "
                         "release build with both compiled out")
    ap.add_argument("--seed", type=int,
                    help="override the fitter SEED in the STAGED .qsf "
                         "(placement only; worth trying before restructuring "
                         "RTL for a sub-ns violation)")
    ap.add_argument("--allow-negative-slack", action="store_true",
                    help="do not fail on a build that misses timing; the "
                         "shortfall must then be stated wherever it is used")
    ap.add_argument("--allow-dirty", action="store_true",
                    help="build HEAD even though the tree has uncommitted "
                         "changes (they are NOT included in the build)")
    args = ap.parse_args()

    global REV
    REV = args.rev

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    stage = os.path.join(here, "build")

    # scripts/hwlock.py: a compile must not start while a JTAG tool is
    # reading the device. One PC, one USB-Blaster, three cores -- the marker
    # is machine-wide, so this also refuses while another core is probing.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from hwlock import require_no_jtag
    require_no_jtag("this build")

    dirty = run(["git", "-C", here, "status", "--porcelain"])
    # Untracked files are not part of HEAD either, but they are usually
    # scratch; only tracked modifications are treated as a divergence worth
    # refusing over.
    tracked_dirty = "\n".join(ln for ln in dirty.splitlines()
                              if not ln.startswith("??"))
    if tracked_dirty and not args.allow_dirty:
        sys.exit("tree is dirty -- commit first (the build is exactly HEAD), "
                 "or pass --allow-dirty to build HEAD without these:\n"
                 + tracked_dirty)

    head = run(["git", "-C", here, "rev-parse", "HEAD"])
    head_short = run(["git", "-C", here, "rev-parse", "--short", "HEAD"])

    marker = os.path.join(stage, ".build_running")
    if os.path.exists(marker):
        sys.exit("a staged build already appears to be running (%s exists) -- "
                 "wait for it, or delete the marker if it is stale" % marker)

    # Create or update the stage worktree to exactly HEAD.
    if not os.path.isdir(os.path.join(stage, ".git")) and \
       not os.path.isfile(os.path.join(stage, ".git")):
        run(["git", "-C", here, "worktree", "add", "--detach", stage, head])
    else:
        # --force: a seed override patches the STAGED .qsf, and a leftover
        # patch must never wedge the next build. The stage is a disposable
        # copy of HEAD; local changes in it are always discardable.
        run(["git", "-C", stage, "checkout", "--force", "--detach", head])
        run(["git", "-C", stage, "reset", "--hard", head])

    # Fitter seed override, patched into the STAGE only, so a build stays
    # reproducible from its commit plus this flag.
    if args.seed is not None:
        qsf = os.path.join(stage, "%s.qsf" % REV)
        if not os.path.isfile(qsf):
            sys.exit("no %s to patch a SEED into" % qsf)
        text = open(qsf, encoding="utf-8", errors="replace").read()
        new, n = re.subn(r"(?m)^set_global_assignment -name SEED .*$",
                         "set_global_assignment -name SEED %d" % args.seed, text)
        if n == 0:
            new = text.rstrip("\n") + \
                "\nset_global_assignment -name SEED %d\n" % args.seed
        elif n > 1:
            sys.exit("expected at most one SEED assignment in %s, found %d" % (qsf, n))
        open(qsf, "w", encoding="utf-8", newline="\n").write(new)
        print("seed:   %d (stage only)" % args.seed)

    # THE SEED IS PART OF THE BUILD. Two .rbf files from the same commit at
    # different seeds are not interchangeable: 10000019 (seed 2) reported every
    # clock domain positive and broke five games on hardware, where 10000020
    # (seed 7, a WORSE worst slack) runs them all. Record it, or a good build
    # cannot be rebuilt. LESSONS_LEARNED, "A clean STA summary is a property of
    # one placement".
    stamp = "%s  %s  seed=%s\n" % (
        head, datetime.datetime.now().isoformat(),
        args.seed if args.seed is not None else "default")
    open(os.path.join(stage, "BUILT_COMMIT"), "w").write(stamp)
    print("stage:  %s" % stage)
    print("rev:    %s" % REV)
    print("commit: %s (%s)" % (head_short, head))
    if dirty and args.allow_dirty:
        print("NOTE:   the tree has uncommitted changes and they are NOT in "
              "this build")

    quartus = os.path.join(QUARTUS_BIN, "quartus_sh.exe")
    log_path = os.path.join(stage, "q_staged.log")
    open(marker, "w").write(stamp)
    try:
        with open(log_path, "w") as log:
            subprocess.run([quartus, "--flow", "compile", REV, "-c", REV],
                           cwd=stage, stdout=log, stderr=subprocess.STDOUT)
    finally:
        os.remove(marker)

    tail = open(log_path, errors="replace").read().splitlines()[-25:]
    ok = any("Full Compilation was successful" in ln for ln in tail)
    for ln in tail:
        if any(k in ln for k in ("successful", "Error", "Elapsed")):
            print(ln.strip())

    print("")
    print("==== resource usage ====")
    report_resources(stage)
    print("")
    print("==== the design is still there ====")
    missing = check_present(stage)
    bad_macros = check_macros(stage)
    for m in REQUIRED_MACROS:
        print("  %-18s %s" % (m, "undefined" if any(m in b for b in bad_macros)
                                   else "defined"))

    print("")
    print("==== timing ====")
    violations = read_slacks(
        os.path.join(stage, "output_files", "%s.sta.summary" % REV))

    if bad_macros:
        sys.exit("\nBUILD MISCONFIGURED --\n  " + "\n  ".join(bad_macros))

    if missing:
        sys.exit(
            "\nDESIGN INCOMPLETE -- %s missing from the fitted netlist.\n"
            "Whatever this build's timing says, it is not a measurement of the\n"
            "design you think you built. Look for an undriven clock or reset:\n"
            "  grep 'Stuck at GND due to stuck port clock' %s\n"
            % (", ".join(missing),
               os.path.join(stage, "output_files", "%s.map.rpt" % REV)))

    if not ok:
        sys.exit("BUILD FAILED -- see %s" % log_path)

    if violations and not args.allow_negative_slack:
        print("")
        for clk, slack, tns in violations:
            print("  FAILING: %-58s %8.3f  TNS %s" % (clk, slack, tns))
        sys.exit(
            "\nTIMING NOT MET -- %d clock(s) fail. The .rbf at\n"
            "  %s\nis not trustworthy. Close timing, try --seed, or pass\n"
            "--allow-negative-slack deliberately."
            % (len(violations),
               os.path.join(stage, "output_files", "%s.rbf" % REV)))
    if violations:
        print("")
        print("WARNING: --allow-negative-slack given; this build misses timing "
              "on %d clock(s)." % len(violations))

    rbf = os.path.join(stage, "output_files", "%s.rbf" % REV)
    print("\nOK -- deploy with:\n"
          "  python scripts/deploy.py --rbf-only --log \"%s\" \\\n"
          "      --rbf \"%s\" \\\n"
          "      --sta \"%s\""
          % (log_path, rbf,
             os.path.join(stage, "output_files", "%s.sta.summary" % REV)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
