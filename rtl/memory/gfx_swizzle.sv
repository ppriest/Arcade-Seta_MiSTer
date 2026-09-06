// Sprite graphics layout: turn MAME's "gfx1" region into one 64-bit SDRAM
// granule per sprite ROW, by permuting WORD ADDRESSES at download time.
//
// WHY
//   layout_sprites is RGN_FRAC(1,2) 4bpp. In MAME's region a 16-pixel row of a
//   tile is four 16-bit words, and they sit 16 bytes apart (the two 8-pixel
//   halves of the row) and half a region apart (the two bit-plane pairs). Four
//   addresses, four different 64-bit granules, four SDRAM round trips -- which
//   measured as ~56 of the ~90 clk_sys cycles a sprite costs, and capped the
//   engine at 68 sprites per scanline against the 512 the chip walks.
//
//   Permuted, a row is eight CONTIGUOUS, 8-byte-aligned bytes: one granule, one
//   round trip. The engine's whole address calculation collapses to
//   {tile, yh, yl} -- see rtl/video/x1_001.sv.
//
// THE PERMUTATION IS PURE, AND ENTIRELY ABOVE BYTE GRANULARITY
//   Source byte  = h*(S/2) + tile*64 + yh*32 + xh*16 + yl*2 + p
//   Dest   byte  =           tile*128 + yh*64 + yl*8 + h*4 + xh*2 + p
//
//   The plane bit p is the LOW BIT OF BOTH, so nothing below a 16-bit word
//   moves. That is what makes this cheap enough to do in the download path:
//   sdram_download.sv pairs ioctl bytes into words and writes them, and only
//   the address it writes them to changes. No byte shuffling, no re-pairing,
//   no second buffer.
//
//   In word terms, source {h, tile, yh, xh, yl} becomes {tile, yh, yl, h, xh}.
//
// ASSUMES A POWER-OF-TWO REGION, which every in-scope "gfx1" is (0x80000
// through 0x800000, checked by scripts/build_region.py against each
// ROM_REGION). `half_words` is the region size in bytes divided by four, i.e.
// the number of 16-bit words in one RGN_FRAC half.
//
// This is NOT verified by inspection: sim/x1_001_tb instantiates this module,
// pushes the natural region through it word by word, and then requires the
// engine reading the result to produce the same pixels as
// scripts/x1_001_model.py reading the natural region. A wrong permutation
// shows up as wrong artwork, not as a silent success.

`default_nettype none

module gfx_swizzle #(
	// 23 bits of word index covers an 8 MB region (gundhara's, the largest in
	// seta.cpp) with a bit to spare.
	parameter int AW = 23
) (
	input  wire [AW-1:0] half_words,   // region bytes / 4
	input  wire [AW-1:0] word_in,
	output wire [AW-1:0] word_out
);

	// Which RGN_FRAC half, and the offset inside it.
	wire          h = (word_in >= half_words);
	wire [AW-1:0] w = h ? (word_in - half_words) : word_in;

	//        w = { tile , yh , xh , yl }        bits [AW-1:5],[4],[3],[2:0]
	// word_out = { tile , yh , yl , h , xh }
	//
	// w's top bit is always zero (w < half_words <= 2^(AW-1)), so dropping it
	// keeps the result AW bits wide without losing anything.
	assign word_out = { w[AW-2:5], w[4], w[2:0], h, w[3] };

endmodule

`default_nettype wire
