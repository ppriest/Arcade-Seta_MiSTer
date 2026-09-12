#!/usr/bin/env python3
"""Read the core's ISSP probes over JTAG, holding the machine-wide hwlock.

    python scripts/read_issp.py D              # decode instance D
    python scripts/read_issp.py C clear        # further args go to the Tcl

scripts/read_issp.tcl does the reading; run it through this. quartus_stp
started bare takes no marker, so a build or a simulation -- from this repo or
another core's -- could start underneath it, which is the combination
scripts/hwlock.py exists to prevent. This refuses to start while Quartus or
ModelSim is running, and holds the marker while it reads.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from hwlock import jtag_session  # noqa: E402


def read(*args, capture=False):
    """Run read_issp.tcl under the lock; the CompletedProcess."""
    with jtag_session("read_issp " + " ".join(args)):
        return subprocess.run(["quartus_stp", "-t", "scripts/read_issp.tcl", *args],
                              cwd=REPO, capture_output=capture, text=True)


if __name__ == "__main__":
    sys.exit(read(*sys.argv[1:]).returncode)
