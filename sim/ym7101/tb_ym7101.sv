// ym7101 A/B equivalence bench: die model `ym7101` (rtl/nuked-md/ym7101.v, the Mega Drive VDP)
// against the 1:1 synthesis-friendly `ym7101_rtl` (rtl/nuked-md/ym7101_rtl.v).  Identical
// stimulus into both; every output port and every storage element (converted primitive v1/v2/mem,
// kept helper l1/l2 and q/nq, and the verbatim procedural scalar regs) compared twice per MCLK:
//   - at posedge MCLK, before the non-blocking updates land (the values the flops sample)
//   - a quarter period after posedge (the values produced by that edge, same inputs)
// Stimulus is applied at negedge MCLK so the phase-generation and bus resolution settle first.
// First mismatch prints cycle/signal/values and stops with FAIL.
//
// Board model around the VDP (sim support, not the DUT): MCLK 107.386 MHz, MCLK_e = MCLK/2, an
// EDCLK_i divider (the H40 dot clock), CLK1_i fed back from the die's CLK1_o, one behavioural VRAM
// (vram_model) on the AD DRAM bus wired as md_board's default 64K config, and a 68000 that
// programs the VDP registers and fills VRAM/CRAM/VSRAM, runs H32 then H40 frames, and issues a
// VRAM-fill DMA and a 68k->VRAM DMA, plus constrained-random port/register writes.  All VDP-driven
// bus values are taken from the die model and fed identically to both DUTs (both are compared to
// be identical anyway), exactly as the ym6045 bench does.
`timescale 1ps/1ps
module tb_ym7101;

	// ---------------- clock ----------------
	reg MCLK = 0;
	always #4656 MCLK = ~MCLK;              // 9.312 ns, MCLK2

	// inputs the TB drives specially (declared before the DUT instances)
	wire        CLK1_i;
	wire [7:0]  SD;
	wire [7:0]  RD_i;
	wire [7:0]  AD_i;

	// comparator macro (used by the generated report tasks).  A difference is a MISMATCH only where
	// the DIE value is KNOWN (not x): the die's `mem<=en?inp:mem` mux goes x on an unknown enable,
	// while the 1:1 `if(en) mem<=inp` form holds -- identical in real 2-state hardware, so a die-x
	// bit is genuinely indeterminate and masked.  A known die bit that differs (including rtl=x
	// where die is defined) is always a real mismatch and is reported.
	integer cycle = 0, ncmp = 0, nmis = 0, nwarn = 0;
	string  phase;
	reg     xcheck_en = 0;
`define CMP(NAME, A, B) \
	if ((A) !== (B) && !$isunknown(A)) begin \
		$display("MISMATCH cycle %0d t=%0t (%s) %s: die=%h rtl=%h", cycle, $time, phase, NAME, A, B); \
		nmis = nmis + 1; \
	end

	// input decls + output _a/_b pairs + u_die/u_rtl instances + outs_a/outs_b + report_outputs()
	// packed storage vectors sto_a/sto_b + report_storage()
	// STAGE 1 (default): u_rtl = ym7101_rtl, full storage compare.
	// STAGE 2 (+define+OPT_BENCH): u_rtl = ym7101_opt, OUTPUTS-only compare (collapsed storage
	// does not map 1:1, so sto is stubbed and check_mem is skipped).
`ifdef OPT_BENCH
	`include "ports_opt.svh"
	`include "cmp_opt.svh"
`else
	`include "ports_gen.svh"
	`include "cmp_gen.svh"
