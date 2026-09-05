/*
 * Copyright (C) 2023 nukeykt
 *
 * This file is part of Nuked-MD.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 *  TMSS(FC1004) emulator
 *  Thanks:
 *      org (ogamespec):
 *          FC1004 decap and die shot.
 *      andkorzh, HardWareMan (emu-russia):
 *          help & support.
 *
 */

/*
 * tmss_rtl -- 1:1 synthesis-friendly representation of tmss (rtl/nuked-md/tmss.v).
 *
 * Same port list, same logic, same storage, same MCLK (the 107.386 MHz sampling clock,
 * md_board's MCLK2). Nothing behavioural was added or removed: every `assign` is copied
 * verbatim from tmss.v (same wire names, same expressions); only the five ym_lib
 * primitive instances are replaced by inline registered logic that produces the same
 * value at every posedge MCLK. Storage registers are named <instance>_<reg> after the
 * primitive's instance name and its internal register, and the primitive's output wire
 * (q / nq / val) is kept as the original wire, assigned from that storage.
 *
 * Conversion rule per primitive (semantics are those of ym_lib.v as sampled on MCLK,
 * not idealised latch semantics):
 *
 *  ym_slatch  (ym_lib: `mem <= en ? inp : mem` every posedge MCLK; val = mem)
 *      ->  always @(posedge MCLK) if (en) mem <= inp;
 *      The recirculating mux becomes a clock enable. Exact by construction: on every
 *      MCLK edge the register takes inp when en is 1 and holds when en is 0, in both
 *      forms. Initial value {W{1'h0}} kept.
 *
 *  ym_sdffr   (ym_lib master-slave pair, all synchronous to MCLK:
 *                  if (~reset) l1 <= 0; else if (~clk) l1 <= val;
 *                  if (~reset) l2 <= 0; else if (clk)  l2 <= l1;      q = l2)
 *  ym_sdffs   (ym_lib master-slave pair, note the *asymmetric* set priority:
 *                  if (~clk) l1 <= val; else if (~set) l1 <= 1;
 *                  if (~set) l2 <= 1;   else if (clk)  l2 <= l1;      nq = ~l2)
 *      ->  kept as the two registers l1/l2 with the identical update rules, written
 *          inline. This is the "when in doubt keep two registers" form and it is exact
 *          trivially (same registers, same next-state equations, same reset/set
 *          priority, same initial values).
 *      Why not the single-register form (`if (clk & ~clk_prev) q <= val_prev`)?
 *          In tmss the `clk` inputs of the three flip-flops are not internal clock
 *          phases but bus-derived logic nets (w40 = ~(~RW & w15), w10 = ~(~AS &
 *          VA[22:20]==6), ~w23 | RW), and the `val` inputs (w3, dff1_q, VD_i[0]) can
 *          change on the very MCLK edge that precedes the rising edge of `clk` (e.g. w3
 *          depends on sl1/sl2, whose enables w38/w39 are high exactly while w40 is low).
 *          l2 takes the value of val from the *last edge on which clk was low*, so a
 *          single-register form would still need a register holding that value (which
 *          is l1) plus a clk_prev register: no storage saving and a harder equivalence
 *          argument (reset/set priority interplay with clk_prev). Two registers it is.
 *      Initial values: ym_sdffr has l1 = 0, l2 = 0 -> kept. ym_sdffs has NO initialiser
 *          in ym_lib.v -> none written here either (same power-up representation for
 *          Quartus; in simulation both models start X until the first ~set).
 *
 * The three `assign`s that were arguments of primitive ports (dff3's clk `~w23 | RW`,
 * sl1/sl2 `.inp(VD_i)`) are used in place, as they were.
 */

