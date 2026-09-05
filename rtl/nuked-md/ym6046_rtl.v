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
 *  YM6046(FC1004) emulator.
 *  Thanks:
 *      org (ogamespec):
 *          FC1004 decap and die shot.
 *      andkorzh, HardWareMan (emu-russia):
 *          help & support.
 *
 */

/*
 * ym6046_rtl -- 1:1 synthesis-friendly representation of ym6046 (rtl/nuked-md/ym6046.v),
 * converted with the method proven on tmss (rtl/nuked-md/tmss_rtl.v, sim/tmss).
 *
 * Same two modules (ym6046_rtl, ym6046_controller_port_rtl), same port lists, same logic,
 * same storage, same MCLK (the 107.386 MHz sampling clock, md_board's MCLK2). Every `assign`
 * and every `wire x = ...` net declaration is copied verbatim from ym6046.v (same names,
 * same expressions, same order); the three controller-port instances keep their names
 * (port_a/port_b/port_c) and connections. Only the ym_lib primitive instances are replaced
 * by inline registered logic that produces the same value at every posedge MCLK. Storage
 * registers are named <instance>_<reg> after the primitive's instance name and its internal
 * register (l1/l2/mem); the primitive's output wires (q / nq / val) are kept as the original
 * wires, assigned from that storage. The one hand-written register of the die model
 * (rx_shifter_q_delay, a plain `always @(posedge MCLK)`) is copied unchanged.
 *
 * Primitive census of ym6046.v (instances in the source text; the controller port is
 * instantiated three times, so the elaborated count is top + 3 x port):
 *
 *   type          top   per port   elaborated   rule
 *   ym_slatch      0       1           3        clock-enable register (A)
 *   ym_sdff        1       1           4        master-slave pair kept (B)
 *   ym_sdffr       9      18          63        master-slave pair kept (C)
 *   ym_sdffs       1       7          22        master-slave pair kept (D)
 *   ym_sdffsr      0       2           6        master-slave pair kept (E)
 *   ym_scnt_bit    2       0           2        master-slave counter pair kept (F)
 *   (plain reg)    0       1           3        copied verbatim
 *   total         13      30         103        (42 primitive instances in the text)
 *
 * Conversion rule per primitive type. The semantics reproduced are those of ym_lib.v as
 * sampled on MCLK (every register updates at posedge MCLK, the die's internal clocks are
 * data), not idealised latch/flip-flop semantics:
 *
 *  (A) ym_slatch  (ym_lib: `mem <= en ? inp : mem` every posedge MCLK; val = mem)
 *      ->  always @(posedge MCLK) if (en) mem <= inp;
 *      The recirculating mux becomes a clock enable. Exact by construction. Initial value
 *      {W{1'h0}} kept. One instance: tx_data_sl (en = ~write_tx_data).
 *
 *  (B) ym_sdff    (ym_lib: `if (~clk) l1 <= val; else l2 <= l1;`   q = l2, nq = ~l2)
 *      ->  the two registers l1/l2 with the identical if/else (the branches are mutually
 *          exclusive in ym_lib, so they stay mutually exclusive here). Initial 0/0 kept.
 *
 *  (C) ym_sdffr   (ym_lib: `if (~reset) l1 <= 0; else if (~clk) l1 <= val;`
 *                          `if (~reset) l2 <= 0; else if (clk)  l2 <= l1;`   q = l2, nq = ~l2)
 *      ->  two registers, same reset priority. Initial 0/0 kept.
 *
 *  (D) ym_sdffs   (ym_lib, note the ASYMMETRIC set priority:
 *                          `if (~clk) l1 <= val; else if (~set) l1 <= 1;`
 *                          `if (~set) l2 <= 1;   else if (clk)  l2 <= l1;`   q = l2, nq = ~l2)
 *      ->  two registers, same priorities. ym_sdffs has NO initialiser in ym_lib.v, so none
 *          is written here either (same power-up representation for Quartus; in simulation
 *          both models start X until the first ~set / ~clk edge).
 *
 *  (E) ym_sdffsr  (ym_lib, note the two different priority orders and the output override:
 *                          `if (~reset) l1 <= 0; else if (~set) l1 <= 1; else if (~clk) l1 <= val;`
 *                          `if (~set) l2 <= 1; else if (~reset) l2 <= 0; else if (clk) l2 <= l1;`
 *                           q  = (~set & ~reset) ? 0 : l2;  nq = (~set & ~reset) ? 0 : ~l2)
 *      ->  two registers, same priorities, and the q/nq override expressions copied as they
 *          are (tx_state1_q feeds its own val and tx_state1_nq feeds tx_state2's set, so the
 *          override is functionally load-bearing). Initial 0/0 kept.
 *
 *  (F) ym_scnt_bit (ym_lib: sum = {1'h0, l2} + cin;
 *                          `if (~rst) begin l1 <= 0; l2 <= 0; end
 *                           else if (~clk) l1 <= ~load ? val : sum[W-1:0]; else l2 <= l1;`
 *                           q = l2; nq = ~l2; cout = sum[W])
 *      ->  two registers plus the sum wire, same structure. Both instances (cnt1, cnt2) tie
 *          rst to 1'h1; the branch is kept (as a named constant wire) so the structure stays
 *          1:1 -- synthesis removes it. nq/cout are not connected in ym6046 and so are not
 *          generated. Initial 0/0 kept.
 *
 * Single-register conversions: NONE. Every clocked primitive here is kept as its l1/l2 pair.
 * The reasons, per clock class (the same argument as tmss_rtl, made once for each class):
 *   - bus-strobe clocks (reg_3e/reg_3f: zwrite0/zwrite1; p_control/p_data/s_control/
 *     tx_state1: write_* strobes; rx_ready/rx_error/rx_data: rx_clk2; rx_shifter: rx_clk):
 *     these are not internal clock phases but bus-derived or FSM-derived logic nets, and
 *     their val inputs (data_bus, FSM outputs of another clock) change at arbitrary MCLK
 *     edges: l2 takes the val of the LAST MCLK edge on which clk was low, so a single
 *     register would still need a register holding that value (which is l1) -- no saving.
 *   - genuine internal clock phases (VCLK for res_dff/cnt1/cnt2; uart_clk2 for the tx FSM
 *     and the divider chain; uart_clk1 for the rx FSMs): the val of several of these is
 *     stable over the clk-low phase, but their reset/set inputs (reset = res_dff_q, a VCLK-
 *     domain signal; s_control_q bits written by the 68000) are asynchronous to the clock
 *     input. ym_lib applies reset/set to l1 and l2 at every MCLK edge independently of
 *     clk; a reset that is active on the last clk-low edge and released on the first
 *     clk-high edge leaves l2 = 0 (from l1), whereas `if (rise) q <= val` would load val.
 *     Reproducing that needs a delayed copy of reset (a register) plus a clk_prev register:
 *     again no storage saving and a harder equivalence argument. And the FSM val inputs
 *     mix clock domains anyway (t_i1..t_i4 include tx_state2_l_q, uart_clk1 domain; r1_j
 *     includes rx_input_bit_q and rx_fsm2_* of the other FSM), so val is not stable over
 *     the clk-low phase for them either.
 *   "When in doubt, two registers" -- exact trivially: same registers, same next-state
 *   equations, same priorities, same initial values.
 *
 * Expressions that were port arguments of primitive instances (clk `~uart_clk2`,
 * `~uart_clk_div_n_q`, `reset & m3`, `reset & read_rx_data`, the val expressions of cnt1,
 * tx_shifter, tx_bit, tx_state1, rx_shifter) are used in place, as they were.
 */

