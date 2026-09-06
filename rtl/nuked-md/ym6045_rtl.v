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
 *  YM6045C(FC1004) emulator.
 *  Thanks:
 *      org (ogamespec):
 *          FC1004 decap and die shot.
 *      andkorzh, HardWareMan (emu-russia):
 *          help & support.
 *
 */

/*
 * ym6045_rtl -- 1:1 synthesis-friendly representation of ym6045 (rtl/nuked-md/ym6045.v), the
 * FC1004 bus arbiter / DRAM refresh / DTACK generator.
 *
 * Same port list, same logic, same storage, same MCLK (the 107.386 MHz sampling clock, md_board's
 * MCLK2). MCLK_e (MCLK/2), VCLK (= the VDP's CLK1, 68000 clock, MCLK/14), ZCLK (= CLK0, Z80 clock,
 * MCLK/30) and HSYNC stay data inputs exactly as in ym6045.v / fc1004.v. Nothing behavioural was
 * added or removed: every `assign`, every wire declaration and the two inline MCLK registers
 * (edclk_buf, w45_mem) are copied verbatim from ym6045.v (same names, same expressions, same
 * order); only the 80 ym_lib primitive instances are replaced by inline registered logic that
 * produces the same value at every posedge MCLK. The original instance line is kept as a comment
 * above each block; storage registers are named <instance>_<reg> after the primitive's instance
 * name and its internal register (l1 / l2 / dl); the primitive's output wires (q / nq / cout /
 * outp) keep their original names, assigned from that storage.
 *
 * Primitive census of ym6045.v (80 instances of 5 kinds; the module has no ym_slatch, ym_dlatch,
 * ym_rs_trig, ym_sr_bit or ym_cnt_bit):
 *   ym_scnt_bit   15  dff1 dff2 dff3 (EDCLK divider, clk MCLK_e); dff4 dff5 dff6 dff7 (EDCLK/HSYNC
 *                     phase counter, clk w4 = the divider output); dff78 dff80 dff79 dff77 and
 *                     dff48 dff54 dff53 dff55 (the two 4-bit VCLK refresh-period counters)
 *   ym_sdffr      25  dff9 dff49 dff50 dff51 dff61 dff62 dff60 dff68 dff71 dff72 dff76 dff63 dff52
 *                     dff65 dff67 dff74 dff57 dff58 dff69 zbr dff25 dff26 dff23 dff31, and z80bank
 *                     (DATA_WIDTH 9: the Z80 bank register shift chain)
 *   ym_sdffs      10  dff8 nmi dff47 dff45 dff46 dff17 dff20 dff19 dff15 dff33
 *   ym_sdff       22  dff34 dff10 dff28 dff22 dff18 dff21 dff29 dff27 dff30 dff44 dff59 dff75 dff66
 *                     dff73 dff64 dff70 dff16 dff11 dff12 dff13 dff24 sres_syncv
 *   ym_delaychain  8  d1(1) d2(1) d3(7) d4(1) d5(2) d6(6) d7(6) d8(1)  (DELAY_CNT in brackets)
 *   inline regs    2  edclk_buf, w45_mem: already plain posedge-MCLK registers in ym6045.v, copied
 * Storage: 72 master-slave pairs (71 x 1 bit + 1 x 9 bits = 160 bits) + 25 delay-chain bits +
 * 2 inline bits = 187 register bits, the same set as the die model, one for one.
 *
 * Conversion rule per primitive kind (the semantics are those of ym_lib.v as sampled on MCLK,
 * not idealised latch semantics; each rule is the primitive's own always block written inline):
 *
 *  ym_sdff     ym_lib master-slave pair, both halves synchronous to MCLK:
 *                  if (~clk) l1 <= val; else l2 <= l1;                      q = l2, nq = ~l2
 *  ym_sdffr    ... with a synchronous reset that has priority in both halves:
 *                  if (~reset) l1 <= 0; else if (~clk) l1 <= val;
 *                  if (~reset) l2 <= 0; else if (clk)  l2 <= l1;
 *  ym_sdffs    ... with the *asymmetric* set priority of ym_lib (val wins over set in l1 while
 *              clk is low; set wins in l2):
 *                  if (~clk) l1 <= val; else if (~set) l1 <= 1;
 *                  if (~set) l2 <= 1;   else if (clk)  l2 <= l1;
 *  ym_scnt_bit counter cell (DATA_WIDTH 1 everywhere here), load active low, rst active low with
 *              priority over both halves:
 *                  sum = {0, l2} + {0, cin};  cout = sum[1];
 *                  if (~rst) begin l1 <= 0; l2 <= 0; end
 *                  else if (~clk) l1 <= ~load ? val : sum[0]; else l2 <= l1;
 *      ->  all four kept as the two registers l1 / l2 with the identical update rules, written
 *          inline. This is the "when in doubt keep two registers" form and it is exact trivially
 *          (same registers, same next-state equations, same reset/set priority, same initial
 *          values); the equivalence bench (sim/ym6045) compares every l1 and l2 of both models
 *          at every MCLK edge.
 *      Why no single-register form ("if (clk_rise_en) q <= val") anywhere in this module: the
 *          task allows it only with an exactness proof on a genuine internal clock phase. In
 *          ym6045 the `clk` inputs are either external clocks carried as data (VCLK, ~VCLK, ZCLK,
 *          ~ZCLK, MCLK_e), outputs of other flip-flops (w2/w4 from the EDCLK divider; dff74_q,
 *          dff68_q, dff71_q, dff72_q, dff63_q, dff52_q, dff65_q, dff67_q in the power-on timer
 *          chain) or bus-derived logic nets (w36, w96, w97, w150, ~w59 = M3 & ~AS, w274 = ~CAS0,
 *          w279 = ~BGACK, ~w16, ~w362), and the `val` inputs are logic of bus inputs that can
 *          change on any MCLK edge. In ym_lib, l2 takes the value that l1 captured on the *last
 *          MCLK edge on which clk was low*; a single register would still need that held value
 *          (which is l1) plus a clk_prev register, so there is no storage saving, and the
 *          reset/set priorities would need a separate argument for every instance. Two registers
 *          for all 72 pairs, no proof obligations beyond "same equations".
 *  ym_delaychain #(N)   dl <= {dl[N-2:0], inp} (dl <= inp for N = 1) every MCLK; outp = dl[N-1]
 *      ->  the same N-bit shift register inline, initial value 0 kept.
 *  ym_slatch / ym_dlatch (rule: `always @(posedge MCLK) if (en) mem <= inp;`)  -- none here.
 *
 * Initial values: ym_sdff, ym_sdffr, ym_scnt_bit and ym_delaychain have l1 = l2 = 0 (dl = 0) in
 * ym_lib.v -> kept. ym_sdffs has NO initialiser in ym_lib.v -> none written here either (same
 * power-up representation for Quartus; in simulation both models start X until the first ~set).
 *
 * Refresh, as it is wired in this netlist (for the record, nothing changed): the two 4-bit VCLK
 * counters dff78/80/79/77 and dff48/54/53/55 (dff55 reloads with M3, so the period is 128 VCLK
 * in MD mode, 256 in Mark III mode) raise w287 for one VCLK; w287 -> dff47 (~VCLK) -> dff70 ->
 * w316 -> REF (active low) while /AS is high, i.e. the refresh cycle is issued between 68000 bus
 * cycles; w287 also clears the "refresh pending" flag dff33, and a bus cycle starting (dff23,
 * clocked by M3 & ~/AS) while it is pending sets the stall flag dff23_q, which holds off the
 * arbiter's DTACK timer (dff15 via w83) for A23 = 0 accesses and the dff17/20/19 sequencer (via
 * w54) for A23 = 1 accesses until dff33 clears one VCLK later (w183). The Z80's own M1 refresh
 * (M1 delayed two ZCLK through dff27/dff30/dff44, with /MREQ low) also drives REF via w320.
 */

