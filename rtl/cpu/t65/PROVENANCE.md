# T65 provenance

Downloaded unmodified from
https://github.com/MiSTer-devel/Arcade-Centipede_MiSTer, `rtl/T65/`, at commit
`5be58ec303b09659a827020bfcb8c8bff8ceaf33` (the latest touching that path when
fetched). T65 "Ver 315" (SzGy, April 2020), after Daniel Wallner, MikeJ,
Wolfgang Scherr and Morten Leikvoll. BSD-style licence, in the header of each
file.

| file | lines | sha1 |
|-|-|-|
| T65.vhd | 701 | 2c672c6a9de73cabf984da9fb9ae9fa8da565358 |
| T65_ALU.vhd | 293 | 8781d79b24a1bb1013329bf2e220413807288511 |
| T65_MCode.vhd | 1265 | b75afbda2ca46c0864633606026bd944823440ed |
| T65_Pack.vhd | 179 | 971de8910961f3cd642ebdb6a8d01d361fb51c93 |
| t65.qip | 4 | 9e8eb5f911e41e5e68ade44fa3918ba163d25836 |

Used for the 65C02 sub CPU on the downtown.cpp boards (Seta_Downtown). Its own
header: "65C02 and 65C816 modes are incomplete ... 65C02 supported: inc, dec,
phx, plx, phy, ply"; missing bra, (zp) forms of ora/lda/cmp/sbc, tsb, trb,
stz, bit variants, wai, stp, jmp (abs,x), bbr, bbs. Which of those each game's
sub program executes is measured with `scripts/mame_subtrace.py`.

## Local changes (Seta_Downtown)

All gated on 65C02 mode (`Mode /= "00"`); 6502 mode decodes exactly as
upstream.

- **Added:** STZ zp/zp,x/abs/abs,x; ORA AND EOR ADC STA LDA CMP SBC (zp);
  JMP (abs,x); BRA; BIT #imm/zp,x/abs,x; TSB/TRB zp/abs; D cleared on
  BRK/IRQ/NMI. `T65_MCode.vhd` (an override block after the upstream decode,
  and the ALU operation for each), `T65_ALU.vhd` (TSB, TRB, BIT #imm: Z only),
  `T65_Pack.vhd` (`Write_Data_ZERO`, three ALU ops), `T65.vhd` (the zero write
  source, D clear).
- **Fixed:** INC A / DEC A put S through the ALU instead of A; PLX / PLY
  loaded X/Y through ROR/INC instead of passing the pulled byte.
- **Not added:** Rockwell BBR/BBS/RMB/SMB, WAI, STP, and 65C02 NOP decoding of
  the undefined opcodes. JMP (abs,x) does not carry into the high byte when
  the table entry's low byte is at $xxFF.
- **Checked by** `sim/t65c02_tb` (ModelSim): a program built by
  `make_prog.py` exercising each added and fixed instruction, 27 memory
  results and 21 cycle counts against the WDC W65C02S datasheet. Not yet
  checked against a game's program in MAME.

Executed in 60 s of each game's attract (`scripts/mame_subtrace.py`), all
covered by the changes above:

| set | 65C02-only instructions |
|-|-|
| downtown | STZ zp/zp,x/abs/abs,x, STA/CMP (zp), INC/DEC A, PHX/PHY/PLX/PLY |
| arbalest, metafox | STZ abs/abs,x, STA/CMP (zp), PHX/PHY/PLX/PLY |
| twineagl | STZ zp,x/abs/abs,x, STA/CMP (zp), PHX/PHY/PLX/PLY |
| calibr50 | STZ (all four), STA/LDA (zp), BRA, JMP (abs,x), INC/DEC A, PHX/PHY/PLX/PLY |
| usclssic | STZ zp/zp,x, INC/DEC A |
| tndrcade | STZ (all four), STA/LDA/CMP (zp), BRA, BIT zp,x, INC A, PHX/PHY/PLX/PLY |
