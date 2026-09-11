// Palette address formation for the 6bpp tile layers.
//
// WHAT THIS IS, AND WHY IT IS A MODULE RATHER THAN THREE LINES IN THE MIXER
//
// MAME expresses it as a palette COLORTABLE -- set_pen_indirect() filled in by
// gundhara_palette(), jjsquawk_palette() and zingzip_palette() -- because a
// lookup table is the cheap way to say it in software. Read what the table
// actually contains and it is not a lookup at all:
//
//     0x400 + ((((color & ~3) << 4) + pen) & 0x1ff)     gundhara, zingzip
//     0x400 + (((color        << 4) + pen) & 0x1ff)     jjsquawk, madshark
//
// That is a NINE-BIT ADDER WITH WRAPAROUND, a mask that drops the colour
// code's low two bits, and a bank base. Adder, not concatenation: a colour
// code of 0x1f with a pen of 0x3f carries out of bit 8 and wraps to the bottom
// of the bank, and the 4bpp path's `base + color*16 + pen` cannot express
// that. It is board wiring -- on the way from the X1-011's layer output to the
// X1-006's palette RAM -- so it gets a block of its own, instantiated per
// layer and passed through where a game does not have it.
//
// THE TWO FAMILIES DIFFER BY TWO CHARACTERS. `color & ~3` against `color`.
// seta.cpp's own comments call gundhara's "only 4 different palettes" and
// jjsquawk's "16 colors granularity"; docs/ROADMAP.md flags the pair as the
// kind of detail that reads as a typo and is not.
//
// COLOUR MODE DOES NOT REACH HERE. vctrl[2] bit 4 picks the layer's second
// GFXDECODE entry, which differs from the first only in its palette base --
// and both bases map to the SAME destination through the table (0x0200 and
// 0x1200 both to 0x400; 0x0a00 and 0x1a00 both to 0x200). So the mode bit
// cannot change the entry, and the engine feeds {color, pen} with no base at
// all for a 6bpp layer.
//
// MODE_DIRECT is the whole of Groups A, B and C: MAME leaves their colortable
// at its default, which dipalette.cpp fills as `pen % indirect_colors` -- an
// identity map. The index passes through untouched and the block folds away.

`default_nettype none

package seta_pal_pkg;
	typedef enum logic [1:0] {
		PAL_DIRECT   = 2'd0,   // 4bpp: the index IS the entry
		PAL_MASKED   = 2'd1,   // gundhara, zingzip:  (color & ~3) << 4
		PAL_PLAIN    = 2'd2    // jjsquawk, madshark:  color << 4
	} pal_mode_t;
endpackage

import seta_pal_pkg::*;

module x1_011_index #(
	parameter int LB_W = 11
) (
	input  wire  [1:0]      mode,
	// The 512-entry bank the layer lands in: 0x200 or 0x400.
	input  wire [LB_W-1:0]  bank,
	// From the tile engine. For a 6bpp layer this is {color[4:0], pen[5:0]}
	// with no palette base added, which is why LB_W of 11 fits it exactly.
	input  wire [LB_W-1:0]  idx,
	output wire [LB_W-1:0]  entry
);

	wire [4:0] color = idx[10:6];
	wire [5:0] pen   = idx[5:0];

	// (color & mask) << 4, in nine bits so the add can carry out of bit 8 and
	// be dropped -- which is what & 0x1ff does.
	wire [4:0] cmasked = (mode == PAL_MASKED) ? (color & 5'b11100) : color;
	wire [8:0] sum     = {cmasked, 4'd0} + {3'd0, pen};

	assign entry = (mode == PAL_DIRECT) ? idx : (bank + {2'd0, sum});

endmodule

`default_nettype wire