`endif

	// die-x-masked difference detector over {all outputs, all storage}, evaluated event-driven
	localparam int OUT_W = $bits(outs_a);
	localparam int ALLW  = OUT_W + STO_W;
	wire [ALLW-1:0] all_a = {outs_a, sto_a};
	wire [ALLW-1:0] all_b = {outs_b, sto_b};
	wire [ALLW-1:0] badbit;
	genvar gi;
	generate for (gi = 0; gi < ALLW; gi = gi + 1) begin : bc
		assign badbit[gi] = (all_a[gi] !== 1'bx) && (all_a[gi] !== all_b[gi]);
	end endgenerate
	wire any_bad = |badbit;

	// ---------------- MCLK_e and EDCLK_i (board clocks) ----------------
	// EDCLK_i is the VDP's external dot clock.  Both H32 and H40 are programmed with RS0=1 so the
	// pixel path is clocked from EDCLK_i in both, which lets the bench reach real frame boundaries
	// (VSYNC) in a feasible number of MCLK cycles.  This is a bench-stimulus choice only: the H32
	// vs H40 width, the H/V counters, HSYNC/VSYNC/DE and the full pixel/serial pipeline still differ
	// per mode and are exercised; die/rtl equivalence does not depend on the dot-clock source.
	// Period 8 (4 high / 4 low) is the fastest that still produces clean clk1/clk2 through the 4-tap
	// dclk delay (clk1 = ~mclk_dclk & dclk_l, dclk_l = mclk_dclk delayed 4 MCLK).
	integer edph = 0;
	always @(negedge MCLK) begin
		MCLK_e <= ~MCLK_e;                              // md_board: MCLK_e <= ~MCLK_e each MCLK2
		edph = (edph == 7) ? 0 : edph + 1;
		EDCLK_i <= (edph < 4);                          // MCLK2/8 dot clock
	end
	assign CLK1_i = CLK1_o_a;                           // 68000 clock fed back from the die

	// ---------------- VRAM (md_board default 64K: one chip on the AD bus) ----------------
	wire [7:0] vram1_AD_o, vram1_SD_o;
	wire       vram1_AD_d, vram1_SD_d;
	reg  [7:0] AD_mem = 0, RD_mem = 0, SD_mem = 0;
	wire [7:0] AD = (~AD_d_a ? AD_o_a : 8'h0) | (~vram1_AD_d ? vram1_AD_o : 8'h0)
	              | ((AD_d_a & vram1_AD_d) ? AD_mem : 8'h0);
	assign RD_i = (~RD_d_a ? RD_o_a : RD_mem);
	assign AD_i = AD;
	assign SD   = vram1_SD_d ? SD_mem : vram1_SD_o;
	always @(posedge MCLK) begin AD_mem <= AD; RD_mem <= RD_i; SD_mem <= SD; end

	vram_model vram1 (
		.MCLK(MCLK), .RAS(RAS1_a), .CAS(CAS1_a), .WE(WE0_a), .OE(OE1_a),
		.SC(SC_a), .SE(SE0_a), .AD(AD), .RD_i(AD),
		.RD_o(vram1_AD_o), .RD_d(vram1_AD_d), .SD_o(vram1_SD_o), .SD_d(vram1_SD_d));

	// ---------------- comparator ----------------
	task automatic report(input string ph);
		phase = ph;
		report_outputs(ph);
		report_storage(ph);
	endtask

	task automatic check(input string ph);
		phase = ph;
		ncmp = ncmp + 1;
		if (any_bad) begin
			report(ph);
			if (nmis == 0) begin
				$display("MISMATCH cycle %0d (%s): masked diff set but no known-die field reported", cycle, ph);
				nmis = 1;
			end
		end
		if (nmis != 0) begin
			$display("FAIL after %0d cycles (%0d compare points): %0d mismatch(es)", cycle, ncmp, nmis);
			$finish;
		end
	endtask

	always @(posedge MCLK) begin check("pre-edge"); cycle = cycle + 1; end
	always @(posedge MCLK) begin #2328; check("post-edge"); end

	// periodic full compare of the verbatim memory arrays (they are copied byte-identical, so this
	// only guards against an accidental edit; done sparsely to keep the run fast)
	integer mi;
	task automatic check_mem();
`ifdef OPT_BENCH
		return;   // opt bench compares outputs only
