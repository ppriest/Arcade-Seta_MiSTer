// The palette-mode enum, in a file of its own.
//
// scripts/run_sim.sh compiles `find rtl -name '*.sv' | sort`, so a package has
// to sort before every file that imports it. It lived in x1_011_index.sv until
// seta_video.sv needed it too, and "x1_011_index" sorts after "seta_video".
// Splitting it out is the fix that does not depend on remembering that.

`default_nettype none

package seta_pal_pkg;
	typedef enum logic [2:0] {
		PAL_DIRECT   = 3'd0,   // 4bpp: the index IS the entry
		PAL_MASKED   = 3'd1,   // gundhara, zingzip:  (color & ~3) << 4
		PAL_PLAIN    = 3'd2,   // jjsquawk, madshark:  color << 4
		PAL_BLAND0   = 3'd3,   // blandia mode 0:  (color << 4) | (pen & 0x0f)
		PAL_BLAND1   = 3'd4    // blandia mode 1:  pen alone
	} pal_mode_t;
endpackage

`default_nettype wire
