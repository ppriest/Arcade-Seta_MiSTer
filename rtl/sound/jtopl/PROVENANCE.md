# jtopl (YM3812 / OPL2) provenance

**In this repository:** copied from Arcade-Fuuki_MiSTer's `rtl/sound/jtopl/` at its commit 8e70617, unchanged, for Thundercade's YM2203 (jt03) and YM3812 (jtopl2) on the Seta_Downtown core. The notes below are that repository's.

Vendored from https://github.com/jotego/jtopl, `master` at commit
`7ac0c819ad274e208206f2acccbbde80aa06ed1a`, fetched file by file from GitHub's contents API on
2026-09-06. Only `hdl/` and `LICENSE` were taken. Used as FG-2's YM3812 through the `jtopl2`
wrapper (`jtopl #(.OPL_TYPE(2))`); its timer IRQ is the Z80's INT line, as fuukifg2.cpp wires
`ym2.irq_handler()`.

`jt2413.v` and the `jtopll_*` files are the OPLL (YM2413) variant, present in the tree but not
listed in `files.qip` and excluded from simulation.

**License: GPL-3.0**, the same posture as jt12/jt49 -- see `rtl/sound/jt12/PROVENANCE.md`.