module ym6045_rtl
	(
	input MCLK,
	input MCLK_e,
	input VCLK,
	input ZCLK,
	input VD8_i,
	input [15:7] ZA_i,
	input ZA0_i,
	input [22:7] VA_i,
	input ZRD_i,
	input M1,
	input ZWR_i,
	input BGACK_i,
	input BG,
	input IORQ,
	input RW_i,
	input UDS_i,
	input AS_i,
	input DTACK_i,
	input LDS_i,
	input CAS0,
	input M3,
	input WRES,
	input CART,
	input OE0,
	input WAIT_i,
	input ZBAK,
	input MREQ_i,
	input FC0,
	input FC1,
	input SRES,
	input test_mode_0,
	input ZD0_i,
	input HSYNC,
	output VD8_o,
	output ZA0_o,
	output [15:8] ZA_o,
	output [22:7] VA_o,
	output ZRD_o,
	output UDS_o,
	output ZWR_o,
	output BGACK_o,
	output AS_o,
	output RW_d,
	output RW_o,
	output LDS_o,
	output strobe_dir,
	output DTACK_o,
	output BR,
	output IA14,
	output TIME,
	output CE0,
	output FDWR,
	output FDC,
	output ROM,
	output ASEL,
	output EOE,
	output NOE,
	output RAS2,
	output CAS2,
	output REF,
	output ZRAM,
	output WAIT_o,
	output ZBR,
	output NMI,
	output ZRES,
	output SOUND,
	output VZ,
	output MREQ_o,
	output VRES,
	output VPA,
	output VDPM,
	output IO,
	output ZV,
	output INTAK,
	output EDCLK,
	output vtoz,
	output w12,
	output w131,
	output w142,
	output w310,
	output w353
	);
	
	wire pal_trap = ~1'h1;
	
	//reg dff1;
	//reg dff2;
	//reg dff3;
	
	wire dff1_nq;
	wire dff2_q, dff2_nq;
	wire dff3_q, dff3_nq;
	
	wire dff4_nq, dff4_cout;
	wire dff5_nq, dff5_cout;
	wire dff6_nq, dff6_cout;
	wire dff7_nq;
	wire dff8_nq;
	wire dff9_q;
	wire w1;
	wire w2;
	wire w3;
	wire w4;
	wire w5;
	wire w7;
	wire w9;
	wire w10;
	wire w11;
	wire dff10_q;
	wire w16;
	wire dff11_q;
	wire dff12_q, dff12_nq;
	wire w26;
	wire w27;
	wire w31;
	wire w33;
	wire w34;
	wire w35;
	wire dff13_q;
	wire w36;
	wire zbr_nq;
	wire sres;
	wire dff15_q, dff15_nq;
	wire w40;
	wire w41;
	wire w42;
	wire w43;
	wire dff16_q;
	wire w44;
	wire w45;
	wire w46;
	wire w48;
	wire w49;
	wire dff17_q;
	wire w50;
	wire dff18_q;
	wire w51;
	wire w53;
	wire w54;
	wire vd8;
	wire w58;
	wire w59;
	wire w63;
	wire w64;
	wire w65;
	wire w66;
	wire w68;
	wire dff19_q;
	wire w69;
	wire w70;
	wire w71;
	wire w72;
	wire dff20_q, dff20_nq;
	wire w73;
	wire w74;
	wire w75;
	wire w76;
	wire w77;
	wire w78;
	wire w79;
	wire dff21_q;
	wire dff22_q;
	wire mreq_in;
	wire w83;
	wire w84;
	wire w86;
	wire dff23_q, dff23_nq;
	wire w90;
	wire w91;
	wire w92; // nc
	wire w94;
	wire w95;
	wire w96;
	wire w97;
	wire w99;
	wire w101;
	wire w102;
	wire w103;
	wire dff24_q, dff24_nq;
	wire dff25_q;
	wire ztov;
	wire w106;
	wire w107;
	wire w111;
	wire w112;
	wire w113;
	wire w118;
	wire w119;
	wire w122;
	wire w124;
	wire w126;
	wire w128;
	wire w129;
	wire w130;
	wire dff26_nq;
	wire dff27_q;
	wire w132;
	wire w133;
	wire w134;
	wire dff28_q;
	wire w136;
	wire w137;
	wire w140;
	wire w143;
	wire dff29_q;
	wire w146;
	wire w149;
	wire w150;
	wire test;
	wire w163;
	wire w164;
	wire w166;
	wire w167;
	wire dff30_q;
	wire w168;
	wire w169;
	wire w170;
	wire dff31_q;
	wire w171;
	wire w172;
	wire w173;
	wire w174;
	wire w175;
	wire w176;
	wire w178;
	wire w182;
	wire sres_syncv_q, sres_syncv_nq;
	wire dff33_q, dff33_nq;
	wire w183;
	wire w185;
	wire w188;
	wire w194;
	wire w197;
	wire w198;
	wire w199;
	wire w200;
	wire w202;
	wire w204;
	wire w206;
	wire w207;
	wire w208;
	wire w211;
	wire w215;
	wire w220;
	wire dff34_q;
	wire w222;
	wire w223;
	wire va22_cart;
	wire dff44_q, dff44_nq;
	wire w232;
	wire w234;
	wire w235;
	wire w238;
	wire w248;
	wire w249;
	wire w254;
	wire w255;
	wire w257;
	wire w258;
	wire w266;
	wire w268;
	wire w269;
	wire dff45_q, dff45_nq;
	wire dff46_q, dff46_nq;
	wire w271;
	wire dff47_q, dff47_nq;
	wire w272;
	wire w273;
	wire w274;
	wire w279;
	wire w283;
	wire w286;
	wire w287;
	wire w289;
	wire dff48_nq, dff48_cout;
	wire w298;
	wire dff49_q, dff49_nq;
	wire dff50_q, dff50_nq;
	wire dff51_q;
	wire w299;
	wire w300;
	wire w301;
	wire w302;
	wire dff52_q, dff52_nq;
	wire w307;
	wire w308;
	wire dff53_nq, dff53_cout;
	wire dff54_nq, dff54_cout;
	wire dff55_nq, dff55_cout;
	wire w309;
	wire w311;
	wire w314;
	wire w316;
	wire w318;
	wire w320;
	wire w321;
	wire w322;
	wire w325;
	wire w326;
	wire nmi_q;
	wire dff57_q;
	wire dff58_nq;
	wire dff59_q;
	wire w328;
	wire w331;
	wire w332;
	wire w333;
	wire dff60_q;
	wire w334;
	wire w336;
	wire w337;
	wire w339;
	wire dff61_q, dff61_nq;
	wire w341;
	wire w342;
	wire dff62_q;
	wire w343;
	wire dff63_q, dff63_nq;
	wire dff64_nq;
	wire w344;
	wire dff65_q, dff65_nq;
	wire dff66_q, dff66_nq;
	wire dff67_q, dff67_nq;
	wire dff68_q, dff68_nq;
	wire dff69_q, dff69_nq;
	wire w346;
	wire w348;
	wire dff70_q;
	wire dff71_q, dff71_nq;
	wire dff72_q, dff72_nq;
	wire dff73_q;
	wire dff74_q, dff74_nq;
	wire w354;
	wire dff75_nq;
	wire dff76_q, dff76_nq;
	wire dff77_nq, dff77_cout;
	wire w356;
	wire w362;
	wire w363;
	wire w372;
	wire dff78_nq, dff78_cout;
	wire w374;
	wire dff79_nq, dff79_cout;
	wire dff80_nq, dff80_cout;
	wire w383;
	
	wire fc00;
	wire fc01;
	wire fc10;
	wire fc11;
	
	wire va14_in;
	wire va21_in;
	wire va22_in;
	wire va23_in;
	
	wire za15_in;
	
	wire [8:0] z80bank_q;
	
	wire [15:0] va_out;
	
	reg edclk_buf;
	
	// EDCLK
	/*always @(posedge MCLK)
	begin
		if (!sres)
		begin
			dff1 <= 1'h0;
			dff2 <= 1'h0;
			dff3 <= 1'h0;
		end
		else
		begin
			if (~w1)
			begin
				dff1 <= 1'h1;
				dff2 <= ~dff9_q;
				dff3 <= 1'h0;
			end
			else
			begin
				dff1 <= dff1 ^ w3;
				dff2 <= ~dff2;
				dff3 <= dff3 ^ dff2;
			end
		end
		
		edclk_buf <= w2;
	end*/
	
	// ym_scnt_bit dff1(.MCLK(MCLK), .clk(MCLK_e), .load(w1), .val(1'h1), .cin(w3), .rst(sres), .nq(dff1_nq));
	reg dff1_l1 = 1'h0, dff1_l2 = 1'h0;
	wire [1:0] dff1_sum = { 1'h0, dff1_l2 } + { 1'h0, w3 };
	always @(posedge MCLK)
	begin
		if (~sres)
		begin
			dff1_l1 <= 1'h0;
			dff1_l2 <= 1'h0;
		end
		else
		begin
			if (~MCLK_e)
				dff1_l1 <= ~w1 ? 1'h1 : dff1_sum[0];
			else
				dff1_l2 <= dff1_l1;
		end
	end
	assign dff1_nq = ~dff1_l2;

	// ym_scnt_bit dff2(.MCLK(MCLK), .clk(MCLK_e), .load(w1), .val(~dff9_q), .cin(1'h1), .rst(sres), .q(dff2_q), .nq(dff2_nq));
	reg dff2_l1 = 1'h0, dff2_l2 = 1'h0;
	wire [1:0] dff2_sum = { 1'h0, dff2_l2 } + { 1'h0, 1'h1 };
	always @(posedge MCLK)
	begin
		if (~sres)
		begin
			dff2_l1 <= 1'h0;
			dff2_l2 <= 1'h0;
		end
		else
		begin
			if (~MCLK_e)
				dff2_l1 <= ~w1 ? ~dff9_q : dff2_sum[0];
			else
				dff2_l2 <= dff2_l1;
		end
	end
	assign dff2_q = dff2_l2;
	assign dff2_nq = ~dff2_l2;

	// ym_scnt_bit dff3(.MCLK(MCLK), .clk(MCLK_e), .load(w1), .val(1'h0), .cin(dff2_q), .rst(sres), .q(dff3_q), .nq(dff3_nq));
	reg dff3_l1 = 1'h0, dff3_l2 = 1'h0;
	wire [1:0] dff3_sum = { 1'h0, dff3_l2 } + { 1'h0, dff2_q };
	always @(posedge MCLK)
	begin
		if (~sres)
		begin
			dff3_l1 <= 1'h0;
			dff3_l2 <= 1'h0;
		end
		else
		begin
			if (~MCLK_e)
				dff3_l1 <= ~w1 ? 1'h0 : dff3_sum[0];
			else
				dff3_l2 <= dff3_l1;
		end
	end
	assign dff3_q = dff3_l2;
	assign dff3_nq = ~dff3_l2;

	
	always @(posedge MCLK)
	begin
		edclk_buf <= w2;
	end
	
	//assign w1 = ~(~dff1 & ~dff2 & ~dff3);
	//assign w2 = dff3;
	//assign w3 = dff2 & dff3;
	assign w1 = ~(dff1_nq & dff2_nq & dff3_nq);
	assign w2 = dff3_q;
	assign w3 = dff2_q & dff3_q;
	assign w4 = w2;
	assign w5 = ~(dff4_nq | dff5_nq | dff6_nq | dff7_nq);

	// ym_scnt_bit dff4(.MCLK(MCLK), .clk(w4), .load(dff9_q), .val(1'h1), .cin(dff9_q), .rst(sres), .nq(dff4_nq), .cout(dff4_cout));
	reg dff4_l1 = 1'h0, dff4_l2 = 1'h0;
	wire [1:0] dff4_sum = { 1'h0, dff4_l2 } + { 1'h0, dff9_q };
	always @(posedge MCLK)
	begin
		if (~sres)
		begin
			dff4_l1 <= 1'h0;
			dff4_l2 <= 1'h0;
		end
		else
		begin
			if (~w4)
				dff4_l1 <= ~dff9_q ? 1'h1 : dff4_sum[0];
			else
				dff4_l2 <= dff4_l1;
		end
	end
	assign dff4_cout = dff4_sum[1];
	assign dff4_nq = ~dff4_l2;

	// ym_scnt_bit dff5(.MCLK(MCLK), .clk(w4), .load(dff9_q), .val(1'h0), .cin(dff4_cout), .rst(sres), .nq(dff5_nq), .cout(dff5_cout));
	reg dff5_l1 = 1'h0, dff5_l2 = 1'h0;
	wire [1:0] dff5_sum = { 1'h0, dff5_l2 } + { 1'h0, dff4_cout };
	always @(posedge MCLK)
	begin
		if (~sres)
		begin
			dff5_l1 <= 1'h0;
			dff5_l2 <= 1'h0;
		end
		else
		begin
			if (~w4)
				dff5_l1 <= ~dff9_q ? 1'h0 : dff5_sum[0];
			else
				dff5_l2 <= dff5_l1;
		end
	end
	assign dff5_cout = dff5_sum[1];
	assign dff5_nq = ~dff5_l2;

	// ym_scnt_bit dff6(.MCLK(MCLK), .clk(w4), .load(dff9_q), .val(1'h0), .cin(dff5_cout), .rst(sres), .nq(dff6_nq), .cout(dff6_cout));
	reg dff6_l1 = 1'h0, dff6_l2 = 1'h0;
	wire [1:0] dff6_sum = { 1'h0, dff6_l2 } + { 1'h0, dff5_cout };
	always @(posedge MCLK)
	begin
		if (~sres)
		begin
			dff6_l1 <= 1'h0;
			dff6_l2 <= 1'h0;
		end
		else
		begin
			if (~w4)
				dff6_l1 <= ~dff9_q ? 1'h0 : dff6_sum[0];
			else
				dff6_l2 <= dff6_l1;
		end
	end
	assign dff6_cout = dff6_sum[1];
	assign dff6_nq = ~dff6_l2;

	// ym_scnt_bit dff7(.MCLK(MCLK), .clk(w4), .load(dff9_q), .val(1'h0), .cin(dff6_cout), .rst(sres), .nq(dff7_nq));
	reg dff7_l1 = 1'h0, dff7_l2 = 1'h0;
	wire [1:0] dff7_sum = { 1'h0, dff7_l2 } + { 1'h0, dff6_cout };
	always @(posedge MCLK)
	begin
		if (~sres)
		begin
			dff7_l1 <= 1'h0;
			dff7_l2 <= 1'h0;
		end
		else
		begin
			if (~w4)
				dff7_l1 <= ~dff9_q ? 1'h0 : dff7_sum[0];
			else
				dff7_l2 <= dff7_l1;
		end
	end
	assign dff7_nq = ~dff7_l2;

	
	assign EDCLK = edclk_buf;
	
	assign w7 = dff8_nq;
	assign w11 = ~(~HSYNC | dff9_q);
	assign w10 = ~(w11 | (1'h0 & dff9_q));
	
	// ym_sdffr dff9(.MCLK(MCLK), .clk(w2), .val(w10), .reset(w7), .q(dff9_q));
	reg dff9_l1 = 1'h0, dff9_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~w7)
			dff9_l1 <= 1'h0;
		else if (~w2)
			dff9_l1 <= w10;
		if (~w7)
			dff9_l2 <= 1'h0;
		else if (w2)
			dff9_l2 <= dff9_l1;
	end
	assign dff9_q = dff9_l2;

	// ym_sdffs dff8(.MCLK(MCLK), .clk(w2), .val(w5), .set(sres), .nq(dff8_nq));
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg dff8_l1, dff8_l2;
	always @(posedge MCLK)
	begin
		if (~w2)
			dff8_l1 <= w5;
		else if (~sres)
			dff8_l1 <= 1'h1;
		if (~sres)
			dff8_l2 <= 1'h1;
		else if (w2)
			dff8_l2 <= dff8_l1;
	end
	assign dff8_nq = ~dff8_l2;

	
	// RAM OE
	assign w9 = sres;
	
	assign w279 = ~BGACK_i;
	assign w302 = ~(w9 & (dff50_nq | dff62_q));
	assign w299 = ~w302;
	
	// ym_sdffr dff49(.MCLK(MCLK), .clk(VCLK), .val(w279), .reset(dff51_q), .q(dff49_q), .nq(dff49_nq));
	reg dff49_l1 = 1'h0, dff49_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~dff51_q)
			dff49_l1 <= 1'h0;
		else if (~VCLK)
			dff49_l1 <= w279;
		if (~dff51_q)
			dff49_l2 <= 1'h0;
		else if (VCLK)
			dff49_l2 <= dff49_l1;
	end
	assign dff49_q = dff49_l2;
	assign dff49_nq = ~dff49_l2;

	// ym_sdffr dff50(.MCLK(MCLK), .clk(~VCLK), .val(w322), .reset(w9), .q(dff50_q), .nq(dff50_nq));
	reg dff50_l1 = 1'h0, dff50_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~w9)
			dff50_l1 <= 1'h0;
		else if (VCLK)
			dff50_l1 <= w322;
		if (~w9)
			dff50_l2 <= 1'h0;
		else if (~VCLK)
			dff50_l2 <= dff50_l1;
	end
	assign dff50_q = dff50_l2;
	assign dff50_nq = ~dff50_l2;

	// ym_sdffr dff51(.MCLK(MCLK), .clk(w279), .val(w336), .reset(w299), .q(dff51_q));
	reg dff51_l1 = 1'h0, dff51_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~w299)
			dff51_l1 <= 1'h0;
		else if (~w279)
			dff51_l1 <= w336;
		if (~w299)
			dff51_l2 <= 1'h0;
		else if (w279)
			dff51_l2 <= dff51_l1;
	end
	assign dff51_q = dff51_l2;

	
	assign w325 = CAS0 & dff62_q;
	assign w321 = dff61_nq & OE0;
	assign w326 = w321 | w325;
	assign w300 = ~(w326 & (dff49_nq | dff50_q));
	assign w314 = ~w300;
	assign NOE = w314;
	assign EOE = ~(~w314 & M3);
	
	assign w322 = dff62_q;
	
	assign w342 = dff49_q;
	
	// ym_sdffr dff61(.MCLK(MCLK), .clk(~VCLK), .val(w342), .reset(dff51_q), .q(dff61_q), .nq(dff61_nq));
	reg dff61_l1 = 1'h0, dff61_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~dff51_q)
			dff61_l1 <= 1'h0;
		else if (VCLK)
			dff61_l1 <= w342;
		if (~dff51_q)
			dff61_l2 <= 1'h0;
		else if (~VCLK)
			dff61_l2 <= dff61_l1;
	end
	assign dff61_q = dff61_l2;
	assign dff61_nq = ~dff61_l2;

	
	// ym_sdffr dff62(.MCLK(MCLK), .clk(VCLK), .val(dff61_q), .reset(dff51_q), .q(dff62_q));
	reg dff62_l1 = 1'h0, dff62_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~dff51_q)
			dff62_l1 <= 1'h0;
		else if (~VCLK)
			dff62_l1 <= dff61_q;
		if (~dff51_q)
			dff62_l2 <= 1'h0;
		else if (VCLK)
			dff62_l2 <= dff62_l1;
	end
	assign dff62_q = dff62_l2;

	
	// delays
	
	wire d1_out;
	wire d2_out;
	wire d3_out;
	wire d4_out;
	wire d5_out;
	wire d6_out;
	wire d7_out;
	wire d8_out;
	
	// ym_delaychain #(.DELAY_CNT(1)) d1(.MCLK(MCLK), .inp(M1), .outp(d1_out));
	reg [0:0] d1_dl = 1'h0;
	always @(posedge MCLK)
		d1_dl <= M1;
	assign d1_out = d1_dl[0];

	// ym_delaychain #(.DELAY_CNT(1)) d2(.MCLK(MCLK), .inp(w188), .outp(d2_out));
	reg [0:0] d2_dl = 1'h0;
	always @(posedge MCLK)
		d2_dl <= w188;
	assign d2_out = d2_dl[0];

	// ym_delaychain #(.DELAY_CNT(7)) d3(.MCLK(MCLK), .inp(w254), .outp(d3_out));
	reg [6:0] d3_dl = 7'h0;
	always @(posedge MCLK)
		d3_dl <= { d3_dl[5:0], w254 };
	assign d3_out = d3_dl[6];

	// ym_delaychain #(.DELAY_CNT(1)) d4(.MCLK(MCLK), .inp(w113), .outp(d4_out));
	reg [0:0] d4_dl = 1'h0;
	always @(posedge MCLK)
		d4_dl <= w113;
	assign d4_out = d4_dl[0];

	// ym_delaychain #(.DELAY_CNT(2)) d5(.MCLK(MCLK), .inp(w271), .outp(d5_out));
	reg [1:0] d5_dl = 2'h0;
	always @(posedge MCLK)
		d5_dl <= { d5_dl[0:0], w271 };
	assign d5_out = d5_dl[1];

	// ym_delaychain #(.DELAY_CNT(6)) d6(.MCLK(MCLK), .inp(w238), .outp(d6_out));
	reg [5:0] d6_dl = 6'h0;
	always @(posedge MCLK)
		d6_dl <= { d6_dl[4:0], w238 };
	assign d6_out = d6_dl[5];

	// ym_delaychain #(.DELAY_CNT(6)) d7(.MCLK(MCLK), .inp(w223), .outp(d7_out));
	reg [5:0] d7_dl = 6'h0;
	always @(posedge MCLK)
		d7_dl <= { d7_dl[4:0], w223 };
	assign d7_out = d7_dl[5];

	// ym_delaychain #(.DELAY_CNT(1)) d8(.MCLK(MCLK), .inp(M3), .outp(d8_out));
	reg [0:0] d8_dl = 1'h0;
	always @(posedge MCLK)
		d8_dl <= M3;
	assign d8_out = d8_dl[0];

	
	// 
	
	assign w143 = ~M3 | w220 | ~ZA_i[15];
	assign w185 = w86 | w220;
	assign w188 = w185 & w143;
	// ym_sdff dff34(.MCLK(MCLK), .clk(ZCLK), .val(d2_out), .q(dff34_q));
	reg dff34_l1 = 1'h0, dff34_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~ZCLK)
			dff34_l1 <= d2_out;
		else
			dff34_l2 <= dff34_l1;
	end
	assign dff34_q = dff34_l2;

	assign w182 = w188 & dff34_q;
	assign w255 = ~(DTACK_i | w79);
	assign w258 = ~(w255 | pal_trap | w182);
	assign WAIT_o = ~w258;
	assign w78 = ~w79 | w182 | ~sres;
	assign w79 = dff21_q | w182 | ~sres;
	// ym_sdff dff10(.MCLK(MCLK), .clk(VCLK), .val(w78), .q(dff10_q));
	reg dff10_l1 = 1'h0, dff10_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff10_l1 <= w78;
		else
			dff10_l2 <= dff10_l1;
	end
	assign dff10_q = dff10_l2;

	assign BR = dff10_q;
	// ym_sdff dff28(.MCLK(MCLK), .clk(VCLK), .val(w79), .q(dff28_q));
	reg dff28_l1 = 1'h0, dff28_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff28_l1 <= w79;
		else
			dff28_l2 <= dff28_l1;
	end
	assign dff28_q = dff28_l2;

	assign w111 = dff28_q | w182;
	// ym_sdff dff22(.MCLK(MCLK), .clk(VCLK), .val(w111), .q(dff22_q));
	reg dff22_l1 = 1'h0, dff22_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff22_l1 <= w111;
		else
			dff22_l2 <= dff22_l1;
	end
	assign dff22_q = dff22_l2;

	assign w77 = dff22_q | w182;
	// ym_sdff dff18(.MCLK(MCLK), .clk(VCLK), .val(w77), .q(dff18_q));
	reg dff18_l1 = 1'h0, dff18_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff18_l1 <= w77;
		else
			dff18_l2 <= dff18_l1;
	end
	assign dff18_q = dff18_l2;

	assign w50 = w77 | ZRD_i;
	assign w51 = dff18_q | ZWR_i;
	assign w53 = w50 & w51;
	assign UDS_o = w53 | ZA0_i;
	assign LDS_o = w53 | ~ZA0_i;
	assign AS_o = w77;
	assign w149 = ~(test | pal_trap | w146);
	assign w76 = ~sres | dff21_q;
	assign ztov = w76 & M3;
	assign w106 = w76;
	assign w175 = ~AS_i;
	assign w176 = ~BGACK_i;
	assign w174 = w175 | w176 | w182 | BG;
	assign w178 = w174 & w79;
	// ym_sdff dff21(.MCLK(MCLK), .clk(~VCLK), .val(w178), .q(dff21_q));
	reg dff21_l1 = 1'h0, dff21_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (VCLK)
			dff21_l1 <= w178;
		else
			dff21_l2 <= dff21_l1;
	end
	assign dff21_q = dff21_l2;

	assign w146 = w76;
	assign w268 = ~(test | pal_trap | w146);
	assign RW_d = w146 | test;
	assign strobe_dir = ~w268;
	assign BGACK_o = ~w149;
	
	reg w45_mem;
	
	assign w45 = w46 & ztov;
	assign w46 = w45_mem | BGACK_i;
	
	always @(posedge MCLK)
	begin
		w45_mem <= w45;
	end
	
	assign w48 = ~w45;
	
	assign w163 = vd8 | mreq_in | va22_in | M3;
	assign w68 = ~(vd8 | w163);
	assign VDPM = ~w68;
	
	assign w16 = ~(dff33_nq | w346);
	// ym_sdffr dff60(.MCLK(MCLK), .clk(~w16), .val(dff69_q), .reset(sres_syncv_q), .q(dff60_q));
	reg dff60_l1 = 1'h0, dff60_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~sres_syncv_q)
			dff60_l1 <= 1'h0;
		else if (w16)
			dff60_l1 <= dff69_q;
		if (~sres_syncv_q)
			dff60_l2 <= 1'h0;
		else if (~w16)
			dff60_l2 <= dff60_l1;
	end
	assign dff60_q = dff60_l2;

	assign w334 = ~(dff60_q | dff69_nq);
	
	assign w337 = ~WRES;
	
	// ym_sdffr dff68(.MCLK(MCLK), .clk(~w16), .val(dff68_nq), .reset(~sres_syncv_nq), .q(dff68_q), .nq(dff68_nq));
	reg dff68_l1 = 1'h0, dff68_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (sres_syncv_nq)
			dff68_l1 <= 1'h0;
		else if (w16)
			dff68_l1 <= dff68_nq;
		if (sres_syncv_nq)
			dff68_l2 <= 1'h0;
		else if (~w16)
			dff68_l2 <= dff68_l1;
	end
	assign dff68_q = dff68_l2;
	assign dff68_nq = ~dff68_l2;

	// ym_sdffr dff71(.MCLK(MCLK), .clk(~dff68_q), .val(dff71_nq), .reset(~sres_syncv_nq), .q(dff71_q), .nq(dff71_nq));
	reg dff71_l1 = 1'h0, dff71_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (sres_syncv_nq)
			dff71_l1 <= 1'h0;
		else if (dff68_q)
			dff71_l1 <= dff71_nq;
		if (sres_syncv_nq)
			dff71_l2 <= 1'h0;
		else if (~dff68_q)
			dff71_l2 <= dff71_l1;
	end
	assign dff71_q = dff71_l2;
	assign dff71_nq = ~dff71_l2;

	// ym_sdffr dff72(.MCLK(MCLK), .clk(~dff71_q), .val(dff72_nq), .reset(~sres_syncv_nq), .q(dff72_q), .nq(dff72_nq));
	reg dff72_l1 = 1'h0, dff72_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (sres_syncv_nq)
			dff72_l1 <= 1'h0;
		else if (dff71_q)
			dff72_l1 <= dff72_nq;
		if (sres_syncv_nq)
			dff72_l2 <= 1'h0;
		else if (~dff71_q)
			dff72_l2 <= dff72_l1;
	end
	assign dff72_q = dff72_l2;
	assign dff72_nq = ~dff72_l2;

	// ym_sdffr dff76(.MCLK(MCLK), .clk(~dff72_q), .val(dff76_nq), .reset(~sres_syncv_nq), .q(dff76_q), .nq(dff76_nq));
	reg dff76_l1 = 1'h0, dff76_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (sres_syncv_nq)
			dff76_l1 <= 1'h0;
		else if (dff72_q)
			dff76_l1 <= dff76_nq;
		if (sres_syncv_nq)
			dff76_l2 <= 1'h0;
		else if (~dff72_q)
			dff76_l2 <= dff76_l1;
	end
	assign dff76_q = dff76_l2;
	assign dff76_nq = ~dff76_l2;

	assign w362 = w363 | dff76_q;
	// ym_sdffr dff63(.MCLK(MCLK), .clk(~w362), .val(dff63_nq), .reset(~sres_syncv_nq), .q(dff63_q), .nq(dff63_nq));
	reg dff63_l1 = 1'h0, dff63_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (sres_syncv_nq)
			dff63_l1 <= 1'h0;
		else if (w362)
			dff63_l1 <= dff63_nq;
		if (sres_syncv_nq)
			dff63_l2 <= 1'h0;
		else if (~w362)
			dff63_l2 <= dff63_l1;
	end
	assign dff63_q = dff63_l2;
	assign dff63_nq = ~dff63_l2;

	// ym_sdffr dff52(.MCLK(MCLK), .clk(~dff63_q), .val(dff52_nq), .reset(~sres_syncv_nq), .q(dff52_q), .nq(dff52_nq));
	reg dff52_l1 = 1'h0, dff52_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (sres_syncv_nq)
			dff52_l1 <= 1'h0;
		else if (dff63_q)
			dff52_l1 <= dff52_nq;
		if (sres_syncv_nq)
			dff52_l2 <= 1'h0;
		else if (~dff63_q)
			dff52_l2 <= dff52_l1;
	end
	assign dff52_q = dff52_l2;
	assign dff52_nq = ~dff52_l2;

	// ym_sdffr dff65(.MCLK(MCLK), .clk(~dff52_q), .val(dff65_nq), .reset(~sres_syncv_nq), .q(dff65_q), .nq(dff65_nq));
	reg dff65_l1 = 1'h0, dff65_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (sres_syncv_nq)
			dff65_l1 <= 1'h0;
		else if (dff52_q)
			dff65_l1 <= dff65_nq;
		if (sres_syncv_nq)
			dff65_l2 <= 1'h0;
		else if (~dff52_q)
			dff65_l2 <= dff65_l1;
	end
	assign dff65_q = dff65_l2;
	assign dff65_nq = ~dff65_l2;

	// ym_sdffr dff67(.MCLK(MCLK), .clk(~dff65_q), .val(dff67_nq), .reset(~sres_syncv_nq), .q(dff67_q), .nq(dff67_nq));
	reg dff67_l1 = 1'h0, dff67_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (sres_syncv_nq)
			dff67_l1 <= 1'h0;
		else if (dff65_q)
			dff67_l1 <= dff67_nq;
		if (sres_syncv_nq)
			dff67_l2 <= 1'h0;
		else if (~dff65_q)
			dff67_l2 <= dff67_l1;
	end
	assign dff67_q = dff67_l2;
	assign dff67_nq = ~dff67_l2;

	// ym_sdffr dff74(.MCLK(MCLK), .clk(~dff67_q), .val(dff74_nq), .reset(sres_syncv_q), .q(dff74_q), .nq(dff74_nq));
	reg dff74_l1 = 1'h0, dff74_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~sres_syncv_q)
			dff74_l1 <= 1'h0;
		else if (dff67_q)
			dff74_l1 <= dff74_nq;
		if (~sres_syncv_q)
			dff74_l2 <= 1'h0;
		else if (~dff67_q)
			dff74_l2 <= dff74_l1;
	end
	assign dff74_q = dff74_l2;
	assign dff74_nq = ~dff74_l2;

	
	// ym_sdffs nmi(.MCLK(MCLK), .clk(dff74_q), .val(va23_in), .set(w332), .q(nmi_q));
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg nmi_l1, nmi_l2;
	always @(posedge MCLK)
	begin
		if (~dff74_q)
			nmi_l1 <= va23_in;
		else if (~w332)
			nmi_l1 <= 1'h1;
		if (~w332)
			nmi_l2 <= 1'h1;
		else if (dff74_q)
			nmi_l2 <= nmi_l1;
	end
	assign nmi_q = nmi_l2;

	// ym_sdffr dff57(.MCLK(MCLK), .clk(dff74_q), .val(sres_syncv_q), .reset(sres_syncv_q), .q(dff57_q));
	reg dff57_l1 = 1'h0, dff57_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~sres_syncv_q)
			dff57_l1 <= 1'h0;
		else if (~dff74_q)
			dff57_l1 <= sres_syncv_q;
		if (~sres_syncv_q)
			dff57_l2 <= 1'h0;
		else if (dff74_q)
			dff57_l2 <= dff57_l1;
	end
	assign dff57_q = dff57_l2;

	// ym_sdffr dff58(.MCLK(MCLK), .clk(dff74_q), .val(dff57_q), .reset(sres_syncv_q), .nq(dff58_nq));
	reg dff58_l1 = 1'h0, dff58_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~sres_syncv_q)
			dff58_l1 <= 1'h0;
		else if (~dff74_q)
			dff58_l1 <= dff57_q;
		if (~sres_syncv_q)
			dff58_l2 <= 1'h0;
		else if (dff74_q)
			dff58_l2 <= dff58_l1;
	end
	assign dff58_nq = ~dff58_l2;

	// ym_sdffr dff69(.MCLK(MCLK), .clk(dff74_q), .val(w337), .reset(sres_syncv_q), .q(dff69_q), .nq(dff69_nq));
	reg dff69_l1 = 1'h0, dff69_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~sres_syncv_q)
			dff69_l1 <= 1'h0;
		else if (~dff74_q)
			dff69_l1 <= w337;
		if (~sres_syncv_q)
			dff69_l2 <= 1'h0;
		else if (dff74_q)
			dff69_l2 <= dff69_l1;
	end
	assign dff69_q = dff69_l2;
	assign dff69_nq = ~dff69_l2;

	assign w328 = ~(dff58_nq | w334);
	
	assign w113 = IORQ | M3 | ~M1;
	// ym_sdff dff29(.MCLK(MCLK), .clk(ZCLK), .val(d4_out), .q(dff29_q));
	reg dff29_l1 = 1'h0, dff29_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~ZCLK)
			dff29_l1 <= d4_out;
		else
			dff29_l2 <= dff29_l1;
	end
	assign dff29_q = dff29_l2;

	assign w112 = w113 & dff29_q;
	
	// ym_sdff dff27(.MCLK(MCLK), .clk(ZCLK), .val(d1_out), .q(dff27_q));
	reg dff27_l1 = 1'h0, dff27_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~ZCLK)
			dff27_l1 <= d1_out;
		else
			dff27_l2 <= dff27_l1;
	end
	assign dff27_q = dff27_l2;

	// ym_sdff dff30(.MCLK(MCLK), .clk(ZCLK), .val(dff27_q), .q(dff30_q));
	reg dff30_l1 = 1'h0, dff30_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~ZCLK)
			dff30_l1 <= dff27_q;
		else
			dff30_l2 <= dff30_l1;
	end
	assign dff30_q = dff30_l2;

	assign w199 = dff30_q;
	assign w207 = w199;
	// ym_sdff dff44(.MCLK(MCLK), .clk(~ZCLK), .val(w207), .q(dff44_q), .nq(dff44_nq));
	reg dff44_l1 = 1'h0, dff44_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (ZCLK)
			dff44_l1 <= w207;
		else
			dff44_l2 <= dff44_l1;
	end
	assign dff44_q = dff44_l2;
	assign dff44_nq = ~dff44_l2;

	
	assign w220 = mreq_in | dff44_nq;
	
	assign NMI = nmi_q;
	
	assign w316 = ~(~M3 | dff70_q);
	
	assign w320 = ~(~M3 | dff44_q | mreq_in);
	assign w318 = w316 | w320;
	assign REF = ~w318;
	
	assign w63 = ~(w99 & ~w122 & ~UDS_i);
	assign w12 = test | ~RW_i | w63;
	assign w36 = w63 | RW_i;
	// ym_sdffr zbr(.MCLK(MCLK), .clk(w36), .val(vd8), .reset(sres_syncv_q), .nq(zbr_nq));
	reg zbr_l1 = 1'h0, zbr_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~sres_syncv_q)
			zbr_l1 <= 1'h0;
		else if (~w36)
			zbr_l1 <= vd8;
		if (~sres_syncv_q)
			zbr_l2 <= 1'h0;
		else if (w36)
			zbr_l2 <= zbr_l1;
	end
	assign zbr_nq = ~zbr_l2;

	assign w33 = ZBAK;
	assign w34 = w33 | zbr_nq;
	assign ZBR = zbr_nq;
	
	assign w257 = ~(LDS_i & UDS_i);
	// ym_sdff dff59(.MCLK(MCLK), .clk(VCLK), .val(w257), .q(dff59_q));
	reg dff59_l1 = 1'h0, dff59_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff59_l1 <= w257;
		else
			dff59_l2 <= dff59_l1;
	end
	assign dff59_q = dff59_l2;

	assign w331 = w257 & dff66_nq & dff59_q;
	assign MREQ_o = ~w331;
	
	assign w66 = w119 | AS_i;
	
	assign w354 = ~(w339 & dff70_q);
	// ym_sdff dff75(.MCLK(MCLK), .clk(~VCLK), .val(w354), .nq(dff75_nq));
	reg dff75_l1 = 1'h0, dff75_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (VCLK)
			dff75_l1 <= w354;
		else
			dff75_l2 <= dff75_l1;
	end
	assign dff75_nq = ~dff75_l2;

	assign w348 = ~(w339 & dff70_q & dff75_nq);
	// ym_sdff dff66(.MCLK(MCLK), .clk(~VCLK), .val(w348), .q(dff66_q), .nq(dff66_nq));
	reg dff66_l1 = 1'h0, dff66_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (VCLK)
			dff66_l1 <= w348;
		else
			dff66_l2 <= dff66_l1;
	end
	assign dff66_q = dff66_l2;
	assign dff66_nq = ~dff66_l2;

	// ym_sdff dff73(.MCLK(MCLK), .clk(VCLK), .val(AS_i), .q(dff73_q));
	reg dff73_l1 = 1'h0, dff73_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff73_l1 <= AS_i;
		else
			dff73_l2 <= dff73_l1;
	end
	assign dff73_q = dff73_l2;

	assign w344 = dff66_q | AS_i | dff73_q;
	// ym_sdff dff64(.MCLK(MCLK), .clk(VCLK), .val(w344), .nq(dff64_nq));
	reg dff64_l1 = 1'h0, dff64_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff64_l1 <= w344;
		else
			dff64_l2 <= dff64_l1;
	end
	assign dff64_nq = ~dff64_l2;

	assign w341 = ~(dff64_nq & w336);
	assign w134 = w66 | w341;
	
	assign vtoz = w119 | test | w33;
	
	assign w308 = ~(w287 | w343);
	assign w307 = ~(w308 | sres_syncv_nq);
	assign w272 = ~(dff47_q | AS_i);
	assign w273 = ~(w272 | w307);
	assign w164 = ~(w34 & w166);
	// ym_sdffs dff47(.MCLK(MCLK), .clk(~VCLK), .val(w273), .set(w164), .q(dff47_q), .nq(dff47_nq));
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg dff47_l1, dff47_l2;
	always @(posedge MCLK)
	begin
		if (VCLK)
			dff47_l1 <= w273;
		else if (~w164)
			dff47_l1 <= 1'h1;
		if (~w164)
			dff47_l2 <= 1'h1;
		else if (~VCLK)
			dff47_l2 <= dff47_l1;
	end
	assign dff47_q = dff47_l2;
	assign dff47_nq = ~dff47_l2;

	assign w339 = ~(AS_i & dff47_nq);
	// ym_sdff dff70(.MCLK(MCLK), .clk(~VCLK), .val(w339), .q(dff70_q));
	reg dff70_l1 = 1'h0, dff70_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (VCLK)
			dff70_l1 <= w339;
		else
			dff70_l2 <= dff70_l1;
	end
	assign dff70_q = dff70_l2;

	
	assign w249 = ~(ztov & fc11);
	assign INTAK = w249;
	
	assign VPA = AS_i | w249;
	
	assign w73 = sres_syncv_q & M3;
	
	// ym_sdffr dff26(.MCLK(MCLK), .clk(w97), .val(vd8), .reset(sres_syncv_q), .nq(dff26_nq));
	reg dff26_l1 = 1'h0, dff26_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~sres_syncv_q)
			dff26_l1 <= 1'h0;
		else if (~w97)
			dff26_l1 <= vd8;
		if (~sres_syncv_q)
			dff26_l2 <= 1'h0;
		else if (w97)
			dff26_l2 <= dff26_l1;
	end
	assign dff26_nq = ~dff26_l2;

	assign w274 = ~CAS0;
	// ym_sdffs dff45(.MCLK(MCLK), .clk(w274), .val(va23_in), .set(~w223), .q(dff45_q));
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg dff45_l1, dff45_l2;
	always @(posedge MCLK)
	begin
		if (~w274)
			dff45_l1 <= va23_in;
		else if (w223)
			dff45_l1 <= 1'h1;
		if (w223)
			dff45_l2 <= 1'h1;
		else if (w274)
			dff45_l2 <= dff45_l1;
	end
	assign dff45_q = dff45_l2;

	assign w269 = dff45_q & va23_in & w274;
	assign w248 = w223 | w269;
	assign w208 = dff26_nq ? w248 : w254;
	assign w202 = w208 | ~va22_cart;
	assign w170 = dff26_nq | d5_out;
	assign w167 = w170 & w202;
	assign w211 = ~M3 | AS_i | va23_in;
	assign w72 = dff15_nq | w43;
	assign w132 = w72 | w211;
	assign w69 = ~(w44 | dff12_nq);
	assign w168 = ~(w69 | dff26_nq);
	assign w169 = w168 | w211 | ~va22_cart;
	
	// ym_sdffr dff25(.MCLK(MCLK), .clk(~VCLK), .val(dff12_nq), .reset(w73), .q(dff25_q));
	reg dff25_l1 = 1'h0, dff25_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~w73)
			dff25_l1 <= 1'h0;
		else if (VCLK)
			dff25_l1 <= dff12_nq;
		if (~w73)
			dff25_l2 <= 1'h0;
		else if (~VCLK)
			dff25_l2 <= dff25_l1;
	end
	assign dff25_q = dff25_l2;

	assign w101 = ~(dff20_nq | dff25_q);
	assign w173 = w101 | dff26_nq;
	assign w171 = za15_in | w220 | M3;
	assign w172 = ~(w169 & w167 & w171 & w173);
	assign CE0 = ~w172;
	
	assign w301 = ~(w223 & d7_out);
	assign w298 = w301 & va23_in;
	// ym_sdffs dff46(.MCLK(MCLK), .clk(w274), .val(dff46_nq), .set(w298), .q(dff46_q), .nq(dff46_nq));
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg dff46_l1, dff46_l2;
	always @(posedge MCLK)
	begin
		if (~w274)
			dff46_l1 <= dff46_nq;
		else if (~w298)
			dff46_l1 <= 1'h1;
		if (~w298)
			dff46_l2 <= 1'h1;
		else if (w274)
			dff46_l2 <= dff46_l1;
	end
	assign dff46_q = dff46_l2;
	assign dff46_nq = ~dff46_l2;

	assign w271 = dff46_q | d6_out;
	
	assign w254 = w223 | va23_in;
	assign w206 = ~va21_in | va22_cart | w254;
	assign w238 = CAS0 | w223;
	assign w204 = ~(~w211 & w69 & ~va22_cart & va21_in);
	assign w197 = w206 & d5_out;
	assign w198 = ~(w197 & w101 & w204);
	assign RAS2 = ~w198;
	
	assign w234 = va22_cart | va21_in | w211;
	assign va22_cart = ~(va22_in ^ CART);
	assign w232 = va22_cart | w248 | va21_in;
	assign w235 = ~(w234 & w232);
	assign ROM = ~w235;
	assign w107 = ~(ZA_i[15:14] == 2'h2 & ~w220 & ~M3);
	assign w102 = ~(w70 & w107 & w238);
	assign CAS2 = ~w102;
	
	assign w64 = ~(w43 & d3_out);
	assign ASEL = ~w64;
	
	assign w59 = ~M3 | AS_i;
	assign w54 = ~(dff23_q & va23_in);
	assign w84 = ~(dff23_nq & dff33_nq & w356);
	assign w58 = w54 & w84;
	// ym_sdffs dff17(.MCLK(MCLK), .clk(VCLK), .val(w58), .set(w73), .q(dff17_q));
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg dff17_l1, dff17_l2;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff17_l1 <= w58;
		else if (~w73)
			dff17_l1 <= 1'h1;
		if (~w73)
			dff17_l2 <= 1'h1;
		else if (VCLK)
			dff17_l2 <= dff17_l1;
	end
	assign dff17_q = dff17_l2;

	assign w49 = dff17_q;
	assign w74 = w49;
	// ym_sdffs dff20(.MCLK(MCLK), .clk(~VCLK), .val(w74), .set(w73), .q(dff20_q), .nq(dff20_nq));
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg dff20_l1, dff20_l2;
	always @(posedge MCLK)
	begin
		if (VCLK)
			dff20_l1 <= w74;
		else if (~w73)
			dff20_l1 <= 1'h1;
		if (~w73)
			dff20_l2 <= 1'h1;
		else if (~VCLK)
			dff20_l2 <= dff20_l1;
	end
	assign dff20_q = dff20_l2;
	assign dff20_nq = ~dff20_l2;

	assign w71 = dff20_q & w74;
	
	// ym_sdffs dff19(.MCLK(MCLK), .clk(~VCLK), .val(w71), .set(w73), .q(dff19_q));
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg dff19_l1, dff19_l2;
	always @(posedge MCLK)
	begin
		if (VCLK)
			dff19_l1 <= w71;
		else if (~w73)
			dff19_l1 <= 1'h1;
		if (~w73)
			dff19_l2 <= 1'h1;
		else if (~VCLK)
			dff19_l2 <= dff19_l1;
	end
	assign dff19_q = dff19_l2;

	assign w42 = ~(dff19_q & w71);
	assign w44 = w42 | va23_in | w59;
	// ym_sdff dff16(.MCLK(MCLK), .clk(VCLK), .val(w44), .q(dff16_q));
	reg dff16_l1 = 1'h0, dff16_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff16_l1 <= w44;
		else
			dff16_l2 <= dff16_l1;
	end
	assign dff16_q = dff16_l2;

	assign w43 = w44 | dff16_q;
	// ym_sdff dff11(.MCLK(MCLK), .clk(~VCLK), .val(w43), .q(dff11_q));
	reg dff11_l1 = 1'h0, dff11_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (VCLK)
			dff11_l1 <= w43;
		else
			dff11_l2 <= dff11_l1;
	end
	assign dff11_q = dff11_l2;

	assign w27 = dff11_q | w44;
	
	assign w41 = w27 | dff15_q;
	// ym_sdff dff12(.MCLK(MCLK), .clk(~VCLK), .val(w41), .q(dff12_q), .nq(dff12_nq));
	reg dff12_l1 = 1'h0, dff12_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (VCLK)
			dff12_l1 <= w41;
		else
			dff12_l2 <= dff12_l1;
	end
	assign dff12_q = dff12_l2;
	assign dff12_nq = ~dff12_l2;

	assign w26 = ~(dff15_nq & dff12_q);
	assign w83 = dff23_nq | va23_in;
	assign w40 = w26 & w83;
	// ym_sdffs dff15(.MCLK(MCLK), .clk(VCLK), .val(w40), .set(w73), .q(dff15_q), .nq(dff15_nq));
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg dff15_l1, dff15_l2;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff15_l1 <= w40;
		else if (~w73)
			dff15_l1 <= 1'h1;
		if (~w73)
			dff15_l2 <= 1'h1;
		else if (VCLK)
			dff15_l2 <= dff15_l1;
	end
	assign dff15_q = dff15_l2;
	assign dff15_nq = ~dff15_l2;

	
	assign w70 = w27 & w71;
	
	
	assign w286 = ~(w287 | sres_syncv_nq);
	assign w289 = w286;
	assign w372 = w289 & 1'h1 & 1'h1;
	
	// ym_scnt_bit dff78(.MCLK(MCLK), .clk(VCLK), .load(w289), .val(1'h0), .cin(w372), .rst(1'h1), .nq(dff78_nq), .cout(dff78_cout));
	reg dff78_l1 = 1'h0, dff78_l2 = 1'h0;
	wire [1:0] dff78_sum = { 1'h0, dff78_l2 } + { 1'h0, w372 };
	always @(posedge MCLK)
	begin
		if (~1'h1)
		begin
			dff78_l1 <= 1'h0;
			dff78_l2 <= 1'h0;
		end
		else
		begin
			if (~VCLK)
				dff78_l1 <= ~w289 ? 1'h0 : dff78_sum[0];
			else
				dff78_l2 <= dff78_l1;
		end
	end
	assign dff78_cout = dff78_sum[1];
	assign dff78_nq = ~dff78_l2;

	// ym_scnt_bit dff80(.MCLK(MCLK), .clk(VCLK), .load(w289), .val(1'h0), .cin(dff78_cout), .rst(1'h1), .nq(dff80_nq), .cout(dff80_cout));
	reg dff80_l1 = 1'h0, dff80_l2 = 1'h0;
	wire [1:0] dff80_sum = { 1'h0, dff80_l2 } + { 1'h0, dff78_cout };
	always @(posedge MCLK)
	begin
		if (~1'h1)
		begin
			dff80_l1 <= 1'h0;
			dff80_l2 <= 1'h0;
		end
		else
		begin
			if (~VCLK)
				dff80_l1 <= ~w289 ? 1'h0 : dff80_sum[0];
			else
				dff80_l2 <= dff80_l1;
		end
	end
	assign dff80_cout = dff80_sum[1];
	assign dff80_nq = ~dff80_l2;

	// ym_scnt_bit dff79(.MCLK(MCLK), .clk(VCLK), .load(w289), .val(1'h0), .cin(dff80_cout), .rst(1'h1), .nq(dff79_nq), .cout(dff79_cout));
	reg dff79_l1 = 1'h0, dff79_l2 = 1'h0;
	wire [1:0] dff79_sum = { 1'h0, dff79_l2 } + { 1'h0, dff80_cout };
	always @(posedge MCLK)
	begin
		if (~1'h1)
		begin
			dff79_l1 <= 1'h0;
			dff79_l2 <= 1'h0;
		end
		else
		begin
			if (~VCLK)
				dff79_l1 <= ~w289 ? 1'h0 : dff79_sum[0];
			else
				dff79_l2 <= dff79_l1;
		end
	end
	assign dff79_cout = dff79_sum[1];
	assign dff79_nq = ~dff79_l2;

	// ym_scnt_bit dff77(.MCLK(MCLK), .clk(VCLK), .load(w289), .val(1'h0), .cin(dff79_cout), .rst(1'h1), .nq(dff77_nq), .cout(dff77_cout));
	reg dff77_l1 = 1'h0, dff77_l2 = 1'h0;
	wire [1:0] dff77_sum = { 1'h0, dff77_l2 } + { 1'h0, dff79_cout };
	always @(posedge MCLK)
	begin
		if (~1'h1)
		begin
			dff77_l1 <= 1'h0;
			dff77_l2 <= 1'h0;
		end
		else
		begin
			if (~VCLK)
				dff77_l1 <= ~w289 ? 1'h0 : dff77_sum[0];
			else
				dff77_l2 <= dff77_l1;
		end
	end
	assign dff77_cout = dff77_sum[1];
	assign dff77_nq = ~dff77_l2;

	assign w374 = ~(dff77_nq | dff78_nq | dff79_nq | dff80_nq);
	assign w356 = w374 & 1'h1;
	
	assign w266 = w289 & w356 & w356;
	// ym_scnt_bit dff48(.MCLK(MCLK), .clk(VCLK), .load(w289), .val(1'h0), .cin(w266), .rst(1'h1), .nq(dff48_nq), .cout(dff48_cout));
	reg dff48_l1 = 1'h0, dff48_l2 = 1'h0;
	wire [1:0] dff48_sum = { 1'h0, dff48_l2 } + { 1'h0, w266 };
	always @(posedge MCLK)
	begin
		if (~1'h1)
		begin
			dff48_l1 <= 1'h0;
			dff48_l2 <= 1'h0;
		end
		else
		begin
			if (~VCLK)
				dff48_l1 <= ~w289 ? 1'h0 : dff48_sum[0];
			else
				dff48_l2 <= dff48_l1;
		end
	end
	assign dff48_cout = dff48_sum[1];
	assign dff48_nq = ~dff48_l2;

	// ym_scnt_bit dff54(.MCLK(MCLK), .clk(VCLK), .load(w289), .val(1'h0), .cin(dff48_cout), .rst(1'h1), .nq(dff54_nq), .cout(dff54_cout));
	reg dff54_l1 = 1'h0, dff54_l2 = 1'h0;
	wire [1:0] dff54_sum = { 1'h0, dff54_l2 } + { 1'h0, dff48_cout };
	always @(posedge MCLK)
	begin
		if (~1'h1)
		begin
			dff54_l1 <= 1'h0;
			dff54_l2 <= 1'h0;
		end
		else
		begin
			if (~VCLK)
				dff54_l1 <= ~w289 ? 1'h0 : dff54_sum[0];
			else
				dff54_l2 <= dff54_l1;
		end
	end
	assign dff54_cout = dff54_sum[1];
	assign dff54_nq = ~dff54_l2;

	// ym_scnt_bit dff53(.MCLK(MCLK), .clk(VCLK), .load(w289), .val(1'h0), .cin(dff54_cout), .rst(1'h1), .nq(dff53_nq), .cout(dff53_cout));
	reg dff53_l1 = 1'h0, dff53_l2 = 1'h0;
	wire [1:0] dff53_sum = { 1'h0, dff53_l2 } + { 1'h0, dff54_cout };
	always @(posedge MCLK)
	begin
		if (~1'h1)
		begin
			dff53_l1 <= 1'h0;
			dff53_l2 <= 1'h0;
		end
		else
		begin
			if (~VCLK)
				dff53_l1 <= ~w289 ? 1'h0 : dff53_sum[0];
			else
				dff53_l2 <= dff53_l1;
		end
	end
	assign dff53_cout = dff53_sum[1];
	assign dff53_nq = ~dff53_l2;

	// ym_scnt_bit dff55(.MCLK(MCLK), .clk(VCLK), .load(w289), .val(M3), .cin(dff53_cout), .rst(1'h1), .nq(dff55_nq), .cout(dff55_cout));
	reg dff55_l1 = 1'h0, dff55_l2 = 1'h0;
	wire [1:0] dff55_sum = { 1'h0, dff55_l2 } + { 1'h0, dff53_cout };
	always @(posedge MCLK)
	begin
		if (~1'h1)
		begin
			dff55_l1 <= 1'h0;
			dff55_l2 <= 1'h0;
		end
		else
		begin
			if (~VCLK)
				dff55_l1 <= ~w289 ? M3 : dff55_sum[0];
			else
				dff55_l2 <= dff55_l1;
		end
	end
	assign dff55_cout = dff55_sum[1];
	assign dff55_nq = ~dff55_l2;

	assign w309 = ~(dff48_nq | dff53_nq | dff54_nq | dff55_nq);
	assign w287 = w309 & w356;
	
	assign w183 = ~(dff33_q | dff23_q | w356 | ~w223);
	assign w283 = ~(w183 | w287 | w343);
	// ym_sdffs dff33(.MCLK(MCLK), .clk(VCLK), .val(w283), .set(sres_syncv_q), .q(dff33_q), .nq(dff33_nq));
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg dff33_l1, dff33_l2;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff33_l1 <= w283;
		else if (~sres_syncv_q)
			dff33_l1 <= 1'h1;
		if (~sres_syncv_q)
			dff33_l2 <= 1'h1;
		else if (VCLK)
			dff33_l2 <= dff33_l1;
	end
	assign dff33_q = dff33_l2;
	assign dff33_nq = ~dff33_l2;

	// ym_sdffr dff23(.MCLK(MCLK), .clk(~w59), .val(dff33_nq), .reset(dff33_nq), .q(dff23_q), .nq(dff23_nq));
	reg dff23_l1 = 1'h0, dff23_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~dff33_nq)
			dff23_l1 <= 1'h0;
		else if (w59)
			dff23_l1 <= dff33_nq;
		if (~dff33_nq)
			dff23_l2 <= 1'h0;
		else if (~w59)
			dff23_l2 <= dff23_l1;
	end
	assign dff23_q = dff23_l2;
	assign dff23_nq = ~dff23_l2;

	
	
	assign ZRD_o = AS_i | ~RW_i;
	
	assign ZV = ztov;
	
	// ym_sdff dff13(.MCLK(MCLK), .clk(~VCLK), .val(UDS_i), .q(dff13_q));
	reg dff13_l1 = 1'h0, dff13_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (VCLK)
			dff13_l1 <= UDS_i;
		else
			dff13_l2 <= dff13_l1;
	end
	assign dff13_q = dff13_l2;

	assign w65 = ~(dff13_q & UDS_i);
	assign w31 = ~w65;
	
	assign sres = SRES;
	
	assign ZWR_o = RW_i | AS_i;
	
	assign vd8 = VD8_i;
	
	assign mreq_in = MREQ_i;
	
	assign w95 = ~(UDS_i | RW_i);
	
	assign w96 = ~(w95 & w90 & ~w122);
	
	assign w97 = ~(w95 & w91 & ~w122);
	
	assign w130 = AS_i | w129;
	assign w103 = ~(dff24_q | RW_i | w130);
	// ym_sdff dff24(.MCLK(MCLK), .clk(VCLK), .val(w103), .q(dff24_q), .nq(dff24_nq));
	reg dff24_l1 = 1'h0, dff24_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			dff24_l1 <= w103;
		else
			dff24_l2 <= dff24_l1;
	end
	assign dff24_q = dff24_l2;
	assign dff24_nq = ~dff24_l2;

	assign FDC = w130;
	assign FDWR = dff24_nq;
	
	assign w94 = w128 | AS_i;
	assign w75 = ~(w112 & w94);
	assign IO = ~w75;
	
	assign SOUND = w140;
	
	assign w126 = w124 | AS_i;
	assign TIME = w126;
	
	assign w131 = ztov | test | pal_trap;
	
	assign w137 = ~(w106 | test | pal_trap);
	
	assign w142 = ~w137;
	
	assign test = test_mode_0;
	
	// ym_sdffr dff31(.MCLK(MCLK), .clk(w96), .val(vd8), .reset(w328), .q(dff31_q));
	reg dff31_l1 = 1'h0, dff31_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~w328)
			dff31_l1 <= 1'h0;
		else if (~w96)
			dff31_l1 <= vd8;
		if (~w328)
			dff31_l2 <= 1'h0;
		else if (w96)
			dff31_l2 <= dff31_l1;
	end
	assign dff31_q = dff31_l2;

	assign w166 = M3 ? dff31_q : w328;
	
	// ym_sdff sres_syncv(.MCLK(MCLK), .clk(VCLK), .val(SRES), .q(sres_syncv_q), .nq(sres_syncv_nq));
	reg sres_syncv_l1 = 1'h0, sres_syncv_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			sres_syncv_l1 <= SRES;
		else
			sres_syncv_l2 <= sres_syncv_l1;
	end
	assign sres_syncv_q = sres_syncv_l2;
	assign sres_syncv_nq = ~sres_syncv_l2;

	
	assign RW_o = ZWR_i;
	
	assign w118 = w122 | AS_i;
	assign w133 = ~(w132 & w118 & w130 & w126 & w94 & w134);
	assign w200 = ~(w133 & w249);
	assign w222 = ~(w200 | test);
	assign DTACK_o = ~w222;
	
	assign w215 = va21_in | mreq_in;
	
	assign w223 = w48 | BGACK_i | ~M3;
	
	assign ZRES = w166;
	
	assign w336 = WAIT_i;
	
	assign w311 = ~(M3 & w328);
	assign VRES = ~w311;
	
	assign w343 = ~(~fc00 | d8_out);
	assign w363 = ~(~fc01 | d8_out);
	assign w346 = ~(~fc10 | d8_out);
	assign w332 = ~(w333 | d8_out);
	assign w333 = ~(d8_out | sres_syncv_q);
	
	assign w353 = w194;
	
	assign fc00 = ~FC1 & ~FC0;
	assign fc01 = ~FC1 & FC0;
	assign fc10 = FC1 & ~FC0;
	assign fc11 = FC1 & FC0;
	
	assign ZRAM = w136;
	
	assign va14_in = VA_i[13];
	
	assign va21_in = VA_i[20];
	
	assign va22_in = VA_i[21];

	assign va23_in = VA_i[22];
	
	assign ZA0_o = w31;
	
	assign ZA_o[15:8] = { 1'h0, VA_i[13:7] };
	
	assign VZ = vtoz;
	
	assign za15_in = ZA_i[15];
	
	// ym_sdffr #(.DATA_WIDTH(9)) z80bank(.MCLK(MCLK), .clk(w150), .val({ ZD0_i, z80bank_q[8:1] }), .reset(sres_syncv_q), .q(z80bank_q));
	reg [8:0] z80bank_l1 = 9'h0, z80bank_l2 = 9'h0;
	always @(posedge MCLK)
	begin
		if (~sres_syncv_q)
			z80bank_l1 <= 9'h0;
		else if (~w150)
			z80bank_l1 <= { ZD0_i, z80bank_q[8:1] };
		if (~sres_syncv_q)
			z80bank_l2 <= 9'h0;
		else if (w150)
			z80bank_l2 <= z80bank_l1;
	end
	assign z80bank_q = z80bank_l2;

	
	wire [15:0] va_out_t = M3 ? { w86 ? z80bank_q : 9'h180, ZA_i[14:8] } : { 3'h0, w166, IORQ, mreq_in, w215, ZA_i[15:7] };
	
	assign va_out = w86 ? va_out_t : {va_out_t[15:8], 8'h0};
	
	assign w91 = VA_i[8:7] == 2'h0;
	assign w99 = VA_i[8:7] == 2'h1;
	assign w90 = VA_i[8:7] == 2'h2;
	assign w92 = VA_i[8:7] == 2'h3;
	
	assign w194 = AS_i | LDS_i | UDS_i | VA_i[22:7] != 16'ha140;
	assign w310 = ~(VA_i[22:7] == 16'hc000 & ~AS_i);
	
	assign w119 = ~(M3 & VA_i[22:15] == 8'ha0);
	
	assign w128 = ~(M3 & VA_i[22:7] == 16'ha100);
	
	assign w122 = ~(M3 & VA_i[22:9] == 14'h2844);
	
	assign w129 = ~(M3 & VA_i[22:7] == 16'ha120);
	
	assign w124 = ~(M3 & VA_i[22:7] == 16'ha130);
	
	assign w136 = ~(ZA_i[15:14] == 2'h0 & ~w220 & M3);
	
	assign w140 = ~(ZA_i[15:13] == 3'h2 & ~w220 & M3);
	
	assign w150 = ~(M3 & ZA_i[15:8] == 8'h60 & ~ZWR_i & ~w220);
	
	assign w86 = ~(ZA_i[15:8] == 8'h7f & M3);
	
	assign IA14 = ~(M3 & va14_in);
	
	assign VA_o[22:7] = va_out;
	
	assign VD8_o = w33;
	
endmodule
