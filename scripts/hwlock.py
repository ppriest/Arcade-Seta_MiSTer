#!/usr/bin/env python3
"""Keep JTAG and Quartus off this machine at the same time.

Shared by the Fuuki, Psikyo and Seta cores -- one PC, one USB-Blaster, one
Quartus, and a marker outside any of the repos so all three see each other.

Running a JTAG session (read_issp.tcl, memdump.py, the tracer readout) while
a Quartus compile is in flight has taken this PC down three times:
KERNEL_SECURITY_CHECK_FAILURE, bugcheck 0x139 -- a corrupted kernel list
entry -- on 2026-09-06 at 12:20, 12:27 and again that evening. Each one cost
a running measurement, and the third cost a frozen fault state that had
taken a while to reach.

It was written down as a caution after the first two and happened anyway, so
it is enforced here rather than remembered. Both directions:

  * a JTAG tool refuses to start while Quartus OR ModelSim is running;
  * a build, or a simulation, refuses to start while a JTAG tool holds the
    marker.

Quartus and ModelSim are NOT a hazard to each other: builds and simulations
may run side by side, and several of either at once.

The marker is a file rather than a lock object because the JTAG side is a
mix of Python and quartus_stp Tcl, and a file is the only thing both can
agree on. It carries the pid and what the session was for, and a stale one
(whose pid is gone) is cleared automatically -- a crashed tool must not
wedge every later build.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# MACHINE-WIDE, not per-repo. There are three MiSTer cores on this PC --
# Fuuki, Psikyo and Seta -- sharing one USB-Blaster and one Quartus install,
# and the bugcheck does not care which repo started which half. A marker
# under one repo's build/ would let a Seta compile start while a Fuuki probe
# was reading, which is exactly the combination being guarded against. It
# lives beside the user profile so every copy of this file agrees on it.
MARKER = Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "mister_jtag_running"


def quartus_processes():
    """Names of running Quartus AND ModelSim processes, empty if none.

    Both are a hazard to a concurrent JTAG session; they are not a hazard
    to each other, and several builds or simulations may run side by side.
    """
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Get-Process quartus*,vsim*,vlog,vcom,vlib -ErrorAction SilentlyContinue | "
             "Select-Object -ExpandProperty ProcessName"],
            capture_output=True, text=True, timeout=30)
        return [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
    except Exception:
        # If the check itself cannot run, do not block the tool -- an
        # unavailable guard is not a reason to stop working.
        return []


def _pid_alive(pid):
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "if (Get-Process -Id %d -ErrorAction SilentlyContinue) "
             "{ 'yes' } else { 'no' }" % pid],
            capture_output=True, text=True, timeout=30)
        return r.stdout.strip() == "yes"
    except Exception:
        return False


def read_marker():
    """(pid, what) if a live JTAG session holds the marker, else None.

    A marker whose process has gone is stale and is removed here.
    """
    if not MARKER.exists():
        return None
    try:
        pid_s, what = MARKER.read_text(encoding="utf-8").split("\n", 1)
        pid = int(pid_s.strip())
    except Exception:
        MARKER.unlink(missing_ok=True)
        return None
    if not _pid_alive(pid):
        MARKER.unlink(missing_ok=True)
        return None
    return pid, what.strip()


def require_no_quartus(what="this JTAG session"):
    """Refuse to run a JTAG tool while Quartus is compiling."""
    procs = quartus_processes()
    if procs:
        sys.exit(
            "REFUSING %s: Quartus/ModelSim is running (%s).\n"
            "JTAG concurrent with either has bugchecked this PC (0x139). "
            "Wait for it, or stop it deliberately."
            % (what, ", ".join(sorted(set(procs)))))


def require_no_jtag(what="this build"):
    """Refuse to start a build while a JTAG tool holds the marker."""
    held = read_marker()
    if held:
        pid, why = held
        sys.exit(
            "REFUSING %s: a JTAG session is running (pid %d, %s).\n"
            "JTAG concurrent with a compile has bugchecked this PC three "
            "times (0x139). Wait for it, or kill it deliberately and delete\n"
            "  %s" % (what, pid, why, MARKER))


if __name__ == "__main__":
    # command-line form for shell scripts: exit non-zero if a JTAG session
    # holds the marker
    if len(sys.argv) >= 2 and sys.argv[1] == "--require-no-jtag":
        require_no_jtag(sys.argv[2] if len(sys.argv) > 2 else "this build")
        sys.exit(0)


class jtag_session:
    """Context manager: guard, take the marker, release it on the way out."""

    def __init__(self, what="jtag"):
        self.what = what

    def __enter__(self):
        require_no_quartus(self.what)
        MARKER.parent.mkdir(parents=True, exist_ok=True)
        MARKER.write_text("%d\n%s at %s\n"
                          % (os.getpid(), REPO.name + ": " + self.what, time.strftime("%H:%M:%S")),
                          encoding="utf-8")
        return self

    def __exit__(self, *exc):
        MARKER.unlink(missing_ok=True)
        return False
