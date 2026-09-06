# Shared simulation models

## `sdram_chip_model_wide.sv`

Vendored from `Arcade-Fuuki_MiSTer/sim/sdram_tb/`, unmodified. Originally a
widened copy of Psikyo's `sdram_chip_model.sv`.

It decodes real SDRAM commands from `{nRAS, nCAS, nWE}` and models CAS latency
and burst behaviour, rather than being a latency stub. That distinction is
load-bearing: LESSONS_LEARNED's "Verify a burst extension against a
command-decoding chip model, not a latency stub" records three bugs caught only
because the model decoded commands — a row/column address split that had to be
swapped, a chip model silently ignoring the `DQML`/`DQMH` write mask, and an
off-by-one in burst-read CAS timing.

**Use the *wide* copy.** The narrower original folds row addresses to 8 bits,
which makes regions whose base addresses share `word_addr[16:9]` alias onto the
same cells. On Fuuki that silently corrupted a downloaded program and left the
rest as never-written X, and the resulting flood of TG68K "X in arithmetic
operand" warnings was mistaken for a CPU bug. This copy uses the real 13-bit row
width, matching `rtl/memory/sdram/sdram.sv`'s own `row = a[22:10]` split.
