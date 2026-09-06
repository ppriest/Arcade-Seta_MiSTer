# `sdram.sv` — provenance and modifications

## Chain of custody

| Stage | What |
|---|---|
| Upstream | Sorgelig's `sdram.v`, GPL-3.0-or-later, taken from `MiSTer-devel/Arcade-Jackal_MiSTer/rtl/ram_rom/sdram.sv`. Kept verbatim beside it as `sdram_upstream_reference.sv` for diffing. |
| Then | `Arcade-Psikyo_MiSTer/rtl/memory/sdram/` — extended to burst-4 reads and proved on real DE10-nano hardware. |
| Then | `Arcade-Fuuki_MiSTer/rtl/memory/sdram/` — carried across, with the surrounding stack widened to 26-bit addresses for a 128 MB module. |
| Here | Copied from that Fuuki tree **untouched**. Do not edit. |

The rest of the stack beside it (`sdram_phy.sv`, `sdram_arbiter.sv`,
`sdram_download.sv`, `sdram_narrow_bridge.sv`, `rom_loader.sv`, `ddram_phy.sv`)
came from the same Fuuki tree in the same copy, also unmodified. Fuuki's is the
more evolved of the two: one parameterised `sdram_arbiter.sv` in place of
Psikyo's `sdram_arbiter2/5/6` trio, and 26-bit addressing throughout. Seta's
largest set is 15.5 MB so it fits the stock 32 MB part comfortably; the wider
address costs nothing and avoids a widening pass later — Fuuki records that one
as having silently shifted two tilemap layers because an arbiter packed its
client addresses as `[25*N-1:0]` arithmetic rather than a named range.

This controller, or a close variant, is vendored into dozens of MiSTer-devel arcade cores. It is a
proven, widely deployed reference rather than a one-off — the same posture this project takes with
TG68K.C and the jotego sound cores.

Targets the MiSTer SDRAM add-on board: an `MT48LC16M16` (16-bit data bus, 2 banks x 13-bit row x
9-bit column, 24-bit word address = **32 MB**), reached through the DE10-nano's `SDRAM_*` pins.
Three independent client ports, **fixed priority port0 -> port1 -> port2** when more than one is
idle-ready — not round-robin, which matters when deciding what to put behind each one.

## Why it is not upstream-verbatim

Every graphics consumer in this project speaks in 64-bit granules — one packed row of a 4bpp
16-pixel tile. Upstream's read state machine captures exactly **one** 16-bit word per transaction
regardless of the mode register's burst-length field, so a 64-bit granule would cost four separate
transactions (~28 cycles uncontended). Psikyo extended it to a real burst-4 read; that extension is
what this project depends on.

Three bugs were found while building that extension, and they are worth knowing because they are
invisible without a chip model that decodes commands:

- The row/column address split needed swapping. A hardware burst auto-increments the **column**, so
  four consecutive word addresses must land in four consecutive columns of one row. The
  non-bursting upstream had it the other way, which only matters once bursting exists.
- The chip model silently ignored the `DQML`/`DQMH` write mask.
- An off-by-one in burst-read CAS timing, from a dropped registration-delay margin.

LESSONS_LEARNED, "Verify a burst extension against a command-decoding chip model, not a latency
stub".

## The 32 MB ceiling, and FG-3

`addr0`/`addr1`/`addr2` were `[24:1]` upstream — 24 bits of **word** address, i.e. exactly 32 MB; this copy widens them to `[25:1]` and drives bit 25 onto A9 at column time, the 64 MB layout of the 128 MB module's first chip (FG-3 needs 56.5 MB). That was
enough for either FG-2 game and **not** enough for either FG-3 game:

| Game | Footprint |
|---|---|
| pbancho | 9.4 MB |
| gogomile | 16.1 MB |
| asurabld | 48.5 MB |
| asurabus | 56.5 MB |

Widening this controller for a 64 MB or 128 MB module means extending the address path and the
row/bank/column split, and it is the open decision recorded in `docs/ROADMAP.md`. Nothing in the
FG-2 bring-up depends on it.

## Facts worth not rediscovering

- **Upstream has no reset port at all** — it is driven purely by `init`, deliberately, so that a
  core reset cannot disturb memory contents. Do not add one. Psikyo's wrapper did, and it pinned
  the download FSM in idle for the entire ROM transfer, because MiSTer holds core `RESET` asserted
  for the whole download (LESSONS_LEARNED, "Never hold the memory path in the core reset").
- **`dout0`/`dout1`/`dout2` are literally the same register.** Sampling later than your own
  valid/ack cycle reads another port's in-flight data. Capture read data on the valid pulse.
- **The three ports are fixed priority, not fair.** Port 0 always preempts port 1, which always
  preempts port 2. Choosing which client sits behind which port is the only bandwidth tuning
  available; there is one physical chip, so "more ports" is not more parallel bandwidth.
- **`SDRAM_CLK` phase shift** is the standard MiSTer `-3 ns` convention, expressed as a positive
  equivalent because `altera_pll` rejects negative values here. It is a poor first suspect for data
  faults; sweeping it to 0 ps on Psikyo gave byte-identical results.
- The uninitialized `state`/`ack0..2` signals get explicit initializers, the same
  simulation-fidelity class of fix as the TG68K one.
