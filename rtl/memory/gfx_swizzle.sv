// Sprite ROM word-address permutation, applied at download. MAME's gfx1
// (RGN_FRAC(1,2) 4bpp) keeps a tile row's four 16-bit words in four places;
// permuted, a row is one 64-bit SDRAM granule addressed by {tile, yh, yl}.
//
//   source word {h, tile, yh, xh, yl}  ->  dest word {tile, yh, yl, h, xh}
//
// The bit-plane bit stays the low byte bit, so bytes pair into words as
// before. The region must be a power of two; half_words = region bytes / 4.

`default_nettype none

module gfx_swizzle #(
	parameter int AW = 23              // 8 MB region
) (
	input  wire [AW-1:0] half_words,   // region bytes / 4
	input  wire [AW-1:0] word_in,
	output wire [AW-1:0] word_out
);

	wire          h = (word_in >= half_words);
	wire [AW-1:0] w = h ? (word_in - half_words) : word_in;

	//        w = { tile , yh , xh , yl }        bits [AW-1:5],[4],[3],[2:0]
	// word_out = { tile , yh , yl , h , xh }     (w's top bit is always zero)
	assign word_out = { w[AW-2:5], w[4], w[2:0], h, w[3] };

endmodule

`default_nettype wire