`endif
		for (mi = 0; mi < 40; mi = mi + 1) begin
			`CMP($sformatf("vsram[%0d]", mi),     u_die.vsram[mi],     u_rtl.vsram[mi])
			`CMP($sformatf("linebuffer[%0d]",mi), u_die.linebuffer[mi],u_rtl.linebuffer[mi])
		end
		for (mi = 0; mi < 80; mi = mi + 1) `CMP($sformatf("sat[%0d]", mi), u_die.sat[mi], u_rtl.sat[mi])
		for (mi = 0; mi < 20; mi = mi + 1) `CMP($sformatf("sprdata[%0d]", mi), u_die.sprdata[mi], u_rtl.sprdata[mi])
		for (mi = 0; mi < 64; mi = mi + 1) `CMP($sformatf("color_ram[%0d]", mi), u_die.color_ram[mi], u_rtl.color_ram[mi])
		if (nmis != 0) begin $display("FAIL (memory) after %0d cycles", cycle); $finish; end
	endtask

	// ---------------- helpers: negedge-synchronised tick ----------------
	task automatic tick(input integer n); repeat (n) @(negedge MCLK); endtask

	// ---------------- 68000 access to the VDP (SEL0=1, word unless byte flagged) ----------------
	localparam [22:0] CTRL = 23'h600002;   // C00004
	localparam [22:0] DATA = 23'h600000;   // C00000
	integer HOLD = 60;                      // MCLK cycles to hold strobes (>= a few cpu_clk0 = mclk_clk5)

	task automatic bus_word(input [22:0] ca, input bit rw, input [15:0] d);
		tick(2); CA_i = ca; RW = rw;
		tick(1); if (!rw) CD_i = d;
		AS = 0; UDS = 0; LDS = 0;
		tick(HOLD);
		AS = 1; UDS = 1; LDS = 1; RW = 1;
		tick(6);
	endtask
	task automatic ctrl_wr(input [15:0] d); bus_word(CTRL, 0, d); endtask
	task automatic data_wr(input [15:0] d); bus_word(DATA, 0, d); endtask
	task automatic data_rd();               bus_word(DATA, 1, 16'h0); endtask
	task automatic ctrl_rd();               bus_word(CTRL, 1, 16'h0); endtask

	task automatic setreg(input [4:0] r, input [7:0] v); ctrl_wr({3'b100, r, v}); endtask
	// set the address + access code (CD5..CD0) for the next data-port transfers
	task automatic setaddr(input [5:0] code, input [15:0] a);
		ctrl_wr({code[1:0], a[13:0]});
		ctrl_wr({8'h0, code[5:2], 2'h0, a[15:14]});
	endtask
	localparam [5:0] CD_VRD=6'h00, CD_VWR=6'h01, CD_CWR=6'h03, CD_SRD=6'h04, CD_SWR=6'h05, CD_CRD=6'h08;

	// ---------------- register programming ----------------
	task automatic program_regs(input bit h40, input bit v30);
		setreg(5'h00, 8'h04);                          // mode1: no HINT, no HV-latch
		setreg(5'h01, v30 ? 8'h4C : 8'h44);            // mode2: DISP on, M5, (M2 for 30 lines)
		setreg(5'h02, 8'h30);                          // plane A nametable = 0xC000
		setreg(5'h03, 8'h3C);                          // window nametable
		setreg(5'h04, 8'h07);                          // plane B nametable = 0xE000
		setreg(5'h05, 8'h7E);                          // sprite attribute table = 0xFC00
		setreg(5'h07, 8'h00);                          // background colour
		setreg(5'h0A, 8'hFF);                          // HINT counter
		setreg(5'h0B, 8'h00);                          // mode3
		setreg(5'h0C, h40 ? 8'h81 : 8'h01);            // mode4: RS0 (EDCLK dot clock); RS1 adds H40 width
		setreg(5'h0D, 8'h37);                          // hscroll table = 0xDC00
		setreg(5'h0F, 8'h02);                          // autoinc = 2
		setreg(5'h10, 8'h01);                          // plane size 64x32
		setreg(5'h11, 8'h00);                          // window H
		setreg(5'h12, 8'h00);                          // window V
	endtask

	// ---------------- memory fills ----------------
	task automatic fill_vram(input [15:0] base, input integer n);
		integer k; setaddr(CD_VWR, base);
		for (k = 0; k < n; k = k + 1) data_wr(16'(base) ^ 16'(k*16'h1111) ^ 16'hA5A5);
	endtask
	task automatic fill_cram(input integer n);
		integer k; setaddr(CD_CWR, 16'h0000);
		for (k = 0; k < n; k = k + 1) data_wr(16'((k*7) & 16'h0EEE));
	endtask
	task automatic fill_vsram(input integer n);
		integer k; setaddr(CD_SWR, 16'h0000);
		for (k = 0; k < n; k = k + 1) data_wr(16'((k*3) & 16'h03FF));
	endtask

	// ---------------- DMA ----------------
	// VRAM fill DMA (reg 0x17 bit7=1, bit6=0): set length, then a data-port write starts the fill
	task automatic dma_vram_fill(input [15:0] dst, input [15:0] len, input [7:0] fillbyte);
		setreg(5'h13, len[7:0]); setreg(5'h14, len[15:8]);
		setreg(5'h17, 8'h80);                          // DMA mode = VRAM fill
		setaddr(CD_VWR | 6'h20, dst);                  // CD5=1 (DMA)
		data_wr({fillbyte, fillbyte});                 // fill value
		tick(400);
	endtask
	// 68k->VRAM DMA (reg 0x17 bit7=0): the 68k releases the bus (BG/BGACK), the VDP runs the copy
	task automatic dma_68k_vram(input [15:0] dst, input [22:0] src, input [15:0] len);
		setreg(5'h13, len[7:0]); setreg(5'h14, len[15:8]);
		setreg(5'h15, src[8:1]); setreg(5'h16, src[16:9]); setreg(5'h17, {1'h0, src[22:17]});
		BG = 0;                                         // grant the bus (VDP is master for the copy)
		setaddr(CD_VWR | 6'h20, dst);
		ctrl_wr(16'h0);                                // second control word can retrigger; harmless
		tick(600);
		BG = 1;
	endtask

	// ---------------- run VDP frames (advance until N VSYNC edges seen) ----------------
	integer n_vsync = 0, n_hsync = 0, n_de = 0, last_vs = 0;
	always @(negedge VSYNC_a) begin
		n_vsync = n_vsync + 1;
		$display("INFO cycle %0d: VSYNC #%0d (period %0d MCLK, hsync=%0d de=%0d)", cycle, n_vsync, cycle-last_vs, n_hsync, n_de);
		last_vs = cycle;
	end
	always @(negedge HSYNC_pull_a) n_hsync = n_hsync + 1;
	always @(posedge vdp_de_h_a) n_de = n_de + 1;

	task automatic run_frames(input integer frames);
		integer target; target = n_vsync + frames;
		while (n_vsync < target && cycle < 40000000) tick(200);
	endtask

	// Bounded active-display run: advance a fixed number of MCLK while the framed pixel/serial
	// pipeline is live.  A full 262-line NTSC frame is ~880k MCLK (measured HSYNC line period
	// ~3360 MCLK, so VSYNC#2 lands near cycle ~850k); two full VSYNC frames per mode is ~3.5M
	// MCLK, ~18x the ~200k-MCLK/seed budget the task sets ("do NOT run millions").  So instead of
	// waiting for whole vertical frames we advance a budgeted number of MCLK, which exercises many
	// active-display lines (HSYNC, DE_H/DE_V, the full pixel+colour+sprite+linebuffer pipeline) in
	// each of H32 and H40 -- every converted storage element on the dclk/hclk/clk1/clk2 phases --
	// plus the DMA and random-write phases, all within budget.  FCYC (plusarg) sets the per-mode
	// active-run length; the compare still runs on every MCLK.
	task automatic run_active(input integer ncyc);
		integer tgt; tgt = cycle + ncyc;
		while (cycle < tgt) tick(200);
	endtask

	// ---------------- constrained-random port/register traffic ----------------
	integer seed;
	task automatic random_access();
		integer cls; cls = $urandom_range(0, 99);
		if (cls < 30)      setreg($urandom_range(0,23), 8'($urandom));
		else if (cls < 55) begin setaddr(6'($urandom_range(0,63)), 16'($urandom)); data_wr(16'($urandom)); end
		else if (cls < 70) begin setaddr(CD_VWR, 16'($urandom)); data_wr(16'($urandom)); data_wr(16'($urandom)); end
		else if (cls < 80) data_rd();
		else if (cls < 88) ctrl_rd();
		else if (cls < 94) begin setaddr(CD_CWR, 16'($urandom)); data_wr(16'($urandom)); end
		else               begin setaddr(CD_SWR, 16'($urandom)); data_wr(16'($urandom)); end
	endtask

	// ---------------- main ----------------
	integer nrand, k, fcyc;
	initial begin
		if (!$value$plusargs("SEED=%d", seed)) seed = 1;
		if (!$value$plusargs("NRAND=%d", nrand)) nrand = 200;
		if (!$value$plusargs("FCYC=%d", fcyc)) fcyc = 60000;
		void'($urandom(seed));
		$display("tb_ym7101: seed=%0d nrand=%0d fcyc=%0d", seed, nrand, fcyc);

		// idle levels
		SPA_B_i=1; CSYNC_i=1; HSYNC_i=1; HL=1; SEL0=1; PAL=0; ext_test_2=0; vdp_cramdot_dis=0;
		BGACK_i=1; BG=1; MREQ=1; INTAK=1; IORQ=1; RD=1; WR=1; M1=1;
		AS=1; UDS=1; LDS=1; RW=1; DTACK_i=1; CD_i=0; CA_i=0;

		// power-on: RESET (reset_comb) asserted, clocks running
		RESET = 0; tick(600);
		RESET = 1; tick(400);
		xcheck_en = 1;
		tick(2000);

		// ---- H32 setup ----
		program_regs(.h40(0), .v30(0));
		fill_cram(64); fill_vsram(40);
		fill_vram(16'hC000, 64);      // plane A tiles
		fill_vram(16'hE000, 64);      // plane B tiles
		fill_vram(16'hFC00, 40);      // sprite table
		fill_vram(16'h0000, 128);     // pattern data
		fill_vram(16'hDC00, 32);      // hscroll
		$display("INFO cycle %0d: H32 programmed (vsync=%0d hsync=%0d de=%0d)", cycle, n_vsync, n_hsync, n_de);
		run_active(fcyc);
		check_mem();
		$display("INFO cycle %0d: H32 active-display run done (vsync=%0d hsync=%0d de=%0d)", cycle, n_vsync, n_hsync, n_de);

		// ---- DMA activity ----
		dma_vram_fill(16'h4000, 16'h0040, 8'h3C);
		dma_68k_vram(16'h5000, 23'h010000, 16'h0030);
		$display("INFO cycle %0d: DMA done", cycle);

		// ---- H40 setup ----
		program_regs(.h40(1), .v30(1));
		fill_vram(16'hC000, 64);
		fill_vram(16'h1000, 128);
		$display("INFO cycle %0d: H40 programmed", cycle);
		run_active(fcyc);
		check_mem();
		$display("INFO cycle %0d: H40 active-display run done (vsync=%0d hsync=%0d de=%0d)", cycle, n_vsync, n_hsync, n_de);

		// ---- constrained random between frames ----
		for (k = 0; k < nrand; k = k + 1) random_access();
		run_active(fcyc/3);
		check_mem();

		$display("PASS: %0d MCLK cycles, %0d compare points, %0d mismatches; vsync=%0d hsync=%0d de=%0d",
			cycle, ncmp, nmis, n_vsync, n_hsync, n_de);
		$finish;
	end

	initial begin repeat (60000000) @(posedge MCLK); $display("TIMEOUT cycle=%0d", cycle); $finish; end

endmodule
