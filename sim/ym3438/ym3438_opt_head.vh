/*
 * ym3438_opt.v -- STAGE 2: ym3438_rtl with the collapsible ym_sr_bit master-slave
 * pairs on the internal FM phase replaced by a single edge-triggered flip-flop,
 * while the cells that a single FF CANNOT represent exactly are kept two-register.
 * Output-exact to the die model: the A/B bench (sim/ym3438, +OPT) passes 200000
 * MCLK cycles on both random seeds with 0 output mismatches, and the sr_out
 * cell-level diagnostic (+SROUT) shows 0 internal divergences over the same runs.
 *
 * Provenance: the cell scaffolding was emitted by sim/ym3438/opt_gen.sh (which does
 * the mechanical single-FF collapse of every ym_sr_bit); the per-cell KEEP=0/1
 * classification below is then maintained HERE, in this file, which is the
 * authoritative artifact validated by the bench and fitted by Quartus.  opt_gen.sh
 * only produces the naive all-collapse starting point -- do NOT let it overwrite
 * this file without re-applying the KEEP classification (see its header banner).
 * The primitive cell definitions live in sim/ym3438/ym3438_opt_head.vh.
 *
 * A ym_sr_bit is a two-phase master-slave: v1 loads bit_in during c1, the slave v2
 * loads v1 during c2, sr_out = v2[MSB].  c1/c2 are the non-overlapping internal FM
 * phases (each high for several MCLK, with a dead phase between).  The die value is
 * bit_in sampled at the LAST c1 edge; a single FF that captures at the c2 rising
 * edge (c2r = c2 & ~c2_prev) instead samples bit_in at the FIRST c2 edge.
 *
 * RULE (parameter KEEP on every collapsible cell):
 *   KEEP=0 (collapse, 1 FF/bit): EXACT iff bit_in is phase-stable across the c1..c2
 *     window -- i.e. bit_in is another cell's registered v2/sr_out, or a pure
 *     combinational function of such registered outputs.  These sample identically
 *     at the last-c1 and first-c2 edges (non-blocking, pre-update).  This covers
 *     every shift-register CHAIN and the whole op/eg/pg/ch/detune pipeline.
 *   KEEP=1 (kept, 2 FF/bit, die-identical): REQUIRED where bit_in is combinational
 *     AND phase-varying -- it can differ between the last-c1 edge and the first-c2
 *     edge, so the single FF would latch the wrong value.  In this design the only
 *     phase-varying sources are (a) nIC / IC (async reset; changes off-phase at
 *     IC-release), (b) the CPU-bus write strobes/data (async), and (c) TEST_i
 *     (async).  A one-slot error at IC-release on a FREE-RUNNING counter or a
 *     rotating register-ring is permanent, so all such cells are kept.
 *
 * Cells kept two-register (KEEP=1), by reason:
 *   - fsm cnt_low/cnt_high, reg_ctrl cnt_low/cnt_high, eg subcnt, io busy_cnt,
 *     lfo lfo_subcnt_sr, eg eg_timer_sr, reg_ctrl timer_a/b counters : free-running
 *     position/timers whose reset (nIC / fsm_sel23) is phase-varying at IC-release.
 *   - the whole reg_ctrl register file (reg_data reg_sr, op_register sr1/sr2,
 *     ch_register sr_0 [stage 0 only -- sr_1..5 are chains and collapse], fm_address,
 *     fm_data, reg_a4/ac, reg_dac_msb, reg_27_timer_reset, kon_sr1..4) : recirculating
 *     rings reset by nIC that must stay slot-aligned with the counter through IC-release.
 *   - io write_a_sr/write_d_sr, reg_wr_ctrl reg_addr_sr : bit_in from async bus strobes.
 *   - eg mask_bit_sr, eg state_sr1, eg timer_shift_sr[11] : bit_in carries nIC and/or
 *     the async TEST_i path.
 *   - the prescaler's ym_sr_bit cells (ym_sr_bit_kept): GENERATE c1/c2 on the PHI
 *     phase, kept two-register so c1/c2 stay bit-identical to the die.
 *
 * NOT collapsed for other reasons (single register already, unchanged from _rtl):
 *   - the transparent latches ym_dlatch_1/2, ym_slatch (already ONE register);
 *   - the set/reset flip-flops ym_rs_trig, ym_rs_trig_sync.
 */