module ym6046_rtl
	(
	input MCLK,
	input [6:0] PORT_A_i,
	input [6:0] PORT_B_i,
	input [6:0] PORT_C_i,
	input test,
	input M3,
	input IO,
	input CAS0,
	input SRES,
	input VCLK,
	input NTSC,
	input DISK,
	input JAP,
	input [7:0] ZA_i,
	input [7:0] ZD_i,
	input [6:0] VA_i,
	input [15:0] VD_i,
	input LWR,
	input t1,
	input ZV,
	input VZ,
	output [6:0] PORT_A_d,
	output [6:0] PORT_B_d,
	output [6:0] PORT_C_d,
	output [6:0] PORT_A_o,
	output [6:0] PORT_B_o,
	output [6:0] PORT_C_o,
	output HL,
	output FRES,
	output bc1,
	output bc2,
	output bc3,
	output bc4,
	output bc5,
	output [7:0] vdata,
	output reg_3e_q,
	output [7:0] zdata,
	output [6:0] ztov_address,
	input tmss_enable
	);

	wire reset;
	wire [3:0] uart_clk_i1;
	wire [3:0] uart_clk_i2;
	wire res_dff_q, res_dff_nq;
	wire pal;
	wire load;
	wire [3:0] cnt1_q;
	wire [3:0] cnt2_q;
	wire uart_clk;
	wire uart_clk2;
	wire uart_clk_div_0_q, uart_clk_div_0_nq;
	wire uart_clk_div_1_q, uart_clk_div_1_nq;
	wire uart_clk_div_2_q, uart_clk_div_2_nq;
	wire uart_clk_div_3_q, uart_clk_div_3_nq;
	wire uart_clk_div_4_q, uart_clk_div_4_nq;
	wire uart_clk_div_5_q, uart_clk_div_5_nq;
	wire uart_clk_div_6_q, uart_clk_div_6_nq;
	wire uart_clk_div_7_q, uart_clk_div_7_nq;
	wire [7:0] address;
	wire [3:0] read_address;
	wire [7:0] data_bus;
	wire [7:0] read_data;
	wire vread;
	wire vwrite;
	wire vsel;
	wire vread_high;
	wire vwrite_low;
	wire vwrite_high;
	wire zwrite_sel;
	wire zread_sel;
	wire zaccess;
	wire zwrite0;
	wire zwrite1;
	wire [7:0] reg_3f_q;
	wire io_access;
	wire byte_sel;
	wire arb_w1;
	wire arb_w2;

	wire read_rx_data_a;
	wire write_p_data_a;
	wire write_tx_data_a;
	wire write_s_control_a;
	wire write_p_control_a;
	wire uart_clk1_a;
	wire uart_clk2_a;
	wire [7:0] p_data_q_a;
	wire [7:0] p_control_q_a;
	wire [7:0] tx_data_a;
	wire [7:0] rx_data_q_a;
	wire [4:0] s_control_q_a;
	wire tx_state1_q_a;
	wire rx_ready_q_a;
	wire rx_error_q_a;
	wire [6:0] port_a_d;
	wire [6:0] port_a_o;
	wire irq_b6_a;
	wire irq_uart_a;

	wire read_rx_data_b;
	wire write_p_data_b;
	wire write_tx_data_b;
	wire write_s_control_b;
	wire write_p_control_b;
	wire uart_clk1_b;
	wire uart_clk2_b;
	wire [7:0] p_data_q_b;
	wire [7:0] p_control_q_b;
	wire [7:0] tx_data_b;
	wire [7:0] rx_data_q_b;
	wire [4:0] s_control_q_b;
	wire tx_state1_q_b;
	wire rx_ready_q_b;
	wire rx_error_q_b;
	wire [6:0] port_b_d;
	wire [6:0] port_b_o;
	wire irq_b6_b;
	wire irq_uart_b;

	wire read_rx_data_c;
	wire write_p_data_c;
	wire write_tx_data_c;
	wire write_s_control_c;
	wire write_p_control_c;
	wire uart_clk1_c;
	wire uart_clk2_c;
	wire [7:0] p_data_q_c;
	wire [7:0] p_control_q_c;
	wire [7:0] tx_data_c;
	wire [7:0] rx_data_q_c;
	wire [4:0] s_control_q_c;
	wire tx_state1_q_c;
	wire rx_ready_q_c;
	wire rx_error_q_c;
	wire [6:0] port_c_d;
	wire [6:0] port_c_o;
	wire irq_b6_c;
	wire irq_uart_c;

	ym6046_controller_port_rtl port_a(.MCLK(MCLK), .port_i(PORT_A_i), .data_bus(data_bus), .reset(reset), .m3(M3), .uart_clk_i1(uart_clk_i1),
		.uart_clk_i2(uart_clk_i2), .read_rx_data(read_rx_data_a), .write_p_data(write_p_data_a), .write_tx_data(write_tx_data_a),
		.write_s_control(write_s_control_a), .write_p_control(write_p_control_a), .uart_clk1(uart_clk1_a), .uart_clk2(uart_clk2_a), .p_data_q(p_data_q_a),
		.p_control_q(p_control_q_a), .tx_data(tx_data_a), .rx_data_q(rx_data_q_a), .s_control_q(s_control_q_a),
		.tx_state1_q(tx_state1_q_a), .rx_ready_q(rx_ready_q_a), .rx_error_q(rx_error_q_a), .port_d(port_a_d), .port_o(port_a_o),
		.irq_b6(irq_b6_a), .irq_uart(irq_uart_a));

	ym6046_controller_port_rtl port_b(.MCLK(MCLK), .port_i(PORT_B_i), .data_bus(data_bus), .reset(reset), .m3(M3), .uart_clk_i1(uart_clk_i1),
		.uart_clk_i2(uart_clk_i2), .read_rx_data(read_rx_data_b), .write_p_data(write_p_data_b), .write_tx_data(write_tx_data_b),
		.write_s_control(write_s_control_b), .write_p_control(write_p_control_b), .uart_clk1(uart_clk1_b), .uart_clk2(uart_clk2_b), .p_data_q(p_data_q_b),
		.p_control_q(p_control_q_b), .tx_data(tx_data_b), .rx_data_q(rx_data_q_b), .s_control_q(s_control_q_b),
		.tx_state1_q(tx_state1_q_b), .rx_ready_q(rx_ready_q_b), .rx_error_q(rx_error_q_b), .port_d(port_b_d), .port_o(port_b_o),
		.irq_b6(irq_b6_b), .irq_uart(irq_uart_b));

	ym6046_controller_port_rtl port_c(.MCLK(MCLK), .port_i(PORT_C_i), .data_bus(data_bus), .reset(reset), .m3(M3), .uart_clk_i1(uart_clk_i1),
		.uart_clk_i2(uart_clk_i2), .read_rx_data(read_rx_data_c), .write_p_data(write_p_data_c), .write_tx_data(write_tx_data_c),
		.write_s_control(write_s_control_c), .write_p_control(write_p_control_c), .uart_clk1(uart_clk1_c), .uart_clk2(uart_clk2_c), .p_data_q(p_data_q_c),
		.p_control_q(p_control_q_c), .tx_data(tx_data_c), .rx_data_q(rx_data_q_c), .s_control_q(s_control_q_c),
		.tx_state1_q(tx_state1_q_c), .rx_ready_q(rx_ready_q_c), .rx_error_q(rx_error_q_c), .port_d(port_c_d), .port_o(port_c_o),
		.irq_b6(irq_b6_c), .irq_uart(irq_uart_c));

	// ym_sdff res_dff(.MCLK(MCLK), .clk(VCLK), .val(SRES), .q(res_dff_q), .nq(res_dff_nq));   -- rule (B)
	reg res_dff_l1 = 1'h0, res_dff_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~VCLK)
			res_dff_l1 <= SRES;
		else
			res_dff_l2 <= res_dff_l1;
	end
	assign res_dff_q = res_dff_l2;
	assign res_dff_nq = ~res_dff_l2;

	assign FRES = res_dff_nq;
	assign reset = res_dff_q;

	assign pal = ~NTSC;

	assign load = ~(~reset | (cnt1_q == 4'hf & cnt2_q == 4'hf));
	// ym_scnt_bit #(.DATA_WIDTH(4)) cnt1(.MCLK(MCLK), .clk(VCLK), .load(load), .val(pal ? 4'hd : 4'hc), .cin(load), .rst(1'h1),
	//	.q(cnt1_q));   -- rule (F)
	wire cnt1_rst = 1'h1;
	reg [3:0] cnt1_l1 = 4'h0, cnt1_l2 = 4'h0;
	wire [4:0] cnt1_sum = { 1'h0, cnt1_l2 } + { 4'h0, load };
	always @(posedge MCLK)
	begin
		if (~cnt1_rst)
		begin
			cnt1_l1 <= 4'h0;
			cnt1_l2 <= 4'h0;
		end
		else
		begin
			if (~VCLK)
				cnt1_l1 <= ~load ? (pal ? 4'hd : 4'hc) : cnt1_sum[3:0];
			else
				cnt1_l2 <= cnt1_l1;
		end
	end
	assign cnt1_q = cnt1_l2;
	// ym_scnt_bit #(.DATA_WIDTH(4)) cnt2(.MCLK(MCLK), .clk(VCLK), .load(load), .val(4'h9), .cin(load & cnt1_q == 4'hf), .rst(1'h1),
	//	.q(cnt2_q));   -- rule (F)
	wire cnt2_rst = 1'h1;
	reg [3:0] cnt2_l1 = 4'h0, cnt2_l2 = 4'h0;
	wire [4:0] cnt2_sum = { 1'h0, cnt2_l2 } + { 4'h0, load & cnt1_q == 4'hf };
	always @(posedge MCLK)
	begin
		if (~cnt2_rst)
		begin
			cnt2_l1 <= 4'h0;
			cnt2_l2 <= 4'h0;
		end
		else
		begin
			if (~VCLK)
				cnt2_l1 <= ~load ? 4'h9 : cnt2_sum[3:0];
			else
				cnt2_l2 <= cnt2_l1;
		end
	end
	assign cnt2_q = cnt2_l2;

	assign uart_clk = cnt2_q[2];

	assign uart_clk2 = test ? VCLK : uart_clk;

	// ym_sdffr uart_clk_div_0(.MCLK(MCLK), .clk(~uart_clk2), .val(uart_clk_div_0_nq), .reset(reset), .q(uart_clk_div_0_q), .nq(uart_clk_div_0_nq));   -- rule (C)
	reg uart_clk_div_0_l1 = 1'h0, uart_clk_div_0_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			uart_clk_div_0_l1 <= 1'h0;
		else if (~(~uart_clk2))
			uart_clk_div_0_l1 <= uart_clk_div_0_nq;
		if (~reset)
			uart_clk_div_0_l2 <= 1'h0;
		else if (~uart_clk2)
			uart_clk_div_0_l2 <= uart_clk_div_0_l1;
	end
	assign uart_clk_div_0_q = uart_clk_div_0_l2;
	assign uart_clk_div_0_nq = ~uart_clk_div_0_l2;
	// ym_sdffr uart_clk_div_1(.MCLK(MCLK), .clk(~uart_clk_div_0_q), .val(uart_clk_div_1_nq), .reset(reset), .q(uart_clk_div_1_q), .nq(uart_clk_div_1_nq));
	reg uart_clk_div_1_l1 = 1'h0, uart_clk_div_1_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			uart_clk_div_1_l1 <= 1'h0;
		else if (~(~uart_clk_div_0_q))
			uart_clk_div_1_l1 <= uart_clk_div_1_nq;
		if (~reset)
			uart_clk_div_1_l2 <= 1'h0;
		else if (~uart_clk_div_0_q)
			uart_clk_div_1_l2 <= uart_clk_div_1_l1;
	end
	assign uart_clk_div_1_q = uart_clk_div_1_l2;
	assign uart_clk_div_1_nq = ~uart_clk_div_1_l2;
	// ym_sdffr uart_clk_div_2(.MCLK(MCLK), .clk(~uart_clk_div_1_q), .val(uart_clk_div_2_nq), .reset(reset), .q(uart_clk_div_2_q), .nq(uart_clk_div_2_nq));
	reg uart_clk_div_2_l1 = 1'h0, uart_clk_div_2_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			uart_clk_div_2_l1 <= 1'h0;
		else if (~(~uart_clk_div_1_q))
			uart_clk_div_2_l1 <= uart_clk_div_2_nq;
		if (~reset)
			uart_clk_div_2_l2 <= 1'h0;
		else if (~uart_clk_div_1_q)
			uart_clk_div_2_l2 <= uart_clk_div_2_l1;
	end
	assign uart_clk_div_2_q = uart_clk_div_2_l2;
	assign uart_clk_div_2_nq = ~uart_clk_div_2_l2;
	// ym_sdffr uart_clk_div_3(.MCLK(MCLK), .clk(~uart_clk_div_2_q), .val(uart_clk_div_3_nq), .reset(reset), .q(uart_clk_div_3_q), .nq(uart_clk_div_3_nq));
	reg uart_clk_div_3_l1 = 1'h0, uart_clk_div_3_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			uart_clk_div_3_l1 <= 1'h0;
		else if (~(~uart_clk_div_2_q))
			uart_clk_div_3_l1 <= uart_clk_div_3_nq;
		if (~reset)
			uart_clk_div_3_l2 <= 1'h0;
		else if (~uart_clk_div_2_q)
			uart_clk_div_3_l2 <= uart_clk_div_3_l1;
	end
	assign uart_clk_div_3_q = uart_clk_div_3_l2;
	assign uart_clk_div_3_nq = ~uart_clk_div_3_l2;
	// ym_sdffr uart_clk_div_4(.MCLK(MCLK), .clk(~uart_clk_div_3_q), .val(uart_clk_div_4_nq), .reset(reset), .q(uart_clk_div_4_q), .nq(uart_clk_div_4_nq));
	reg uart_clk_div_4_l1 = 1'h0, uart_clk_div_4_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			uart_clk_div_4_l1 <= 1'h0;
		else if (~(~uart_clk_div_3_q))
			uart_clk_div_4_l1 <= uart_clk_div_4_nq;
		if (~reset)
			uart_clk_div_4_l2 <= 1'h0;
		else if (~uart_clk_div_3_q)
			uart_clk_div_4_l2 <= uart_clk_div_4_l1;
	end
	assign uart_clk_div_4_q = uart_clk_div_4_l2;
	assign uart_clk_div_4_nq = ~uart_clk_div_4_l2;
	// ym_sdffr uart_clk_div_5(.MCLK(MCLK), .clk(~uart_clk_div_4_q), .val(uart_clk_div_5_nq), .reset(reset), .q(uart_clk_div_5_q), .nq(uart_clk_div_5_nq));
	reg uart_clk_div_5_l1 = 1'h0, uart_clk_div_5_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			uart_clk_div_5_l1 <= 1'h0;
		else if (~(~uart_clk_div_4_q))
			uart_clk_div_5_l1 <= uart_clk_div_5_nq;
		if (~reset)
			uart_clk_div_5_l2 <= 1'h0;
		else if (~uart_clk_div_4_q)
			uart_clk_div_5_l2 <= uart_clk_div_5_l1;
	end
	assign uart_clk_div_5_q = uart_clk_div_5_l2;
	assign uart_clk_div_5_nq = ~uart_clk_div_5_l2;
	// ym_sdffr uart_clk_div_6(.MCLK(MCLK), .clk(~uart_clk_div_5_q), .val(uart_clk_div_6_nq), .reset(reset), .q(uart_clk_div_6_q), .nq(uart_clk_div_6_nq));
	reg uart_clk_div_6_l1 = 1'h0, uart_clk_div_6_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			uart_clk_div_6_l1 <= 1'h0;
		else if (~(~uart_clk_div_5_q))
			uart_clk_div_6_l1 <= uart_clk_div_6_nq;
		if (~reset)
			uart_clk_div_6_l2 <= 1'h0;
		else if (~uart_clk_div_5_q)
			uart_clk_div_6_l2 <= uart_clk_div_6_l1;
	end
	assign uart_clk_div_6_q = uart_clk_div_6_l2;
	assign uart_clk_div_6_nq = ~uart_clk_div_6_l2;
	// ym_sdffr uart_clk_div_7(.MCLK(MCLK), .clk(~uart_clk_div_6_q), .val(uart_clk_div_7_nq), .reset(reset), .q(uart_clk_div_7_q), .nq(uart_clk_div_7_nq));
	reg uart_clk_div_7_l1 = 1'h0, uart_clk_div_7_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			uart_clk_div_7_l1 <= 1'h0;
		else if (~(~uart_clk_div_6_q))
			uart_clk_div_7_l1 <= uart_clk_div_7_nq;
		if (~reset)
			uart_clk_div_7_l2 <= 1'h0;
		else if (~uart_clk_div_6_q)
			uart_clk_div_7_l2 <= uart_clk_div_7_l1;
	end
	assign uart_clk_div_7_q = uart_clk_div_7_l2;
	assign uart_clk_div_7_nq = ~uart_clk_div_7_l2;

	assign uart_clk_i1[0] = uart_clk2;
	assign uart_clk_i1[1] = uart_clk_div_0_q;
	assign uart_clk_i1[2] = uart_clk_div_1_q;
	assign uart_clk_i1[3] = uart_clk_div_3_q;

	assign uart_clk_i2[0] = uart_clk_div_3_q;
	assign uart_clk_i2[1] = uart_clk_div_4_q;
	assign uart_clk_i2[2] = uart_clk_div_5_q;
	assign uart_clk_i2[3] = uart_clk_div_7_q;

	assign address = M3 ? { 1'h0, VA_i[6:0] } : ZA_i[7:0];
	assign ztov_address = M3 ? ZA_i[7:1] : ZA_i[6:0];

	assign read_address = M3 ? address[3:0] : (address[0] ? 4'h2 : 4'h1);

	assign data_bus = M3 ? VD_i[7:0] : ZD_i[7:0];

	wire [15:0] ra_sel;

	assign ra_sel[0] = read_address == 4'h0;
	assign ra_sel[1] = read_address == 4'h1;
	assign ra_sel[2] = read_address == 4'h2;
	assign ra_sel[3] = read_address == 4'h3;
	assign ra_sel[4] = read_address == 4'h4;
	assign ra_sel[5] = read_address == 4'h5;
	assign ra_sel[6] = read_address == 4'h6;
	assign ra_sel[7] = read_address == 4'h7;
	assign ra_sel[8] = read_address == 4'h8;
	assign ra_sel[9] = read_address == 4'h9;
	assign ra_sel[10] = read_address == 4'ha;
	assign ra_sel[11] = read_address == 4'hb;
	assign ra_sel[12] = read_address == 4'hc;
	assign ra_sel[13] = read_address == 4'hd;
	assign ra_sel[14] = read_address == 4'he;
	assign ra_sel[15] = read_address == 4'hf;

	wire [1:0] dir_a = JAP ? 2'h3 : PORT_A_d[6:5];
	wire [1:0] dir_b = JAP ? 2'h3 : PORT_B_d[6:5];

	wire [7:0] rd_0 = { JAP, test ? { uart_clk, uart_clk2_c, uart_clk1_c, uart_clk2_b, uart_clk1_b, uart_clk2_a, uart_clk1_a } :
		{ pal, DISK, 4'h0, tmss_enable } };

	wire [7:0] rd_1 = M3 ? { p_data_q_a[7], PORT_A_i } : { PORT_B_i[1:0], dir_a[0] & PORT_A_i[5], PORT_A_i[4], PORT_A_i[3:0] };

	wire [7:0] rd_2 = M3 ? { p_data_q_b[7], PORT_B_i } : { dir_b[1] & PORT_B_i[6], dir_a[1] & PORT_A_i[6], 2'h1, dir_b[0] & PORT_B_i[5], PORT_B_i[4:2] };

	wire [7:0] rd_3 = { p_data_q_c[7], PORT_C_i };

	wire [7:0] rd_4 = p_control_q_a;

	wire [7:0] rd_5 = p_control_q_b;

	wire [7:0] rd_6 = p_control_q_c;

	wire [7:0] rd_7 = tx_data_a;

	wire [7:0] rd_8 = rx_data_q_a;

	wire [7:0] rd_9 = { s_control_q_a, rx_error_q_a, rx_ready_q_a, tx_state1_q_a };

	wire [7:0] rd_10 = tx_data_b;

	wire [7:0] rd_11 = rx_data_q_b;

	wire [7:0] rd_12 = { s_control_q_b, rx_error_q_b, rx_ready_q_b, tx_state1_q_b };

	wire [7:0] rd_13 = tx_data_c;

	wire [7:0] rd_14 = rx_data_q_c;

	wire [7:0] rd_15 = { s_control_q_c, rx_error_q_c, rx_ready_q_c, tx_state1_q_c };

	assign read_data =
		(ra_sel[0] ? rd_0 : 8'h0) |
		(ra_sel[1] ? rd_1 : 8'h0) |
		(ra_sel[2] ? rd_2 : 8'h0) |
		(ra_sel[3] ? rd_3 : 8'h0) |
		(ra_sel[4] ? rd_4 : 8'h0) |
		(ra_sel[5] ? rd_5 : 8'h0) |
		(ra_sel[6] ? rd_6 : 8'h0) |
		(ra_sel[7] ? rd_7 : 8'h0) |
		(ra_sel[8] ? rd_8 : 8'h0) |
		(ra_sel[9] ? rd_9 : 8'h0) |
		(ra_sel[10] ? rd_10 : 8'h0) |
		(ra_sel[11] ? rd_11 : 8'h0) |
		(ra_sel[12] ? rd_12 : 8'h0) |
		(ra_sel[13] ? rd_13 : 8'h0) |
		(ra_sel[14] ? rd_14 : 8'h0) |
		(ra_sel[15] ? rd_15 : 8'h0);

	assign vread = CAS0 | IO;
	assign vwrite = LWR | IO;
	assign vsel = ~(M3 & address[7:4] == 4'h0);
	assign vread_high = ~vsel & address[3] & ~vread;
	assign vwrite_low = ~vsel & ~address[3] & ~vwrite;
	assign vwrite_high = ~vsel & address[3] & ~vwrite;

	assign zwrite_sel = ~(address[7:1] == 7'h1f & ~M3 & ~vwrite);
	assign zread_sel = ~((address & 8'he2) == 8'hc0
		& (address[4:2] == 3'h0 | address[4:2] == 3'h7) & ~M3);
	assign zaccess = (zwrite_sel & zread_sel) & vsel;

	assign zwrite0 = zwrite_sel | address[0];
	assign zwrite1 = zwrite_sel | ~address[0];

	assign read_rx_data_a = ~(vread_high & address[2:0] == 3'h0);
	assign read_rx_data_b = ~(vread_high & address[2:0] == 3'h3);
	assign read_rx_data_c = ~(vread_high & address[2:0] == 3'h6);
	assign write_p_data_a = ~(vwrite_low & address[2:0] == 3'h1);
	assign write_p_data_b = ~(vwrite_low & address[2:0] == 3'h2);
	assign write_p_data_c = ~(vwrite_low & address[2:0] == 3'h3);
	assign write_p_control_a = ~(vwrite_low & address[2:0] == 3'h4);
	assign write_p_control_b = ~(vwrite_low & address[2:0] == 3'h5);
	assign write_p_control_c = ~(vwrite_low & address[2:0] == 3'h6);
	assign write_tx_data_a = ~(vwrite_low & address[2:0] == 3'h7);
	assign write_s_control_a = ~(vwrite_high & address[2:0] == 3'h1);
	assign write_tx_data_b = ~(vwrite_high & address[2:0] == 3'h2);
	assign write_s_control_b = ~(vwrite_high & address[2:0] == 3'h4);
	assign write_tx_data_c = ~(vwrite_high & address[2:0] == 3'h5);
	assign write_s_control_c = ~(vwrite_high & address[2:0] == 3'h7);

	// ym_sdffr reg_3e(.MCLK(MCLK), .clk(zwrite0), .val(data_bus[4]), .reset(reset), .q(reg_3e_q));   -- rule (C)
	reg reg_3e_l1 = 1'h0, reg_3e_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			reg_3e_l1 <= 1'h0;
		else if (~zwrite0)
			reg_3e_l1 <= data_bus[4];
		if (~reset)
			reg_3e_l2 <= 1'h0;
		else if (zwrite0)
			reg_3e_l2 <= reg_3e_l1;
	end
	assign reg_3e_q = reg_3e_l2;
	// ym_sdffs #(.DATA_WIDTH(8)) reg_3f(.MCLK(MCLK), .clk(zwrite1), .val(data_bus), .set(reset), .q(reg_3f_q));   -- rule (D)
	// (ym_sdffs has no initialiser in ym_lib.v -- none here either, on purpose)
	reg [7:0] reg_3f_l1, reg_3f_l2;
	always @(posedge MCLK)
	begin
		if (~zwrite1)
			reg_3f_l1 <= data_bus;
		else if (~reset)
			reg_3f_l1 <= 8'hff;
		if (~reset)
			reg_3f_l2 <= 8'hff;
		else if (zwrite1)
			reg_3f_l2 <= reg_3f_l1;
	end
	assign reg_3f_q = reg_3f_l2;

	assign PORT_A_d = M3 ? port_a_d : { reg_3f_q[1:0], port_a_d[4:0] };
	assign PORT_B_d = M3 ? port_b_d : { reg_3f_q[3:2], port_b_d[4:0] };
	assign PORT_C_d = port_c_d;

	assign PORT_A_o = M3 ? port_a_o : { reg_3f_q[5:4], port_a_o[4:0] };
	assign PORT_B_o = M3 ? port_b_o : { reg_3f_q[7:6], port_b_o[4:0] };
	assign PORT_C_o = port_c_o;

	assign io_access = ~(zaccess | IO | CAS0);

	assign byte_sel = M3 & ~ZA_i[0];

	assign arb_w1 = ~(io_access & M3) & (ZV | ~CAS0) & (VZ | CAS0);
	assign arb_w2 = (ZV | CAS0) & (VZ | ~CAS0);

	assign bc1 = VZ | t1;
	assign bc2 = arb_w1 | t1;
	assign bc3 = (arb_w1 & M3) | t1;
	assign bc4 = arb_w2 | t1;
	assign bc5 = ZV | t1;

	assign vdata = io_access ? read_data : ZD_i[7:0];
	assign zdata = io_access ? read_data : (byte_sel ? VD_i[15:8] : VD_i[7:0]);

	assign HL = M3 ?
		~(irq_b6_a | irq_uart_a | irq_b6_b | irq_uart_b | irq_b6_c | irq_uart_c) :
		~((PORT_A_d[6] & ~PORT_A_i[6]) | (PORT_B_d[6] & ~PORT_B_i[6]));

endmodule


module ym6046_controller_port_rtl
	(
	input MCLK,
	input [6:0] port_i,
	input [7:0] data_bus,
	input reset,
	input m3,
	input [3:0] uart_clk_i1,
	input [3:0] uart_clk_i2,
	input read_rx_data,
	input write_p_data,
	input write_tx_data,
	input write_s_control,
	input write_p_control,
	output uart_clk1,
	output uart_clk2,
	output [7:0] p_data_q,
	output [7:0] p_control_q,
	output [7:0] tx_data,
	output [7:0] rx_data_q,
	output [4:0] s_control_q,
	output tx_state1_q,
	output rx_ready_q,
	output rx_error_q,
	output [6:0] port_d,
	output [6:0] port_o,
	output irq_b6,
	output irq_uart
	);

	wire [7:0] tx_shifter_q;
	wire tx_step;
	wire tx_bit_q;
	wire tx_fsm1_q, tx_fsm1_nq;
	wire tx_fsm2_q, tx_fsm2_nq;
	wire tx_fsm3_q, tx_fsm3_nq;
	wire tx_fsm4_q, tx_fsm4_nq;
	wire tx_fsm5_q;
	wire tx_state1_nq;
	wire tx_state2_q;
	wire tx_state2_l_q;
	wire rx_input_bit_q, rx_input_bit_nq;
	wire rx_fsm1_1_nq;
	wire rx_fsm1_2_q, rx_fsm1_2_nq;
	wire rx_fsm1_3_q, rx_fsm1_3_nq;
	wire rx_fsm1_4_q, rx_fsm1_4_nq;
	wire rx_fsm1_5_q, rx_fsm1_5_nq;
	wire rx_clk;
	wire rx_fsm2_1_q, rx_fsm2_1_nq;
	wire rx_fsm2_2_q, rx_fsm2_2_nq;
	wire rx_fsm2_3_q, rx_fsm2_3_nq;
	wire rx_fsm2_4_q, rx_fsm2_4_nq;
	wire rx_fsm2_5_q, rx_fsm2_5_nq;
	wire rx_clk2;
	wire [7:0] rx_shifter_q;
	reg [7:0] rx_shifter_q_delay;

	// ym_sdffr #(.DATA_WIDTH(8)) p_control(.MCLK(MCLK), .clk(write_p_control), .val(data_bus), .reset(reset & m3), .q(p_control_q));   -- rule (C)
	reg [7:0] p_control_l1 = 8'h0, p_control_l2 = 8'h0;
	always @(posedge MCLK)
	begin
		if (~(reset & m3))
			p_control_l1 <= 8'h0;
		else if (~write_p_control)
			p_control_l1 <= data_bus;
		if (~(reset & m3))
			p_control_l2 <= 8'h0;
		else if (write_p_control)
			p_control_l2 <= p_control_l1;
	end
	assign p_control_q = p_control_l2;

	assign port_d = ((~p_control_q[6:0]) & (s_control_q[1] ? 7'h6f : 7'h7f)) | (s_control_q[2] ? 7'h20 : 7'h0);

	// ym_sdffr #(.DATA_WIDTH(8)) p_data(.MCLK(MCLK), .clk(write_p_data), .val(data_bus), .reset(1'h1), .q(p_data_q));   -- rule (C)
	wire p_data_reset = 1'h1;
	reg [7:0] p_data_l1 = 8'h0, p_data_l2 = 8'h0;
	always @(posedge MCLK)
	begin
		if (~p_data_reset)
			p_data_l1 <= 8'h0;
		else if (~write_p_data)
			p_data_l1 <= data_bus;
		if (~p_data_reset)
			p_data_l2 <= 8'h0;
		else if (write_p_data)
			p_data_l2 <= p_data_l1;
	end
	assign p_data_q = p_data_l2;

	assign port_o[6:5] = p_data_q[6:5];
	assign port_o[4] = s_control_q[1] ? tx_bit_q : p_data_q[4];
	assign port_o[3:0] = p_data_q[3:0];

	// ym_sdffr #(.DATA_WIDTH(5)) s_control(.MCLK(MCLK), .clk(write_s_control), .val(data_bus[7:3]), .reset(reset & m3), .q(s_control_q));   -- rule (C)
	reg [4:0] s_control_l1 = 5'h0, s_control_l2 = 5'h0;
	always @(posedge MCLK)
	begin
		if (~(reset & m3))
			s_control_l1 <= 5'h0;
		else if (~write_s_control)
			s_control_l1 <= data_bus[7:3];
		if (~(reset & m3))
			s_control_l2 <= 5'h0;
		else if (write_s_control)
			s_control_l2 <= s_control_l1;
	end
	assign s_control_q = s_control_l2;

	// ym_slatch #(.DATA_WIDTH(8)) tx_data_sl(.MCLK(MCLK), .en(~write_tx_data), .inp(data_bus), .val(tx_data));   -- rule (A)
	reg [7:0] tx_data_sl_mem = 8'h0;
	always @(posedge MCLK)
		if (~write_tx_data)
			tx_data_sl_mem <= data_bus;
	assign tx_data = tx_data_sl_mem;

	assign uart_clk1 = uart_clk_i1[s_control_q[4:3]];
	assign uart_clk2 = uart_clk_i2[s_control_q[4:3]];

	// ym_sdffr #(.DATA_WIDTH(8)) tx_shifter(.MCLK(MCLK), .clk(uart_clk2), .val(tx_step ? { 1'h0, tx_shifter_q[7:1] } : ~tx_data),
	//	.reset(s_control_q[1]), .q(tx_shifter_q));   -- rule (C)
	reg [7:0] tx_shifter_l1 = 8'h0, tx_shifter_l2 = 8'h0;
	always @(posedge MCLK)
	begin
		if (~s_control_q[1])
			tx_shifter_l1 <= 8'h0;
		else if (~uart_clk2)
			tx_shifter_l1 <= tx_step ? { 1'h0, tx_shifter_q[7:1] } : ~tx_data;
		if (~s_control_q[1])
			tx_shifter_l2 <= 8'h0;
		else if (uart_clk2)
			tx_shifter_l2 <= tx_shifter_l1;
	end
	assign tx_shifter_q = tx_shifter_l2;

	// ym_sdffs tx_bit(.MCLK(MCLK), .clk(uart_clk2), .val(~tx_shifter_q[0] & tx_step), .set(s_control_q[1]), .q(tx_bit_q));   -- rule (D), no initialiser
	reg tx_bit_l1, tx_bit_l2;
	always @(posedge MCLK)
	begin
		if (~uart_clk2)
			tx_bit_l1 <= ~tx_shifter_q[0] & tx_step;
		else if (~s_control_q[1])
			tx_bit_l1 <= 1'h1;
		if (~s_control_q[1])
			tx_bit_l2 <= 1'h1;
		else if (uart_clk2)
			tx_bit_l2 <= tx_bit_l1;
	end
	assign tx_bit_q = tx_bit_l2;

	wire t_i1 = (tx_fsm4_q & tx_fsm1_nq)
		| (tx_fsm1_nq & tx_fsm4_nq & tx_state2_l_q)
		| (tx_fsm4_q & tx_fsm1_q & tx_fsm2_q);
	wire t_i2 = (tx_fsm1_nq & tx_fsm4_nq & tx_state2_l_q) | (tx_fsm1_q & tx_fsm2_q)
		| (tx_fsm2_nq & tx_fsm1_nq & tx_fsm3_q & tx_fsm4_nq);
	wire t_i3 = (tx_fsm1_nq & tx_fsm4_nq & tx_state2_l_q)
		| (tx_fsm4_q & tx_fsm1_q & tx_fsm2_q)
		| (tx_fsm2_q & tx_fsm4_q & tx_fsm3_q)
		| (tx_fsm4_q & tx_fsm3_q & tx_fsm1_q);
	wire t_i4 = (tx_fsm1_q & tx_fsm2_q)
		| (tx_fsm2_nq & tx_fsm1_nq & tx_fsm3_q & tx_fsm4_nq)
		| (tx_fsm4_q & tx_fsm1_q)
		| (tx_fsm4_q & tx_fsm2_q);
	wire t_i5 = ~(tx_fsm1_nq & tx_fsm2_nq & tx_fsm3_nq & tx_fsm4_q);

	// ym_sdffr tx_fsm1(.MCLK(MCLK), .clk(uart_clk2), .val(t_i1), .reset(reset), .q(tx_fsm1_q), .nq(tx_fsm1_nq));   -- rule (C)
	reg tx_fsm1_l1 = 1'h0, tx_fsm1_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			tx_fsm1_l1 <= 1'h0;
		else if (~uart_clk2)
			tx_fsm1_l1 <= t_i1;
		if (~reset)
			tx_fsm1_l2 <= 1'h0;
		else if (uart_clk2)
			tx_fsm1_l2 <= tx_fsm1_l1;
	end
	assign tx_fsm1_q = tx_fsm1_l2;
	assign tx_fsm1_nq = ~tx_fsm1_l2;
	// ym_sdffr tx_fsm2(.MCLK(MCLK), .clk(uart_clk2), .val(t_i2), .reset(reset), .q(tx_fsm2_q), .nq(tx_fsm2_nq));
	reg tx_fsm2_l1 = 1'h0, tx_fsm2_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			tx_fsm2_l1 <= 1'h0;
		else if (~uart_clk2)
			tx_fsm2_l1 <= t_i2;
		if (~reset)
			tx_fsm2_l2 <= 1'h0;
		else if (uart_clk2)
			tx_fsm2_l2 <= tx_fsm2_l1;
	end
	assign tx_fsm2_q = tx_fsm2_l2;
	assign tx_fsm2_nq = ~tx_fsm2_l2;
	// ym_sdffr tx_fsm3(.MCLK(MCLK), .clk(uart_clk2), .val(t_i3), .reset(reset), .q(tx_fsm3_q), .nq(tx_fsm3_nq));
	reg tx_fsm3_l1 = 1'h0, tx_fsm3_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			tx_fsm3_l1 <= 1'h0;
		else if (~uart_clk2)
			tx_fsm3_l1 <= t_i3;
		if (~reset)
			tx_fsm3_l2 <= 1'h0;
		else if (uart_clk2)
			tx_fsm3_l2 <= tx_fsm3_l1;
	end
	assign tx_fsm3_q = tx_fsm3_l2;
	assign tx_fsm3_nq = ~tx_fsm3_l2;
	// ym_sdffr tx_fsm4(.MCLK(MCLK), .clk(uart_clk2), .val(t_i4), .reset(reset), .q(tx_fsm4_q), .nq(tx_fsm4_nq));
	reg tx_fsm4_l1 = 1'h0, tx_fsm4_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			tx_fsm4_l1 <= 1'h0;
		else if (~uart_clk2)
			tx_fsm4_l1 <= t_i4;
		if (~reset)
			tx_fsm4_l2 <= 1'h0;
		else if (uart_clk2)
			tx_fsm4_l2 <= tx_fsm4_l1;
	end
	assign tx_fsm4_q = tx_fsm4_l2;
	assign tx_fsm4_nq = ~tx_fsm4_l2;
	// ym_sdffs tx_fsm5(.MCLK(MCLK), .clk(uart_clk2), .val(t_i5), .set(reset), .q(tx_fsm5_q));   -- rule (D), no initialiser
	reg tx_fsm5_l1, tx_fsm5_l2;
	always @(posedge MCLK)
	begin
		if (~uart_clk2)
			tx_fsm5_l1 <= t_i5;
		else if (~reset)
			tx_fsm5_l1 <= 1'h1;
		if (~reset)
			tx_fsm5_l2 <= 1'h1;
		else if (uart_clk2)
			tx_fsm5_l2 <= tx_fsm5_l1;
	end
	assign tx_fsm5_q = tx_fsm5_l2;

	assign tx_step = ~(tx_state2_l_q & tx_fsm1_nq & tx_fsm2_nq & tx_fsm3_nq & tx_fsm4_nq);

	// ym_sdffsr tx_state1(.MCLK(MCLK), .clk(uart_clk2), .val(~tx_step & tx_state1_q), .set(write_tx_data), .reset(reset),
	//	.q(tx_state1_q), .nq(tx_state1_nq));   -- rule (E)
	reg tx_state1_l1 = 1'h0, tx_state1_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			tx_state1_l1 <= 1'h0;
		else if (~write_tx_data)
			tx_state1_l1 <= 1'h1;
		else if (~uart_clk2)
			tx_state1_l1 <= ~tx_step & tx_state1_q;
		if (~write_tx_data)
			tx_state1_l2 <= 1'h1;
		else if (~reset)
			tx_state1_l2 <= 1'h0;
		else if (uart_clk2)
			tx_state1_l2 <= tx_state1_l1;
	end
	assign tx_state1_q = (~write_tx_data & ~reset) ? 1'h0 : tx_state1_l2;
	assign tx_state1_nq = (~write_tx_data & ~reset) ? 1'h0 : ~tx_state1_l2;
	// ym_sdffsr tx_state2(.MCLK(MCLK), .clk(tx_fsm5_q), .val(1'h0), .set(tx_state1_nq), .reset(reset),
	//	.q(tx_state2_q));   -- rule (E)
	reg tx_state2_l1 = 1'h0, tx_state2_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			tx_state2_l1 <= 1'h0;
		else if (~tx_state1_nq)
			tx_state2_l1 <= 1'h1;
		else if (~tx_fsm5_q)
			tx_state2_l1 <= 1'h0;
		if (~tx_state1_nq)
			tx_state2_l2 <= 1'h1;
		else if (~reset)
			tx_state2_l2 <= 1'h0;
		else if (tx_fsm5_q)
			tx_state2_l2 <= tx_state2_l1;
	end
	assign tx_state2_q = (~tx_state1_nq & ~reset) ? 1'h0 : tx_state2_l2;

	// ym_sdff tx_state2_l(.MCLK(MCLK), .clk(uart_clk1), .val(tx_state2_q), .q(tx_state2_l_q));   -- rule (B)
	reg tx_state2_l_l1 = 1'h0, tx_state2_l_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~uart_clk1)
			tx_state2_l_l1 <= tx_state2_q;
		else
			tx_state2_l_l2 <= tx_state2_l_l1;
	end
	assign tx_state2_l_q = tx_state2_l_l2;

	// ym_sdffs rx_input_bit(.MCLK(MCLK), .clk(uart_clk1), .val(port_i[5]), .set(s_control_q[2]), .q(rx_input_bit_q), .nq(rx_input_bit_nq));   -- rule (D), no initialiser
	reg rx_input_bit_l1, rx_input_bit_l2;
	always @(posedge MCLK)
	begin
		if (~uart_clk1)
			rx_input_bit_l1 <= port_i[5];
		else if (~s_control_q[2])
			rx_input_bit_l1 <= 1'h1;
		if (~s_control_q[2])
			rx_input_bit_l2 <= 1'h1;
		else if (uart_clk1)
			rx_input_bit_l2 <= rx_input_bit_l1;
	end
	assign rx_input_bit_q = rx_input_bit_l2;
	assign rx_input_bit_nq = ~rx_input_bit_l2;

	wire r1_j = ~(rx_fsm1_1_nq | ~(rx_fsm2_1_nq & rx_fsm2_4_nq) | rx_input_bit_q);
	wire r1_i1 = ~((rx_fsm1_2_q | r1_j) & (rx_fsm1_1_nq | r1_j));
	wire r1_i2 = (rx_fsm1_4_nq & rx_fsm1_5_q & rx_fsm1_3_nq & ~rx_fsm1_2_q)
		| (rx_fsm1_2_q & rx_fsm1_3_q)
		| (rx_fsm1_2_q & rx_fsm1_5_nq)
		| (rx_fsm1_2_q & rx_fsm1_4_q)
		| r1_j;
	wire r1_i3 = r1_j
		| (rx_fsm1_3_q & rx_fsm1_4_q)
		| (rx_fsm1_4_nq & rx_fsm1_5_q & rx_fsm1_3_nq)
		| (rx_fsm1_3_q & rx_fsm1_5_nq);
	wire r1_i4 = r1_j
		| (rx_fsm1_5_nq & rx_fsm1_4_q)
		| (rx_fsm1_5_q & rx_fsm1_4_nq);
	wire r1_i5 = ~(r1_j | rx_fsm1_5_q);

	// ym_sdffr rx_fsm1_1(.MCLK(MCLK), .clk(uart_clk1), .val(r1_i1), .reset(reset), .nq(rx_fsm1_1_nq));   -- rule (C)
	reg rx_fsm1_1_l1 = 1'h0, rx_fsm1_1_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			rx_fsm1_1_l1 <= 1'h0;
		else if (~uart_clk1)
			rx_fsm1_1_l1 <= r1_i1;
		if (~reset)
			rx_fsm1_1_l2 <= 1'h0;
		else if (uart_clk1)
			rx_fsm1_1_l2 <= rx_fsm1_1_l1;
	end
	assign rx_fsm1_1_nq = ~rx_fsm1_1_l2;
	// ym_sdffs rx_fsm1_2(.MCLK(MCLK), .clk(uart_clk1), .val(r1_i2), .set(reset), .q(rx_fsm1_2_q), .nq(rx_fsm1_2_nq));   -- rule (D), no initialiser
	reg rx_fsm1_2_l1, rx_fsm1_2_l2;
	always @(posedge MCLK)
	begin
		if (~uart_clk1)
			rx_fsm1_2_l1 <= r1_i2;
		else if (~reset)
			rx_fsm1_2_l1 <= 1'h1;
		if (~reset)
			rx_fsm1_2_l2 <= 1'h1;
		else if (uart_clk1)
			rx_fsm1_2_l2 <= rx_fsm1_2_l1;
	end
	assign rx_fsm1_2_q = rx_fsm1_2_l2;
	assign rx_fsm1_2_nq = ~rx_fsm1_2_l2;
	// ym_sdffs rx_fsm1_3(.MCLK(MCLK), .clk(uart_clk1), .val(r1_i3), .set(reset), .q(rx_fsm1_3_q), .nq(rx_fsm1_3_nq));
	reg rx_fsm1_3_l1, rx_fsm1_3_l2;
	always @(posedge MCLK)
	begin
		if (~uart_clk1)
			rx_fsm1_3_l1 <= r1_i3;
		else if (~reset)
			rx_fsm1_3_l1 <= 1'h1;
		if (~reset)
			rx_fsm1_3_l2 <= 1'h1;
		else if (uart_clk1)
			rx_fsm1_3_l2 <= rx_fsm1_3_l1;
	end
	assign rx_fsm1_3_q = rx_fsm1_3_l2;
	assign rx_fsm1_3_nq = ~rx_fsm1_3_l2;
	// ym_sdffs rx_fsm1_4(.MCLK(MCLK), .clk(uart_clk1), .val(r1_i4), .set(reset), .q(rx_fsm1_4_q), .nq(rx_fsm1_4_nq));
	reg rx_fsm1_4_l1, rx_fsm1_4_l2;
	always @(posedge MCLK)
	begin
		if (~uart_clk1)
			rx_fsm1_4_l1 <= r1_i4;
		else if (~reset)
			rx_fsm1_4_l1 <= 1'h1;
		if (~reset)
			rx_fsm1_4_l2 <= 1'h1;
		else if (uart_clk1)
			rx_fsm1_4_l2 <= rx_fsm1_4_l1;
	end
	assign rx_fsm1_4_q = rx_fsm1_4_l2;
	assign rx_fsm1_4_nq = ~rx_fsm1_4_l2;
	// ym_sdffr rx_fsm1_5(.MCLK(MCLK), .clk(uart_clk1), .val(r1_i5), .reset(reset), .q(rx_fsm1_5_q), .nq(rx_fsm1_5_nq));   -- rule (C)
	reg rx_fsm1_5_l1 = 1'h0, rx_fsm1_5_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			rx_fsm1_5_l1 <= 1'h0;
		else if (~uart_clk1)
			rx_fsm1_5_l1 <= r1_i5;
		if (~reset)
			rx_fsm1_5_l2 <= 1'h0;
		else if (uart_clk1)
			rx_fsm1_5_l2 <= rx_fsm1_5_l1;
	end
	assign rx_fsm1_5_q = rx_fsm1_5_l2;
	assign rx_fsm1_5_nq = ~rx_fsm1_5_l2;

	assign rx_clk = rx_fsm1_2_nq;

	wire r2_j = (rx_fsm2_1_nq & rx_fsm2_4_nq && ~rx_input_bit_q & rx_fsm1_1_nq);
	wire r2_i1 = r2_j
		| (rx_fsm2_1_q & rx_fsm2_2_q & rx_fsm2_3_nq & rx_fsm2_4_nq)
		| (rx_fsm2_1_q & rx_fsm2_3_q & rx_fsm2_4_nq)
		| (rx_fsm2_1_q & rx_fsm2_4_q);
	wire r2_i2 = r2_j
		| (rx_fsm2_1_q & rx_fsm2_2_nq & rx_fsm2_3_nq & rx_fsm2_4_nq)
		| (rx_fsm2_1_q & rx_fsm2_3_q & rx_fsm2_4_q)
		| (rx_fsm2_1_q & rx_fsm2_2_q & rx_fsm2_4_q);
	wire r2_i3 = r2_j
		| (rx_fsm2_1_q & rx_fsm2_2_nq & rx_fsm2_3_nq & rx_fsm2_4_nq)
		| (rx_fsm2_1_q & rx_fsm2_2_q & rx_fsm2_3_nq & rx_fsm2_4_nq)
		| (rx_fsm2_1_q & rx_fsm2_2_q & rx_fsm2_3_q);
	wire r2_i4 = r2_j
		| (rx_fsm2_1_q & rx_fsm2_2_nq & rx_fsm2_3_nq & rx_fsm2_4_nq)
		| (rx_fsm2_1_q & rx_fsm2_2_q & rx_fsm2_3_nq & rx_fsm2_4_nq)
		| (rx_fsm2_1_q & rx_fsm2_3_q & rx_fsm2_4_nq);
	wire r2_i5 = ~(rx_fsm2_1_q & rx_fsm2_2_nq & rx_fsm2_3_nq & rx_fsm2_4_nq);

	// ym_sdffr rx_fsm2_1(.MCLK(MCLK), .clk(uart_clk1), .val(r2_i1), .reset(reset), .q(rx_fsm2_1_q), .nq(rx_fsm2_1_nq));   -- rule (C)
	reg rx_fsm2_1_l1 = 1'h0, rx_fsm2_1_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			rx_fsm2_1_l1 <= 1'h0;
		else if (~uart_clk1)
			rx_fsm2_1_l1 <= r2_i1;
		if (~reset)
			rx_fsm2_1_l2 <= 1'h0;
		else if (uart_clk1)
			rx_fsm2_1_l2 <= rx_fsm2_1_l1;
	end
	assign rx_fsm2_1_q = rx_fsm2_1_l2;
	assign rx_fsm2_1_nq = ~rx_fsm2_1_l2;
	// ym_sdffr rx_fsm2_2(.MCLK(MCLK), .clk(uart_clk1), .val(r2_i2), .reset(reset), .q(rx_fsm2_2_q), .nq(rx_fsm2_2_nq));
	reg rx_fsm2_2_l1 = 1'h0, rx_fsm2_2_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			rx_fsm2_2_l1 <= 1'h0;
		else if (~uart_clk1)
			rx_fsm2_2_l1 <= r2_i2;
		if (~reset)
			rx_fsm2_2_l2 <= 1'h0;
		else if (uart_clk1)
			rx_fsm2_2_l2 <= rx_fsm2_2_l1;
	end
	assign rx_fsm2_2_q = rx_fsm2_2_l2;
	assign rx_fsm2_2_nq = ~rx_fsm2_2_l2;
	// ym_sdffr rx_fsm2_3(.MCLK(MCLK), .clk(uart_clk1), .val(r2_i3), .reset(reset), .q(rx_fsm2_3_q), .nq(rx_fsm2_3_nq));
	reg rx_fsm2_3_l1 = 1'h0, rx_fsm2_3_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			rx_fsm2_3_l1 <= 1'h0;
		else if (~uart_clk1)
			rx_fsm2_3_l1 <= r2_i3;
		if (~reset)
			rx_fsm2_3_l2 <= 1'h0;
		else if (uart_clk1)
			rx_fsm2_3_l2 <= rx_fsm2_3_l1;
	end
	assign rx_fsm2_3_q = rx_fsm2_3_l2;
	assign rx_fsm2_3_nq = ~rx_fsm2_3_l2;
	// ym_sdffr rx_fsm2_4(.MCLK(MCLK), .clk(uart_clk1), .val(r2_i4), .reset(reset), .q(rx_fsm2_4_q), .nq(rx_fsm2_4_nq));
	reg rx_fsm2_4_l1 = 1'h0, rx_fsm2_4_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~reset)
			rx_fsm2_4_l1 <= 1'h0;
		else if (~uart_clk1)
			rx_fsm2_4_l1 <= r2_i4;
		if (~reset)
			rx_fsm2_4_l2 <= 1'h0;
		else if (uart_clk1)
			rx_fsm2_4_l2 <= rx_fsm2_4_l1;
	end
	assign rx_fsm2_4_q = rx_fsm2_4_l2;
	assign rx_fsm2_4_nq = ~rx_fsm2_4_l2;
	// ym_sdffs rx_fsm2_5(.MCLK(MCLK), .clk(uart_clk1), .val(r2_i5), .set(reset), .q(rx_fsm2_5_q));   -- rule (D), no initialiser
	reg rx_fsm2_5_l1, rx_fsm2_5_l2;
	always @(posedge MCLK)
	begin
		if (~uart_clk1)
			rx_fsm2_5_l1 <= r2_i5;
		else if (~reset)
			rx_fsm2_5_l1 <= 1'h1;
		if (~reset)
			rx_fsm2_5_l2 <= 1'h1;
		else if (uart_clk1)
			rx_fsm2_5_l2 <= rx_fsm2_5_l1;
	end
	assign rx_fsm2_5_q = rx_fsm2_5_l2;
	assign rx_clk2 = rx_clk | rx_fsm2_5_q;

	// ym_sdffr #(.DATA_WIDTH(8)) rx_shifter(.MCLK(MCLK), .clk(rx_clk), .val({ rx_shifter_q[6:0], rx_input_bit_q }),
	//	.reset(s_control_q[2]), .q(rx_shifter_q));   -- rule (C)
	reg [7:0] rx_shifter_l1 = 8'h0, rx_shifter_l2 = 8'h0;
	always @(posedge MCLK)
	begin
		if (~s_control_q[2])
			rx_shifter_l1 <= 8'h0;
		else if (~rx_clk)
			rx_shifter_l1 <= { rx_shifter_q[6:0], rx_input_bit_q };
		if (~s_control_q[2])
			rx_shifter_l2 <= 8'h0;
		else if (rx_clk)
			rx_shifter_l2 <= rx_shifter_l1;
	end
	assign rx_shifter_q = rx_shifter_l2;

	// ym_sdffr rx_ready(.MCLK(MCLK), .clk(rx_clk2), .val(1'h1), .reset(reset & read_rx_data), .q(rx_ready_q));   -- rule (C)
	reg rx_ready_l1 = 1'h0, rx_ready_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~(reset & read_rx_data))
			rx_ready_l1 <= 1'h0;
		else if (~rx_clk2)
			rx_ready_l1 <= 1'h1;
		if (~(reset & read_rx_data))
			rx_ready_l2 <= 1'h0;
		else if (rx_clk2)
			rx_ready_l2 <= rx_ready_l1;
	end
	assign rx_ready_q = rx_ready_l2;
	// ym_sdffr rx_error(.MCLK(MCLK), .clk(rx_clk2), .val(rx_input_bit_nq), .reset(reset & read_rx_data), .q(rx_error_q));   -- rule (C)
	reg rx_error_l1 = 1'h0, rx_error_l2 = 1'h0;
	always @(posedge MCLK)
	begin
		if (~(reset & read_rx_data))
			rx_error_l1 <= 1'h0;
		else if (~rx_clk2)
			rx_error_l1 <= rx_input_bit_nq;
		if (~(reset & read_rx_data))
			rx_error_l2 <= 1'h0;
		else if (rx_clk2)
			rx_error_l2 <= rx_error_l1;
	end
	assign rx_error_q = rx_error_l2;
	// ym_sdffr #(.DATA_WIDTH(8)) rx_data(.MCLK(MCLK), .clk(rx_clk2), .val(rx_shifter_q_delay), .reset(1'h1), .q(rx_data_q));   -- rule (C)
	wire rx_data_reset = 1'h1;
	reg [7:0] rx_data_l1 = 8'h0, rx_data_l2 = 8'h0;
	always @(posedge MCLK)
	begin
		if (~rx_data_reset)
			rx_data_l1 <= 8'h0;
		else if (~rx_clk2)
			rx_data_l1 <= rx_shifter_q_delay;
		if (~rx_data_reset)
			rx_data_l2 <= 8'h0;
		else if (rx_clk2)
			rx_data_l2 <= rx_data_l1;
	end
	assign rx_data_q = rx_data_l2;

	assign irq_b6 = ~port_i[6] & p_control_q[7];
	assign irq_uart = rx_ready_q & s_control_q[0];

	always @(posedge MCLK)
	begin
		rx_shifter_q_delay <= rx_shifter_q;
	end
endmodule
