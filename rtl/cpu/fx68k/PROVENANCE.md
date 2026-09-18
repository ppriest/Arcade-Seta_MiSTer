# fx68k provenance

Cycle-accurate 68000, Copyright (c) 2018, 2021 Jorge Cwik. GPLv3 (`LICENSE`).
Upstream: https://github.com/ijor/fx68k.

Replaces TG68K.C as the main CPU: `sim/tg68k_pace_tb` measured TG68K running
a `nop; dbra` loop in 4 clock enables an iteration against the 68000's 14, and
Twin Eagle's boot wait for its sub CPU lasted 5 ms instead of 18.

## Chain of custody

| Stage | What |
|-|-|
| Taken from | `Arcade-SegaXBoard_MiSTer-1.0.0/rtl/cpu/fx68k/` (a local copy of that release) |

SHA-1 of that copy:

| file | SHA-1 |
|-|-|
| LICENSE | 31a3d460bb3c7d98845187c716a30db81c44b615 |
| README.md | d2d7dc45e734479f3e80d23ca56c1fd0d11dc391 |
| fx68k.sv | c4eca36551004414145bdebf2d51ad31e37d3c70 |
| fx68kAlu.sv | 2147c8a58eb6cf55189e8fea787d59a55d23192a |
| uaddrPla.sv | 1c9d9dc262c2fcf0c2f0fcb83b1161b2c91f4aee |
| microrom.mem | 62036424b29dfd412e7091bd1e331b14e767caa0 |
| nanorom.mem | a1f291b6397c7907b64141429434aabda9a0d7dc |

## Local changes

- `fx68k.sv`: the two `$readmemb` paths are relative to the project root
  (`rtl/cpu/fx68k/microrom.mem`, `nanorom.mem`), where both Quartus (the
  `build/` worktree) and `scripts/run_sim.sh` run. Line endings LF.
