// Palette address of a 6bpp tile-layer pixel. MAME's colortables
// (gundhara_palette, jjsquawk_palette, zingzip_palette, blandia_palette)
// reduce to arithmetic:
//
//     0x400 + ((((color & ~3) << 4) + pen) & 0x1ff)     PAL_MASKED
//     0x400 + (((color        << 4) + pen) & 0x1ff)     PAL_PLAIN
//     bank  + ((color << 4) | (pen & 0x0f))             PAL_BLAND0 (blandia mode 0)
//     bank  + pen                                       PAL_BLAND1 (blandia mode 1)
//
// MASKED and PLAIN are a 9-bit add that wraps. PAL_DIRECT (all 4bpp sets)
// passes the index through.

`default_nettype none

import seta_pal_pkg::*;

module x1_011_index #(
	parameter int LB_W = 11
) (
	input  wire  [2:0]      mode,
	input  wire [LB_W-1:0]  bank,      // 0x200 or 0x400
	input  wire [LB_W-1:0]  idx,       // 6bpp: {color[4:0], pen[5:0]}
	output wire [LB_W-1:0]  entry
);

	wire [4:0] color = idx[10:6];
	wire [5:0] pen   = idx[5:0];

	wire [4:0] cmasked = (mode == PAL_MASKED) ? (color & 5'b11100) : color;
	wire [8:0] sum     = {cmasked, 4'd0} + {3'd0, pen};

	wire [8:0] bland = (mode == PAL_BLAND1) ? {3'd0, pen} : {color, pen[3:0]};

	wire [8:0] off = (mode == PAL_BLAND0 || mode == PAL_BLAND1) ? bland : sum;

	assign entry = (mode == PAL_DIRECT) ? idx : (bank + {2'd0, off});

endmodule

`default_nettype wire