module tmss_rtl
	(
	input MCLK,
	input [15:0] VD_i,
	input [2:0] test,
	input JAP,
	input AS,
	input LDS,
	input UDS,
	input RW,
	input [22:0] VA,
	input SRES,
	input CE0_i,
	input M3,
	input CART,
	input INTAK,
	output [15:0] VD_o,
	output DTACK,
	output RESET,
	output CE0_o,
	output test_0,
	output test_1,
	output test_2,
	output test_3,
	output test_4,
	output data_out_en,
	input tmss_enable,
	input [15:0] tmss_data,
	output [9:0] tmss_address
	);

	wire dff1_q;
	wire dff2_nq;
	wire w3;
	wire w10;
	wire w15;
	wire w23;
	wire w40;
	wire w41;
	wire dff3_q;
	wire w31;
	wire w28;
	wire w38;
	wire [15:0] l1;
	wire w39;
	wire [15:0] l2;
	wire [15:0] w20;
	wire w50;
	wire w51;
	wire w53;
	wire w54;
	wire w55;
	wire w56;
	wire w52;
	wire w57;
	wire w58;
	wire w59;
	wire w62;

	// ym_sdffr dff1(.MCLK(MCLK), .clk(w40), .val(w3), .reset(SRES), .q(dff1_q));
	reg dff1_l1 = 1'h0, dff1_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~SRES)
			dff1_l1 <= 1'h0;
		else if (~w40)
			dff1_l1 <= w3;
		if (~SRES)
			dff1_l2 <= 1'h0;
		else if (w40)
			dff1_l2 <= dff1_l1;
	end
	assign dff1_q = dff1_l2;

	// ym_sdffs dff2(.MCLK(MCLK), .clk(w10), .val(dff1_q), .set(SRES), .nq(dff2_nq));
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg dff2_l1, dff2_l2;
	always @(posedge MCLK)
	begin
		if (~w10)
			dff2_l1 <= dff1_q;
		else if (~SRES)
			dff2_l1 <= 1'h1;
		if (~SRES)
			dff2_l2 <= 1'h1;
		else if (w10)
			dff2_l2 <= dff2_l1;
	end
	assign dff2_nq = ~dff2_l2;

	assign w3 = l1 == 16'h5345 & l2 == 16'h4741;

	assign RESET = tmss_enable ? (~(JAP & dff2_nq) | test_4) : 1'h1;

	assign w10 = ~(~AS & VA[22:20] == 3'h6);

	assign w15 = ~AS & ~LDS & VA[22:1] == 22'h285000 & ~UDS;
	assign w23 = ~AS & ~LDS & VA == 23'h50a080;

	assign DTACK = tmss_enable ? (~((w15 | w23) & INTAK) | test_4) : 1'h1;

	assign w40 = ~(~RW & w15);
	assign w41 = ~(RW & w15);

	// ym_sdffr dff3(.MCLK(MCLK), .clk(~w23 | RW), .val(VD_i[0]), .reset(SRES), .q(dff3_q));
	reg dff3_l1 = 1'h0, dff3_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~SRES)
			dff3_l1 <= 1'h0;
		else if (~(~w23 | RW))
			dff3_l1 <= VD_i[0];
		if (~SRES)
			dff3_l2 <= 1'h0;
		else if (~w23 | RW)
			dff3_l2 <= dff3_l1;
	end
	assign dff3_q = dff3_l2;
	//ym_sdffs dff3(.MCLK(MCLK), .clk(~w23 | RW), .val(VD_i[0]), .set(SRES), .q(dff3_q));

	assign w31 = CART | ~M3;
	assign w28 = dff3_q | w31 | CE0_i;
	assign CE0_o = tmss_enable ? (~(dff3_q | w31) | CE0_i) : CE0_i;

	assign w38 = ~VA[0] & ~RW & w15;
	// ym_slatch #(.DATA_WIDTH(16)) sl1(.MCLK(MCLK), .en(w38), .inp(VD_i), .val(l1));
	reg [15:0] sl1_mem = 16'h0;
	always @(posedge MCLK)
		if (w38)
			sl1_mem <= VD_i;
	assign l1 = sl1_mem;
	assign w39 = VA[0] & ~RW & w15;
	// ym_slatch #(.DATA_WIDTH(16)) sl2(.MCLK(MCLK), .en(w39), .inp(VD_i), .val(l2));
	reg [15:0] sl2_mem = 16'h0;
	always @(posedge MCLK)
		if (w39)
			sl2_mem <= VD_i;
	assign l2 = sl2_mem;

	assign w20 = VA[0] ? l2 : l1;
	assign VD_o = tmss_enable ? (w28 ? w20 : tmss_data) : 16'h0;

	assign tmss_address = VA[9:0];

	assign data_out_en = tmss_enable ? (w41 & w28) | test_4 : 1'h1;

	assign w50 = test[2:0] != 3'h0;
	assign w51 = test[2:0] != 3'h1;
	assign w53 = test[2:0] != 3'h2;
	assign w54 = test[2:0] != 3'h3;
	assign w55 = test[2:0] != 3'h4;
	assign w56 = test[2:0] != 3'h7;

	assign w52 = w50 ^ w56;
	assign w57 = w51 ^ w56;
	assign w58 = w53 ^ w56;
	assign w59 = w54 ^ w56;
	assign w62 = w56 ^ w55;

	assign test_0 = ~w52;
	assign test_1 = ~w57;
	assign test_2 = ~w58;
	assign test_3 = ~w59;
	assign test_4 = ~w62;

endmodule