`default_nettype wire

// ---- collapsed master-slave shift cell (single edge-triggered FF) ------------
// KEEP=0: single-FF collapse (capture bit_in at the c2 rising edge, c2r).  Exact
//   ONLY when bit_in is phase-stable across the c1..c2 window (a chain input, i.e.
//   another cell's registered v2/sr_out, or a pure function of such).
// KEEP=1: the die's genuine two-phase master-slave (v1<=bit_in at c1, v2<=v1 at
//   c2).  REQUIRED for any cell whose bit_in is combinational-and-phase-varying --
//   i.e. changes between the c1 sample and the c2 sample (reset/IC-release, the
//   free-running FSM counters, and anything derived from them).  Bit-exact to die.
module ym_sr_bit_opt #(parameter SR_LENGTH = 1, KEEP = 0)
	(
	input MCLK,
	input c1,       // used only when KEEP=1 (master phase)
	input c2,       // used only when KEEP=1 (slave phase)
	input c2r,      // rising-edge-of-c2 capture pulse (shared per module); KEEP=0
	input bit_in,
	output sr_out
	);

	generate
	if (KEEP) begin : g_kept
		reg [SR_LENGTH-1:0] v1 = 0;
		reg [SR_LENGTH-1:0] v2 = 0;
		wire [SR_LENGTH-1:0] v2_assign = c2 ? v1 : v2;
		assign sr_out = v2[SR_LENGTH-1];
		always @(posedge MCLK)
		begin
			if (c1)
			begin
				if (SR_LENGTH == 1)
					v1 <= bit_in;
				else
					v1 <= { v2[SR_LENGTH-2:0], bit_in };
			end
			v2 <= v2_assign;
		end
	end else begin : g_opt
		reg [SR_LENGTH-1:0] q = 0;
		assign sr_out = q[SR_LENGTH-1];
		always @(posedge MCLK)
			if (c2r)
			begin
				if (SR_LENGTH == 1)
					q <= bit_in;
				else
					q <= { q[SR_LENGTH-2:0], bit_in };
			end
	end
	endgenerate
endmodule

// ---- kept (two-register) shift cell: used ONLY by the prescaler --------------
module ym_sr_bit_kept #(parameter SR_LENGTH = 1)
	(
	input MCLK,
	input c1,
	input c2,
	input bit_in,
	output sr_out
	);

	reg [SR_LENGTH-1:0] v1 = 0;
	reg [SR_LENGTH-1:0] v2 = 0;

	wire [SR_LENGTH-1:0] v2_assign = c2 ? v1 : v2;

	assign sr_out = v2[SR_LENGTH-1];

	always @(posedge MCLK)
	begin
		if (c1)
		begin
			if (SR_LENGTH == 1)
				v1 <= bit_in;
			else
				v1 <= { v2[SR_LENGTH-2:0], bit_in };
		end
		v2 <= v2_assign;
	end
endmodule

module ym_sr_bit_array_opt #(parameter SR_LENGTH = 1, DATA_WIDTH = 1, KEEP = 0)
	(
	input MCLK,
	input c1,
	input c2,
	input c2r,
	input [DATA_WIDTH-1:0] data_in,
	output [DATA_WIDTH-1:0] data_out
	);

	wire out[0:DATA_WIDTH-1];

	generate
		genvar i;
		for (i = 0; i < DATA_WIDTH; i = i + 1)
		begin : l1
			ym_sr_bit_opt #(.SR_LENGTH(SR_LENGTH), .KEEP(KEEP)) sr (
			.MCLK(MCLK), .c1(c1), .c2(c2), .c2r(c2r),
			.bit_in(data_in[i]), .sr_out(out[i]) );
			assign data_out[i] = out[i];
		end
	endgenerate
endmodule

module ym_cnt_bit_opt #(parameter DATA_WIDTH = 1, KEEP = 0)
	(
	input MCLK, input c1, input c2, input c2r,
	input c_in, input reset,
	output [DATA_WIDTH-1:0] val, output c_out
	);
	wire [DATA_WIDTH-1:0] data_in;
	wire [DATA_WIDTH-1:0] data_out;
	wire [DATA_WIDTH:0] sum;
	ym_sr_bit_array_opt #(.DATA_WIDTH(DATA_WIDTH), .KEEP(KEEP)) mem
		( .MCLK(MCLK), .c1(c1), .c2(c2), .c2r(c2r), .data_in(data_in), .data_out(data_out) );
	assign sum = { 1'h0, data_out } + {{DATA_WIDTH{1'h0}}, c_in};
	assign val = data_out;
	assign data_in = reset ? {DATA_WIDTH{1'h0}} : sum[DATA_WIDTH-1:0];
	assign c_out = sum[DATA_WIDTH];
endmodule

module ym_cnt_bit_load_opt #(parameter DATA_WIDTH = 1, KEEP = 0)
	(
	input MCLK, input c1, input c2, input c2r,
	input c_in, input reset, input load, input [DATA_WIDTH-1:0] load_val,
	output [DATA_WIDTH-1:0] val, output c_out
	);
	wire [DATA_WIDTH-1:0] data_in;
	wire [DATA_WIDTH-1:0] data_out;
	wire [DATA_WIDTH:0] sum;
	ym_sr_bit_array_opt #(.DATA_WIDTH(DATA_WIDTH), .KEEP(KEEP)) mem
		( .MCLK(MCLK), .c1(c1), .c2(c2), .c2r(c2r), .data_in(data_in), .data_out(data_out) );
	wire [DATA_WIDTH-1:0] base_val = load ? load_val : data_out;
	assign sum = {1'h0, base_val} + {{DATA_WIDTH{1'h0}},c_in};
	assign data_in = reset ? {DATA_WIDTH{1'h0}} : sum[DATA_WIDTH-1:0];
	assign val = data_out;
	assign c_out = sum[DATA_WIDTH];
endmodule

module ym_dbg_read_opt #(parameter DATA_WIDTH = 1, KEEP = 0)
	(
	input MCLK, input c1, input c2, input c2r,
	input prev, input load, input [DATA_WIDTH-1:0] load_val, output next
	);
	wire [DATA_WIDTH-1:0] data_in;
	wire [DATA_WIDTH-1:0] data_out;
	ym_sr_bit_array_opt #(.DATA_WIDTH(DATA_WIDTH), .KEEP(KEEP)) mem
		( .MCLK(MCLK), .c1(c1), .c2(c2), .c2r(c2r), .data_in(data_in), .data_out(data_out) );
	wire [DATA_WIDTH-1:0] chain;
	assign data_in = chain | (load ? load_val : {DATA_WIDTH{1'h0}});
	generate
		if (DATA_WIDTH == 1) assign chain = prev;
		else assign chain = { prev, data_out[DATA_WIDTH-1:1] };
	endgenerate
	assign next = data_out[0];
endmodule

module ym_dbg_read_eg_opt #(parameter DATA_WIDTH = 1, KEEP = 0)
	(
	input MCLK, input c1, input c2, input c2r,
	input prev, input load, input [DATA_WIDTH-1:0] load_val, output next
	);
	wire [DATA_WIDTH-1:0] data_in;
	wire [DATA_WIDTH-1:0] data_out;
	ym_sr_bit_array_opt #(.DATA_WIDTH(DATA_WIDTH), .KEEP(KEEP)) mem
		( .MCLK(MCLK), .c1(c1), .c2(c2), .c2r(c2r), .data_in(data_in), .data_out(data_out) );
	wire [DATA_WIDTH-1:0] chain;
	assign data_in = chain | (load ? load_val : {DATA_WIDTH{1'h0}});
	generate
		if (DATA_WIDTH == 1) assign chain = prev;
		else assign chain = { data_out[DATA_WIDTH-2:0], prev };
	endgenerate
	assign next = data_out[DATA_WIDTH-1];
endmodule

// ---- unchanged single-register cells (renamed _opt) --------------------------
module ym_dlatch_1_opt #(parameter DATA_WIDTH = 1)
	( input MCLK, input c1, input [DATA_WIDTH-1:0] inp, output [DATA_WIDTH-1:0] val, output [DATA_WIDTH-1:0] nval );
	reg [DATA_WIDTH-1:0] mem = {DATA_WIDTH{1'h0}};
	always @(posedge MCLK) if (c1) mem <= inp;
	assign val = mem;
	assign nval = ~mem;
endmodule

// ym_dlatch_2 carries an (ignored) c2r port so the blanket ".c2(c2)->,.c2r(c2r)"
// instantiation rewrite is uniform; the latch still uses c2, not c2r.
module ym_dlatch_2_opt #(parameter DATA_WIDTH = 1)
	( input MCLK, input c2, input c2r, input [DATA_WIDTH-1:0] inp, output [DATA_WIDTH-1:0] val, output [DATA_WIDTH-1:0] nval );
	reg [DATA_WIDTH-1:0] mem = {DATA_WIDTH{1'h0}};
	always @(posedge MCLK) if (c2) mem <= inp;
	assign val = mem;
	assign nval = ~mem;
endmodule

module ym_edge_detect_opt
	( input MCLK, input c1, input inp, output outp );
	wire prev_out;
	ym_dlatch_1_opt prev ( .MCLK(MCLK), .c1(c1), .inp(inp), .val(prev_out), .nval() );
	assign outp = ~(prev_out | ~inp);
endmodule

module ym_slatch_opt #(parameter DATA_WIDTH = 1)
	( input MCLK, input en, input [DATA_WIDTH-1:0] inp, output [DATA_WIDTH-1:0] val, output [DATA_WIDTH-1:0] nval );
	reg [DATA_WIDTH-1:0] mem = {DATA_WIDTH{1'h0}};
	always @(posedge MCLK) if (en) mem <= inp;
	assign val = mem;
	assign nval = ~mem;
endmodule

module ym_rs_trig_opt
	( input MCLK, input set, input rst, output reg q = 1'h0, output reg nq = 1'h1 );
	always @(posedge MCLK) begin
		q <= rst ? 1'h0 : (set ? 1'h1 : q);
		nq <= set ? 1'h0 : (rst ? 1'h1 : ~q);
	end
endmodule

module ym_rs_trig_sync_opt
	( input MCLK, input set, input rst, input c1, output reg q = 1'h0, output reg nq = 1'h1 );
	always @(posedge MCLK) begin
		q <= (c1 & rst) ? 1'h0 : ((c1 & set) ? 1'h1 : q);
		nq <= (c1 & set) ? 1'h0 : ((c1 & rst) ? 1'h1 : ~q);
	end
endmodule
