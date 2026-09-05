// ym6046 A/B equivalence bench: die model `ym6046` (rtl/nuked-md/ym6046.v) against the 1:1
// synthesis-friendly `ym6046_rtl` (rtl/nuked-md/ym6046_rtl.v). Identical stimulus into both;
// every output and every storage element (both modules, all three controller ports) compared
// twice per MCLK cycle:
//   - at posedge MCLK, before the non-blocking updates land (the values the flops sample)
//   - a quarter period after posedge (the values produced by that edge, same inputs)
// Stimulus is applied at negedge MCLK only. First mismatch prints cycle/signal/values and
// stops the run with FAIL.
//
// Board wiring reproduced (fc1004.v / md_board.v / ym6045.v / ym7101.v):
//   VCLK  = the VDP's CPU clock output mclk_cpu_clk1: MCLK(53.7 MHz)/7 -> 14 MCLK2 cycles,
//           7 high / 7 low (prescaler dff8..dff11 and the mclk_clk3_l tap).
//   IO    = arbiter: MD mode ~(~AS & VA[22:7] == A100) (A10000-A100FF); SMS mode = Z80 /IORQ.
//   CAS0  = VDP read strobe (~RW & (UDS|LDS), not for its own C00000 region); Z80 /RD in SMS.
//   LWR   = VDP lower write strobe (LDS & ~RW & latched AS); Z80 /WR in SMS mode.
//   ZV    = arbiter ztov = (~sres | dff21) & M3: 0 in SMS mode, pulsed low for Z80->68k bridge
//           cycles in MD mode. VZ = arbiter vtoz = ~(M3 & VA[22:15]==A0) | ZBAK.
//   t1    = tmss test_1 = 0 in normal mode (toggled in the random phase).
//   PORT_x_i = md_board pin resolution: a driven pin reads back the chip's own output, an
//           input pin reads the pad/device line (pull-up when nothing drives it).
`timescale 1ps/1ps

// ---------------------------------------------------------------- pad / device model on one controller port
module tb_pad(
	input MCLK,
	input [6:0] port_d,     // die model's direction (1 = input pin, 0 = driven)
	input [6:0] port_o,     // die model's output levels
	input [1:0] kind,       // 0: 6-button pad, 1: 3-button pad, 2: TR->TL echo device (handshake peripheral)
	input loop,             // serial loopback cable: TL (bit 4, TX) onto TR (bit 5, RX)
	input ext6,             // external drive of TH while it is an input (0 = pulled low: light gun / IRQ)
	input [11:0] btn,       // {Mode,X,Y,Z,Start,A,C,B,Right,Left,Down,Up}, 1 = pressed
	input [6:0] glitch,     // XOR onto the lines (random phase)
	input integer dly,      // response delay in MCLK cycles (0..15)
	output reg [6:0] port_i
	);
	wire [6:0] pin_from_chip = (~port_d & port_o) | (port_d & 7'h7f);
	wire th = pin_from_chip[6];
	wire tr = pin_from_chip[5];
	wire tl = pin_from_chip[4];
	reg th_prev = 1, tr_prev = 1;
	integer th_cnt = 0, idle = 0;
	reg [3:0] nib = 4'h0;
	reg [6:0] lines;
	reg [6:0] pipe [0:15];
	integer i;
	initial begin
		port_i = 7'h7f;
		for (i = 0; i < 16; i = i + 1) pipe[i] = 7'h7f;
	end
	always @(negedge MCLK) begin
		#100;
		// 6-button TH-low counter with idle timeout (real pad ~1.5 ms, shortened for the bench)
		if (th != th_prev) begin idle = 0; if (!th) th_cnt = th_cnt + 1; end
		else begin idle = idle + 1; if (idle > 3000) th_cnt = 0; end
		th_prev = th;
		if (tr != tr_prev) nib = nib + 1;
		tr_prev = tr;
		case (kind)
			0: begin
				if (th) begin
					if (th_cnt == 3) lines = {1'b1, ~btn[5], ~btn[4], ~btn[11], ~btn[10], ~btn[9], ~btn[8]};
					else             lines = {1'b1, ~btn[5:0]};
				end else begin
					if (th_cnt == 3)      lines = {1'b1, ~btn[7], ~btn[6], 4'b0000};
					else if (th_cnt == 4) lines = {1'b1, ~btn[7], ~btn[6], 4'b1111};
					else                  lines = {1'b1, ~btn[7], ~btn[6], 2'b00, ~btn[1], ~btn[0]};
				end
			end
			1: begin
				if (th) lines = {1'b1, ~btn[5:0]};
				else    lines = {1'b1, ~btn[7], ~btn[6], 2'b00, ~btn[1], ~btn[0]};
			end
			default: lines = {1'b1, 1'b1, tr, nib};   // TL echoes TR, nibble advances on every TR edge
		endcase
		lines[6] = ext6;
		if (loop) lines[5] = tl;
		lines = lines ^ glitch;
		for (i = 15; i > 0; i = i - 1) pipe[i] = pipe[i-1];
		pipe[0] = lines;
		port_i = (~port_d & port_o) | (port_d & pipe[dly]);
	end
endmodule

// ---------------------------------------------------------------- the bench
module tb_ym6046;

// MCLK 107.38635 MHz (md_board MCLK2)
reg MCLK = 0;
always #4656 MCLK = ~MCLK;        // 9.312 ns
localparam T68 = 14;              // MCLK cycles per VCLK period (68000 clock, 7.67 MHz)
localparam TZ80 = 30;             // MCLK cycles per Z80 clock (3.58 MHz)

// VCLK as the VDP delivers it: 7 MCLK high, 7 MCLK low, changed at negedge like all stimulus
reg VCLK = 0;
integer vdiv = 0;
always @(negedge MCLK) begin
	if (vdiv == 6) begin vdiv = 0; VCLK = ~VCLK; end else vdiv = vdiv + 1;
end

// ---------------------------------------------------------------- inputs (shared)
reg         test = 0;
reg         M3 = 1;
reg         SRES = 1;
reg         NTSC = 1;
reg         DISK = 1;
reg         JAP = 0;
reg  [7:0]  ZA_i = 8'h00;
reg  [7:0]  ZD_i = 8'h00;
reg  [22:0] VA = 23'h0;
reg  [15:0] VD_i = 16'h0000;
reg         LWR = 1;
reg         CAS0 = 1;
reg         t1 = 0;
reg         tmss_enable = 1;
reg         AS = 1, UDS = 1, LDS = 1, RW = 1;   // 68000 strobes (feed the arbiter/VDP decode below)
reg         IORQ = 1;                            // Z80 /IORQ (SMS mode)
reg         ZBAK = 1;                            // Z80 bus acknowledge (arbiter VZ decode)
reg         zv_r = 1;                            // Z80->68k bridge cycle in progress (arbiter ztov)
reg         io_force = 0, zv_force = 0, vz_force = 0;
wire        IO = M3 ? (~(~AS & VA[22:7] == 16'hA100) & ~io_force) : (IORQ & ~io_force);
wire        ZV = M3 ? (zv_r & ~zv_force) : 1'b0;
wire        VZ = (M3 ? ~(VA[22:15] == 8'hA0 & ~ZBAK) : 1'b1) & ~vz_force;
wire [6:0]  VA_i = VA[6:0];

// pad / device configuration
reg  [1:0]  kind_a = 0, kind_b = 2, kind_c = 1;
reg         loop_a = 0, loop_b = 0, loop_c = 0;
reg         ext6_a = 1, ext6_b = 1, ext6_c = 1;
reg  [11:0] btn_a = 12'h000, btn_b = 12'h000, btn_c = 12'h000;
reg  [6:0]  gl_a = 7'h0, gl_b = 7'h0, gl_c = 7'h0;
integer     dly_a = 2, dly_b = 3, dly_c = 1;
wire [6:0]  PORT_A_i, PORT_B_i, PORT_C_i;

// ---------------------------------------------------------------- outputs A (die) / B (rtl)
wire [6:0] PORT_A_d_a, PORT_B_d_a, PORT_C_d_a, PORT_A_o_a, PORT_B_o_a, PORT_C_o_a;
wire [6:0] PORT_A_d_b, PORT_B_d_b, PORT_C_d_b, PORT_A_o_b, PORT_B_o_b, PORT_C_o_b;
wire       HL_a, FRES_a, bc1_a, bc2_a, bc3_a, bc4_a, bc5_a, reg_3e_q_a;
wire       HL_b, FRES_b, bc1_b, bc2_b, bc3_b, bc4_b, bc5_b, reg_3e_q_b;
wire [7:0] vdata_a, zdata_a, vdata_b, zdata_b;
wire [6:0] ztov_address_a, ztov_address_b;

tb_pad pad_a(.MCLK(MCLK), .port_d(PORT_A_d_a), .port_o(PORT_A_o_a), .kind(kind_a), .loop(loop_a), .ext6(ext6_a), .btn(btn_a), .glitch(gl_a), .dly(dly_a), .port_i(PORT_A_i));
tb_pad pad_b(.MCLK(MCLK), .port_d(PORT_B_d_a), .port_o(PORT_B_o_a), .kind(kind_b), .loop(loop_b), .ext6(ext6_b), .btn(btn_b), .glitch(gl_b), .dly(dly_b), .port_i(PORT_B_i));
tb_pad pad_c(.MCLK(MCLK), .port_d(PORT_C_d_a), .port_o(PORT_C_o_a), .kind(kind_c), .loop(loop_c), .ext6(ext6_c), .btn(btn_c), .glitch(gl_c), .dly(dly_c), .port_i(PORT_C_i));

ym6046 u_die (
	.MCLK(MCLK), .PORT_A_i(PORT_A_i), .PORT_B_i(PORT_B_i), .PORT_C_i(PORT_C_i), .test(test), .M3(M3), .IO(IO), .CAS0(CAS0),
	.SRES(SRES), .VCLK(VCLK), .NTSC(NTSC), .DISK(DISK), .JAP(JAP), .ZA_i(ZA_i), .ZD_i(ZD_i), .VA_i(VA_i), .VD_i(VD_i),
	.LWR(LWR), .t1(t1), .ZV(ZV), .VZ(VZ),
	.PORT_A_d(PORT_A_d_a), .PORT_B_d(PORT_B_d_a), .PORT_C_d(PORT_C_d_a), .PORT_A_o(PORT_A_o_a), .PORT_B_o(PORT_B_o_a), .PORT_C_o(PORT_C_o_a),
	.HL(HL_a), .FRES(FRES_a), .bc1(bc1_a), .bc2(bc2_a), .bc3(bc3_a), .bc4(bc4_a), .bc5(bc5_a), .vdata(vdata_a), .reg_3e_q(reg_3e_q_a),
	.zdata(zdata_a), .ztov_address(ztov_address_a), .tmss_enable(tmss_enable));

ym6046_rtl u_rtl (
	.MCLK(MCLK), .PORT_A_i(PORT_A_i), .PORT_B_i(PORT_B_i), .PORT_C_i(PORT_C_i), .test(test), .M3(M3), .IO(IO), .CAS0(CAS0),
	.SRES(SRES), .VCLK(VCLK), .NTSC(NTSC), .DISK(DISK), .JAP(JAP), .ZA_i(ZA_i), .ZD_i(ZD_i), .VA_i(VA_i), .VD_i(VD_i),
	.LWR(LWR), .t1(t1), .ZV(ZV), .VZ(VZ),
	.PORT_A_d(PORT_A_d_b), .PORT_B_d(PORT_B_d_b), .PORT_C_d(PORT_C_d_b), .PORT_A_o(PORT_A_o_b), .PORT_B_o(PORT_B_o_b), .PORT_C_o(PORT_C_o_b),
	.HL(HL_b), .FRES(FRES_b), .bc1(bc1_b), .bc2(bc2_b), .bc3(bc3_b), .bc4(bc4_b), .bc5(bc5_b), .vdata(vdata_b), .reg_3e_q(reg_3e_q_b),
	.zdata(zdata_b), .ztov_address(ztov_address_b), .tmss_enable(tmss_enable));

// ---------------------------------------------------------------- comparator
integer cycle = 0;                // MCLK edges seen
integer ncmp = 0;                 // compare points (2 per cycle)
integer nmis = 0;
integer nwarn = 0;
integer nsig = 0;                 // signals compared per compare point (counted once)
reg xcheck_en = 0;                // after the first SRES: no X allowed anywhere that is compared
reg rand_phase = 0;

`define CMP(NAME, A, B) \
	begin \
		if (ncmp == 1) nsig = nsig + 1; \
		if ((A) !== (B)) begin \
			$display("MISMATCH cycle %0d t=%0t (%s) %s: die=%h rtl=%h", cycle, $time, phase, NAME, A, B); \
			nmis = nmis + 1; \
		end else if (xcheck_en && $isunknown(A)) begin \
			$display("MISMATCH cycle %0d t=%0t (%s) %s: X in both models (%b)", cycle, $time, phase, NAME, A); \
			nmis = nmis + 1; \
		end \
	end
// master-slave pair D (die primitive instance) vs R (rtl register base name)
`define CMPP(D, R) \
	`CMP(`"D.l1`", D.l1, R``_l1) \
	`CMP(`"D.l2`", D.l2, R``_l2)
// every storage element of one controller port instance P
`define CMPPORT(P) \
	`CMPP(u_die.P.p_control,   u_rtl.P.p_control) \
	`CMPP(u_die.P.p_data,      u_rtl.P.p_data) \
	`CMPP(u_die.P.s_control,   u_rtl.P.s_control) \
	`CMP(`"u_die.P.tx_data_sl.mem`", u_die.P.tx_data_sl.mem, u_rtl.P.tx_data_sl_mem) \
	`CMPP(u_die.P.tx_shifter,  u_rtl.P.tx_shifter) \
	`CMPP(u_die.P.tx_bit,      u_rtl.P.tx_bit) \
	`CMPP(u_die.P.tx_fsm1,     u_rtl.P.tx_fsm1) \
	`CMPP(u_die.P.tx_fsm2,     u_rtl.P.tx_fsm2) \
	`CMPP(u_die.P.tx_fsm3,     u_rtl.P.tx_fsm3) \
	`CMPP(u_die.P.tx_fsm4,     u_rtl.P.tx_fsm4) \
	`CMPP(u_die.P.tx_fsm5,     u_rtl.P.tx_fsm5) \
	`CMPP(u_die.P.tx_state1,   u_rtl.P.tx_state1) \
	`CMPP(u_die.P.tx_state2,   u_rtl.P.tx_state2) \
	`CMPP(u_die.P.tx_state2_l, u_rtl.P.tx_state2_l) \
	`CMPP(u_die.P.rx_input_bit, u_rtl.P.rx_input_bit) \
	`CMPP(u_die.P.rx_fsm1_1,   u_rtl.P.rx_fsm1_1) \
	`CMPP(u_die.P.rx_fsm1_2,   u_rtl.P.rx_fsm1_2) \
	`CMPP(u_die.P.rx_fsm1_3,   u_rtl.P.rx_fsm1_3) \
	`CMPP(u_die.P.rx_fsm1_4,   u_rtl.P.rx_fsm1_4) \
	`CMPP(u_die.P.rx_fsm1_5,   u_rtl.P.rx_fsm1_5) \
	`CMPP(u_die.P.rx_fsm2_1,   u_rtl.P.rx_fsm2_1) \
	`CMPP(u_die.P.rx_fsm2_2,   u_rtl.P.rx_fsm2_2) \
	`CMPP(u_die.P.rx_fsm2_3,   u_rtl.P.rx_fsm2_3) \
	`CMPP(u_die.P.rx_fsm2_4,   u_rtl.P.rx_fsm2_4) \
	`CMPP(u_die.P.rx_fsm2_5,   u_rtl.P.rx_fsm2_5) \
	`CMPP(u_die.P.rx_shifter,  u_rtl.P.rx_shifter) \
	`CMPP(u_die.P.rx_ready,    u_rtl.P.rx_ready) \
	`CMPP(u_die.P.rx_error,    u_rtl.P.rx_error) \
	`CMPP(u_die.P.rx_data,     u_rtl.P.rx_data) \
	`CMP(`"u_die.P.rx_shifter_q_delay`", u_die.P.rx_shifter_q_delay, u_rtl.P.rx_shifter_q_delay)

task automatic check(input string phase);
	ncmp = ncmp + 1;
	// every output of the top module
	`CMP("PORT_A_d",     PORT_A_d_a,     PORT_A_d_b)
	`CMP("PORT_B_d",     PORT_B_d_a,     PORT_B_d_b)
	`CMP("PORT_C_d",     PORT_C_d_a,     PORT_C_d_b)
	`CMP("PORT_A_o",     PORT_A_o_a,     PORT_A_o_b)
	`CMP("PORT_B_o",     PORT_B_o_a,     PORT_B_o_b)
	`CMP("PORT_C_o",     PORT_C_o_a,     PORT_C_o_b)
	`CMP("HL",           HL_a,           HL_b)
	`CMP("FRES",         FRES_a,         FRES_b)
	`CMP("bc1",          bc1_a,          bc1_b)
	`CMP("bc2",          bc2_a,          bc2_b)
	`CMP("bc3",          bc3_a,          bc3_b)
	`CMP("bc4",          bc4_a,          bc4_b)
	`CMP("bc5",          bc5_a,          bc5_b)
	`CMP("vdata",        vdata_a,        vdata_b)
	`CMP("reg_3e_q",     reg_3e_q_a,     reg_3e_q_b)
	`CMP("zdata",        zdata_a,        zdata_b)
	`CMP("ztov_address", ztov_address_a, ztov_address_b)
	// every storage element of the top module
	`CMPP(u_die.res_dff,        u_rtl.res_dff)
	`CMPP(u_die.cnt1,           u_rtl.cnt1)
	`CMPP(u_die.cnt2,           u_rtl.cnt2)
	`CMPP(u_die.uart_clk_div_0, u_rtl.uart_clk_div_0)
	`CMPP(u_die.uart_clk_div_1, u_rtl.uart_clk_div_1)
	`CMPP(u_die.uart_clk_div_2, u_rtl.uart_clk_div_2)
	`CMPP(u_die.uart_clk_div_3, u_rtl.uart_clk_div_3)
	`CMPP(u_die.uart_clk_div_4, u_rtl.uart_clk_div_4)
	`CMPP(u_die.uart_clk_div_5, u_rtl.uart_clk_div_5)
	`CMPP(u_die.uart_clk_div_6, u_rtl.uart_clk_div_6)
	`CMPP(u_die.uart_clk_div_7, u_rtl.uart_clk_div_7)
	`CMPP(u_die.reg_3e,         u_rtl.reg_3e)
	`CMPP(u_die.reg_3f,         u_rtl.reg_3f)
	// every storage element of the three controller ports
	`CMPPORT(port_a)
	`CMPPORT(port_b)
	`CMPPORT(port_c)
	if (nmis != 0) begin
		$display("FAIL after %0d cycles (%0d compare points, %0d signals each): %0d mismatch(es)", cycle, ncmp, nsig, nmis);
		$finish;
	end
endtask

// pre-edge compare: values present at the edge (what both models sample now)
always @(posedge MCLK) begin
	check("pre-edge");
	cycle = cycle + 1;
end
// post-edge compare: values produced by that edge, inputs unchanged until negedge
always @(posedge MCLK) begin
	#2328;
	check("post-edge");
end

// ---------------------------------------------------------------- directed-phase sanity
// Not part of the equivalence proof: confirms the stimulus really drives the chip's functions
// on the die model (so the comparison covers the real behaviour).
task automatic expect_(input bit cond, input string what);
	if (!cond) begin
		$display("WARN cycle %0d: expectation not met: %s", cycle, what);
		nwarn = nwarn + 1;
	end else
		$display("INFO cycle %0d: %s", cycle, what);
endtask

always @(HL_a) if (!rand_phase) $display("INFO cycle %0d t=%0t HL(die) -> %b", cycle, $time, HL_a);
always @(FRES_a) if (!rand_phase) $display("INFO cycle %0d t=%0t FRES(die) -> %b", cycle, $time, FRES_a);

// ---------------------------------------------------------------- stimulus helpers
task automatic tick(input integer n);
	repeat (n) @(negedge MCLK);
endtask

// I/O chip register offsets (VA[6:0] of A10000 + 2*offset + 1)
function automatic [22:0] ioaddr(input [6:0] r);
	return 23'h508000 | {16'h0, r};
endfunction
function automatic [6:0] r_data(input integer p); return 7'h1 + p[6:0]; endfunction   // A10003/5/7
function automatic [6:0] r_ctrl(input integer p); return 7'h4 + p[6:0]; endfunction   // A10009/B/D
function automatic [6:0] r_txd(input integer p);  return p == 0 ? 7'h7 : p == 1 ? 7'hA : 7'hD; endfunction
function automatic [6:0] r_rxd(input integer p);  return p == 0 ? 7'h8 : p == 1 ? 7'hB : 7'hE; endfunction
function automatic [6:0] r_sct(input integer p);  return p == 0 ? 7'h9 : p == 1 ? 7'hC : 7'hF; endfunction

// 68000 bus cycle aligned to VCLK (S0 starts on a rising edge; states are half clocks):
// S0 address, S1 R/W, S2 /AS (+data strobes and the VDP's CAS0 on reads), S3 write data,
// S4 write strobes (+LWR), S5-S6 hold (data latched end of S6), S7 negate, R/W back high.
task automatic bus68k(input [22:0] addr, input bit read, input bit u, input bit l, input [15:0] wdata, output [7:0] rdata);
	@(posedge VCLK); VA = addr;                                          // S0
	@(negedge VCLK); RW = read;                                          // S1
	@(posedge VCLK); AS = 0;                                             // S2
	if (read) begin UDS = ~u; LDS = ~l; CAS0 = (VA[22:20] == 3'h7); end  //   VDP: no CAS0 for its own region
	@(negedge VCLK); if (!read) VD_i = wdata;                            // S3
	@(posedge VCLK); if (!read) begin UDS = ~u; LDS = ~l; LWR = ~l; end  // S4
	@(negedge VCLK);                                                     // S5
	@(posedge VCLK); rdata = vdata_a;                                    // S6 (68000 latches at its end)
	@(negedge VCLK); AS = 1; UDS = 1; LDS = 1; CAS0 = 1; LWR = 1;        // S7
	@(posedge VCLK); RW = 1; VD_i = $urandom;                            // bus released
endtask

// the same with an asynchronous SRES pulse starting `at` MCLK cycles after S0, `len` cycles long
task automatic bus68k_sres(input [22:0] addr, input bit read, input bit u, input bit l, input [15:0] wdata, input integer at, input integer len);
	reg [7:0] r;
	fork
		begin tick(at); SRES = 0; tick(len); SRES = 1; end
		bus68k(addr, read, u, l, wdata, r);
	join
endtask

// Z80 I/O cycle (SMS mode): T1 address, T2 /IORQ + /RD or /WR, TW, /IORQ released mid T3
task automatic busz80(input [7:0] addr, input bit read, input [7:0] wdata, output [7:0] rdata);
	tick(TZ80 / 2); ZA_i = addr;
	tick(TZ80); IORQ = 0;
	if (read) CAS0 = 0; else begin ZD_i = wdata; LWR = 0; end
	tick(TZ80 + TZ80 / 2);
	rdata = zdata_a;
	IORQ = 1; CAS0 = 1; LWR = 1;
	tick(TZ80 / 2); ZD_i = $urandom;
endtask

// Z80 -> 68000 bus bridge cycle (MD mode): arbiter drops ZV, runs a 68000-like cycle on the Z80's behalf
task automatic zbridge(input bit read, input [7:0] za, input [7:0] zd);
	@(posedge VCLK); ZA_i = za; zv_r = 0;
	@(negedge VCLK);
	@(posedge VCLK); if (read) CAS0 = 0; else begin ZD_i = zd; LWR = 0; end
	repeat (3) @(posedge VCLK);
	@(negedge VCLK); CAS0 = 1; LWR = 1;
	@(posedge VCLK); zv_r = 1; ZD_i = $urandom;
endtask

// 6-button read sequence on port p: TH output, then TH 1/0 x4 with a data read after each edge
task automatic pad_seq(input integer p);
	reg [7:0] r;
	integer k;
	bus68k(ioaddr(r_ctrl(p)), 0, 0, 1, 16'h0040, r);
	for (k = 0; k < 8; k = k + 1) begin
		bus68k(ioaddr(r_data(p)), 0, 0, 1, (k & 1) ? 16'h0000 : 16'h0040, r);
		bus68k(ioaddr(r_data(p)), 1, 0, 1, 16'h0, r);
	end
	bus68k(ioaddr(r_data(p)), 0, 0, 1, 16'h0040, r);
endtask

// one poll step of controller traffic, used while a UART frame is in flight
integer poll_k = 0;
task automatic pad_poll_step();
	reg [7:0] r;
	poll_k = poll_k + 1;
	case (poll_k % 4)
		0: bus68k(ioaddr(r_data(1)), 0, 0, 1, 16'h0040, r);
		1: bus68k(ioaddr(r_data(1)), 1, 0, 1, 16'h0, r);
		2: bus68k(ioaddr(r_data(1)), 0, 0, 1, 16'h0000, r);
		default: bus68k(ioaddr(r_data(2)), 1, 0, 1, 16'h0, r);
	endcase
endtask

// UART frame on port p through the loopback cable: configure S-CTRL (baud, SIN, SOUT, RINT),
// write TxData, poll S-CTRL for RRDY, read RxData and check it, RRDY must clear
task automatic uart_xfer(input integer p, input [7:0] data, input [1:0] baud, input integer maxpoll, input integer pollgap);
	reg [7:0] r;
	integer n;
	bus68k(ioaddr(r_sct(p)), 0, 0, 1, {8'h0, baud, 3'b111, 3'b000}, r);
	bus68k(ioaddr(r_txd(p)), 0, 0, 1, {8'h0, data}, r);
	bus68k(ioaddr(r_sct(p)), 1, 0, 1, 16'h0, r);
	expect_(r[0] == 1, $sformatf("port %0d baud %0d: TFUL set right after the TxData write (sctrl=%h)", p, baud, r));
	n = 0;
	do begin
		pad_poll_step();
		tick(pollgap);
		bus68k(ioaddr(r_sct(p)), 1, 0, 1, 16'h0, r);
		n = n + 1;
	end while (!r[1] && n < maxpoll);
	expect_(r[1] == 1, $sformatf("port %0d baud %0d: RRDY after the loopback frame (%0d polls, sctrl=%h)", p, baud, n, r));
	expect_(r[2] == 0, $sformatf("port %0d baud %0d: no RERR on a clean frame", p, baud));
	expect_(r[0] == 0, $sformatf("port %0d baud %0d: TFUL cleared after the frame", p, baud));
	expect_(HL_a == 0, "HL asserted by RRDY & RINT");
	bus68k(ioaddr(r_rxd(p)), 1, 0, 1, 16'h0, r);
	expect_(r == data, $sformatf("port %0d baud %0d: RxData %h == TxData %h", p, baud, r, data));
	bus68k(ioaddr(r_sct(p)), 1, 0, 1, 16'h0, r);
	expect_(r[1] == 0, $sformatf("port %0d baud %0d: RRDY cleared by the RxData read", p, baud));
endtask

// constrained-random 68000 cycle: I/O chip registers most of the time, random strobe timing,
// mid-cycle data/address changes, IO glitches
task automatic bus_rand();
	integer cls, hold, pre, sdel, gl;
	reg [22:0] a;
	reg [15:0] d;
	reg rd, u, l;
	cls = $urandom_range(0, 15);
	case (cls)
		0, 1, 2, 3, 4, 5, 6: a = 23'h508000 | 23'($urandom_range(0, 15));           // A10001..A1001F
		7:       a = 23'h508000 | 23'($urandom_range(16, 127));                    // A10021..A100FF (IO low, vsel high)
		8:       a = 23'h508000 ^ (23'h1 << $urandom_range(7, 22));                // one-bit-off near miss
		9:       a = {8'hA0, 15'($urandom)};                                        // Z80 space (VZ)
		10:      a = {3'h6, 20'($urandom)};                                         // VDP region (no CAS0)
		11:      a = 23'h50A000 | 23'($urandom_range(0, 255));                      // TMSS registers
		default: a = 23'($urandom);
	endcase
	rd = $urandom_range(0, 1);
	u  = ($urandom_range(0, 3) != 0);
	l  = ($urandom_range(0, 4) != 0);
	case ($urandom_range(0, 9))
		0: d = 16'h0040; 1: d = 16'h0000; 2: d = 16'h0060; 3: d = 16'h0038; 4: d = 16'h00FF; 5: d = 16'h0080;
		default: d = 16'($urandom);
	endcase
	hold = $urandom_range(2, 40);
	pre  = $urandom_range(0, 3);
	sdel = $urandom_range(0, 3); if (sdel >= hold) sdel = 0;
	gl   = $urandom_range(0, 11);
	@(negedge MCLK); VA = a; RW = rd;
	tick(pre);
	AS = 0; VD_i = d;
	tick(sdel);
	if (rd) CAS0 = ~(u | l) | (a[22:20] == 3'h7); else LWR = ~l;
	UDS = ~u; LDS = ~l;
	if (gl == 0 && hold - sdel > 2) begin        // data changes while the write strobe is low
		tick(1); VD_i = 16'($urandom); tick(hold - sdel - 1);
	end else if (gl == 1 && hold - sdel > 2) begin // address changes mid-cycle
		tick(1); VA = a ^ 23'(1 << $urandom_range(0, 6)); tick(hold - sdel - 1);
	end else if (gl == 2 && hold - sdel > 3) begin // IO glitch mid-cycle
		tick(1); io_force = 1; tick(1); io_force = 0; tick(hold - sdel - 2);
	end else if (gl == 3 && hold - sdel > 3) begin // strobe glitch mid-cycle
		tick(1); CAS0 = 1; LWR = 1; tick(1); if (rd) CAS0 = 0; else LWR = 0; tick(hold - sdel - 2);
	end else
		tick(hold - sdel);
	case ($urandom_range(0, 2))
		0: begin UDS = 1; LDS = 1; CAS0 = 1; LWR = 1; @(negedge MCLK); AS = 1; end
		1: begin AS = 1; @(negedge MCLK); UDS = 1; LDS = 1; CAS0 = 1; LWR = 1; end
		default: begin AS = 1; UDS = 1; LDS = 1; CAS0 = 1; LWR = 1; end
	endcase
	if ($urandom_range(0, 3) == 0) VD_i = 16'($urandom);
	tick($urandom_range(0, 1));
	if ($urandom_range(0, 9) != 0) RW = 1;
	tick($urandom_range(0, 8));
endtask

// constrained-random Z80 I/O cycle (SMS mode): ports 3E/3F/C0/C1/DC/DD and near misses, random lengths
task automatic z80_rand();
	integer hold, pre;
	reg [7:0] a, d;
	reg rd;
	case ($urandom_range(0, 9))
		0, 1: a = 8'h3F;
		2:    a = 8'h3E;
		3, 4: a = 8'hDC;
		5:    a = 8'hDD;
		6:    a = 8'hC0 | 8'($urandom_range(0, 1));
		7:    a = 8'h3F ^ (8'h1 << $urandom_range(1, 7));
		default: a = 8'($urandom);
	endcase
	rd = $urandom_range(0, 1);
	d = 8'($urandom);
	hold = $urandom_range(2, 90);
	pre = $urandom_range(0, 20);
	@(negedge MCLK); ZA_i = a;
	tick(pre);
	IORQ = 0;
	tick($urandom_range(0, 2));
	if (rd) CAS0 = 0; else begin ZD_i = d; LWR = 0; end
	tick(hold);
	if ($urandom_range(0, 1)) begin IORQ = 1; tick(1); CAS0 = 1; LWR = 1; end
	else begin CAS0 = 1; LWR = 1; IORQ = 1; end
	tick($urandom_range(0, 10));
	if ($urandom_range(0, 1)) ZD_i = 8'($urandom);
endtask

// ---------------------------------------------------------------- random side processes
integer sseed;
initial begin
	integer s;
	if (!$value$plusargs("SEED=%d", s)) s = 1;
	void'($urandom(s * 7919 + 1));
	wait (rand_phase);
	while (rand_phase) begin
		@(negedge MCLK);
		if ($urandom_range(0, 999) < 5)  test = $urandom;
		if ($urandom_range(0, 999) < 3)  NTSC = $urandom;
		if ($urandom_range(0, 999) < 3)  DISK = $urandom;
		if ($urandom_range(0, 999) < 3)  JAP = $urandom;
		if ($urandom_range(0, 999) < 2)  t1 = $urandom;
		if ($urandom_range(0, 999) < 3)  tmss_enable = $urandom;
		if ($urandom_range(0, 999) < 20) ZA_i = 8'($urandom);
		if ($urandom_range(0, 999) < 20) ZD_i = 8'($urandom);
		if ($urandom_range(0, 999) < 8)  ZBAK = $urandom;
		if ($urandom_range(0, 999) < 4)  zv_force = $urandom;
		if ($urandom_range(0, 999) < 4)  vz_force = $urandom;
		if ($urandom_range(0, 999) < 2)  io_force = $urandom;
	end
end
initial begin
	integer s;
	if (!$value$plusargs("SEED=%d", s)) s = 1;
	void'($urandom(s * 7919 + 2));
	wait (rand_phase);
	while (rand_phase) begin
		@(negedge MCLK);
		if ($urandom_range(0, 999) < 6)  btn_a = 12'($urandom);
		if ($urandom_range(0, 999) < 6)  btn_b = 12'($urandom);
		if ($urandom_range(0, 999) < 6)  btn_c = 12'($urandom);
		if ($urandom_range(0, 999) < 2)  kind_a = 2'($urandom_range(0, 2));
		if ($urandom_range(0, 999) < 2)  kind_b = 2'($urandom_range(0, 2));
		if ($urandom_range(0, 999) < 2)  kind_c = 2'($urandom_range(0, 2));
		if ($urandom_range(0, 999) < 2)  loop_a = $urandom;
		if ($urandom_range(0, 999) < 2)  loop_b = $urandom;
		if ($urandom_range(0, 999) < 2)  loop_c = $urandom;
		if ($urandom_range(0, 999) < 3)  ext6_a = $urandom;
		if ($urandom_range(0, 999) < 3)  ext6_b = $urandom;
		if ($urandom_range(0, 999) < 3)  ext6_c = $urandom;
		if ($urandom_range(0, 999) < 2)  dly_a = $urandom_range(0, 15);
		if ($urandom_range(0, 999) < 2)  dly_b = $urandom_range(0, 15);
		if ($urandom_range(0, 999) < 2)  dly_c = $urandom_range(0, 15);
		// single-cycle glitches on the pad lines
		if ($urandom_range(0, 999) < 4) begin gl_a = 7'($urandom); @(negedge MCLK); gl_a = 7'h0; end
		if ($urandom_range(0, 999) < 4) begin gl_b = 7'($urandom); @(negedge MCLK); gl_b = 7'h0; end
		if ($urandom_range(0, 999) < 4) begin gl_c = 7'($urandom); @(negedge MCLK); gl_c = 7'h0; end
	end
end
initial begin
	integer s;
	if (!$value$plusargs("SEED=%d", s)) s = 1;
	void'($urandom(s * 7919 + 3));
	wait (rand_phase);
	while (rand_phase) begin
		@(negedge MCLK);
		if ($urandom_range(0, 9999) < 4) begin      // asynchronous SRES pulses, anywhere in a cycle
			SRES = 0;
			tick($urandom_range(1, 60));
			SRES = 1;
		end
	end
end

// ---------------------------------------------------------------- main
integer seed;
integer n_random;
integer real_uart;
reg [7:0] r;
initial begin
	if (!$value$plusargs("SEED=%d", seed)) seed = 1;
	if (!$value$plusargs("NRAND=%d", n_random)) n_random = 250000;
	if (!$value$plusargs("REALUART=%d", real_uart)) real_uart = 1;
	void'($urandom(seed));
	$display("tb_ym6046: seed=%0d random cycles=%0d real-speed uart frame=%0d", seed, n_random, real_uart);

	// ---- directed: power-up, SRES
	tick(20);
	SRES = 0; tick(300); SRES = 1; tick(60);
	xcheck_en = 1;
	expect_(FRES_a == 0, "FRES (Z80/FM reset, active low) released after SRES via the VCLK synchroniser");
	expect_(u_die.reset == 1, "internal reset released");

	// version register (A10001) byte and word reads, and the even byte (UDS only)
	bus68k(23'h508000, 1, 0, 1, 16'h0, r);
	expect_(r == {JAP, ~NTSC, DISK, 4'h0, tmss_enable}, $sformatf("version register = %h", r));
	bus68k(23'h508000, 1, 1, 1, 16'h0, r);
	bus68k(23'h508000, 1, 1, 0, 16'h0, r);
	// A100xx above the register window: IO low but vsel high -> no register access
	bus68k(23'h508010, 1, 0, 1, 16'h0, r);
	bus68k(23'h508010, 0, 0, 1, 16'h0040, r);
	// pad reads, all three ports, TH toggling (6-button on A, echo device on B, 3-button on C)
	btn_a = 12'h0A5; btn_c = 12'h033;
	pad_seq(0);
	pad_seq(2);
	// reads of all registers (data, control, txd, rxd, sctrl)
	for (int k = 1; k < 16; k = k + 1) bus68k(ioaddr(7'(k)), 1, 0, 1, 16'h0, r);
	// TH/TR handshake on port B: TH, TR outputs; TR toggles, the device echoes it on TL
	bus68k(ioaddr(r_ctrl(1)), 0, 0, 1, 16'h0060, r);
	for (int k = 0; k < 6; k = k + 1) begin
		bus68k(ioaddr(r_data(1)), 0, 0, 1, (k & 1) ? 16'h0040 : 16'h0060, r);
		bus68k(ioaddr(r_data(1)), 1, 0, 1, 16'h0, r);
		expect_(r[4] == ((k & 1) ? 1'b0 : 1'b1), $sformatf("handshake: TL echoes TR=%0d (data=%h)", (k & 1) ? 0 : 1, r));
	end
	// TH interrupt on port B: TH input, INT enable (bit 7), device pulls TH low -> HL
	bus68k(ioaddr(r_ctrl(1)), 0, 0, 1, 16'h0080, r);
	expect_(HL_a == 1, "HL idle before the TH interrupt");
	ext6_b = 0; tick(30);
	expect_(HL_a == 0, "HL asserted by TH low on port B with INT enabled");
	bus68k(ioaddr(r_data(1)), 1, 0, 1, 16'h0, r);
	ext6_b = 1; tick(30);
	expect_(HL_a == 1, "HL released when TH returns high");
	bus68k(ioaddr(r_ctrl(1)), 0, 0, 1, 16'h0000, r);
	// word writes (UDS+LDS) and a data write with bit 7 (readable in the data register)
	bus68k(ioaddr(r_data(0)), 0, 1, 1, 16'hC0C0, r);
	bus68k(ioaddr(r_data(0)), 1, 0, 1, 16'h0, r);
	expect_(r[7] == 1, "data register bit 7 readable");
	bus68k(ioaddr(r_ctrl(0)), 0, 1, 1, 16'h7F7F, r);   // all outputs
	bus68k(ioaddr(r_data(0)), 0, 0, 1, 16'h0055, r);
	bus68k(ioaddr(r_data(0)), 1, 0, 1, 16'h0, r);
	expect_(r[6:0] == 7'h55, $sformatf("driven pins read back their output (%h)", r));
	bus68k(ioaddr(r_ctrl(0)), 0, 0, 1, 16'h0040, r);

	// ---- UART, test mode (uart_clk2 = VCLK: bit clock VCLK/16 at baud 0), loopback cable on each port
	test = 1;
	tick(100);
	loop_a = 1; kind_a = 1;
	uart_xfer(0, 8'h55, 2'd0, 60, 200);
	uart_xfer(0, 8'hA3, 2'd0, 60, 200);
	uart_xfer(0, 8'h0F, 2'd1, 60, 400);
	// back-to-back writes: second byte overwrites while TFUL (tx_data latch), then the frame completes
	bus68k(ioaddr(r_txd(0)), 0, 0, 1, 16'h0011, r);
	bus68k(ioaddr(r_txd(0)), 0, 0, 1, 16'h0022, r);
	for (int k = 0; k < 20; k = k + 1) begin pad_poll_step(); tick(200); end
	bus68k(ioaddr(r_sct(0)), 1, 0, 1, 16'h0, r);
	bus68k(ioaddr(r_rxd(0)), 1, 0, 1, 16'h0, r);
	$display("INFO back-to-back TxData writes: RxData=%h", r);
	// break on the RX line (TR held low, no loopback) -> frame error
	loop_a = 0; btn_a = 12'h020;   // C pressed = TR low
	tick(6000);
	btn_a = 12'h000;
	tick(2000);
	bus68k(ioaddr(r_sct(0)), 1, 0, 1, 16'h0, r);
	expect_(r[1] == 1 && r[2] == 1, $sformatf("break on TR: RRDY and RERR (sctrl=%h)", r));
	bus68k(ioaddr(r_rxd(0)), 1, 0, 1, 16'h0, r);
	bus68k(ioaddr(r_sct(0)), 1, 0, 1, 16'h0, r);
	expect_(r[2] == 0, "RERR cleared by the RxData read");
	// port B and C at other baud settings
	loop_b = 1; kind_b = 1;
	uart_xfer(1, 8'hC3, 2'd0, 60, 200);
	uart_xfer(1, 8'h81, 2'd2, 80, 800);
	loop_c = 1;
	uart_xfer(2, 8'h3C, 2'd3, 120, 1500);
	loop_b = 0; kind_b = 2;
	// SIN off while receiving, SOUT off while sending (s_control resets the shifters)
	bus68k(ioaddr(r_sct(2)), 0, 0, 1, 16'h0038, r);
	bus68k(ioaddr(r_txd(2)), 0, 0, 1, 16'h00E7, r);
	tick(600);
	bus68k(ioaddr(r_sct(2)), 0, 0, 1, 16'h0008, r);
	tick(600);
	bus68k(ioaddr(r_sct(2)), 0, 0, 1, 16'h0000, r);
	loop_c = 0;
	test = 0;

	// ---- Z80 bridge cycles (ZV) and 68000 accesses to the Z80 space (VZ) in MD mode
	zbridge(1, 8'h00, 8'h00);
	zbridge(0, 8'h01, 8'h5A);
	zbridge(1, 8'hFF, 8'h00);
	ZBAK = 0;
	bus68k(23'h500000, 1, 1, 1, 16'h0, r);
	bus68k(23'h500001, 0, 0, 1, 16'h1234, r);
	bus68k(23'h507FFF, 0, 1, 0, 16'h5678, r);
	ZBAK = 1;
	bus68k(23'h500000, 1, 1, 1, 16'h0, r);
	// pin inputs during reads
	NTSC = 0; bus68k(23'h508000, 1, 0, 1, 16'h0, r); expect_(r[6] == 1, "PAL bit follows NTSC low");
	DISK = 0; JAP = 1; tmss_enable = 0; bus68k(23'h508000, 1, 0, 1, 16'h0, r);
	expect_(r == 8'hC0, $sformatf("version register with JAP=1 PAL DISK=0 tmss_enable=0: %h", r));
	NTSC = 1; DISK = 1; JAP = 0; tmss_enable = 1;
	test = 1; bus68k(23'h508000, 1, 0, 1, 16'h0, r); test = 0;
	t1 = 1; bus68k(23'h508000, 1, 0, 1, 16'h0, r); t1 = 0;

	// ---- SRES in the middle of bus cycles (control write, version read, TxData write, data write)
	bus68k_sres(ioaddr(r_ctrl(0)), 0, 0, 1, 16'h0040, 30, 5);
	bus68k_sres(23'h508000, 1, 0, 1, 16'h0, 18, 40);
	bus68k_sres(ioaddr(r_txd(0)), 0, 0, 1, 16'h0077, 35, 3);
	bus68k_sres(ioaddr(r_data(2)), 0, 0, 1, 16'h0000, 5, 80);
	tick(40);

	// ---- SMS mode (M3 = 0): Z80 I/O ports 3E/3F/DC/DD/C0/C1, light gun TH -> HL
	SRES = 0; tick(30); M3 = 0; tick(60); SRES = 1; tick(60);
	kind_a = 1; kind_b = 1; btn_a = 12'h00F; btn_b = 12'h0F0;
	busz80(8'h3F, 0, 8'hFF, r);                 // all TH/TR inputs
	busz80(8'hDC, 1, 8'h00, r); $display("INFO SMS port DC = %h", r);
	busz80(8'hDD, 1, 8'h00, r); $display("INFO SMS port DD = %h", r);
	busz80(8'h3F, 0, 8'h00, r);                 // TH/TR outputs, low
	busz80(8'hDC, 1, 8'h00, r);
	busz80(8'hDD, 1, 8'h00, r);
	busz80(8'h3F, 0, 8'hF5, r);                 // TH out high, TR in on both
	busz80(8'hDD, 1, 8'h00, r);
	busz80(8'h3F, 0, 8'h0A, r);
	busz80(8'hDD, 1, 8'h00, r);
	busz80(8'h3F, 0, 8'hFF, r);
	expect_(HL_a == 1, "SMS: HL idle with TH inputs high");
	ext6_a = 0; tick(40);
	expect_(HL_a == 0, "SMS: HL (light gun latch) asserted by TH low on port A");
	ext6_a = 1; tick(40);
	ext6_b = 0; tick(40); ext6_b = 1; tick(40);
	busz80(8'h3E, 0, 8'hA8, r);                 // memory control, bit 4 -> reg_3e_q
	expect_(reg_3e_q_a == 0, "reg_3e_q follows port 3E bit 4 (0)");
	busz80(8'h3E, 0, 8'hB8, r);
	expect_(reg_3e_q_a == 1, "reg_3e_q follows port 3E bit 4 (1)");
	busz80(8'hC0, 1, 8'h00, r);
	busz80(8'hC1, 1, 8'h00, r);
	busz80(8'h7E, 1, 8'h00, r);                 // VDP V counter: not this chip
	busz80(8'hBF, 0, 8'h80, r);
	fork
		begin tick(50); SRES = 0; tick(20); SRES = 1; end
		busz80(8'h3F, 0, 8'h55, r);
	join
	busz80(8'h3F, 0, 8'hFF, r);
	// back to MD mode
	SRES = 0; tick(30); M3 = 1; tick(60); SRES = 1; tick(60);
	kind_a = 0; kind_b = 2; kind_c = 1; btn_a = 0; btn_b = 0;

	// ---- one real-speed UART frame (test = 0: uart_clk from cnt1/cnt2, 4800 bps at baud 0),
	//      with controller traffic in parallel while it is in flight
	if (real_uart) begin
		loop_a = 1; kind_a = 1;
		uart_xfer(0, 8'h96, 2'd0, 400, 1200);
		loop_a = 0; kind_a = 0;
	end
	$display("INFO directed phase done at cycle %0d, warnings=%0d", cycle, nwarn);

	// ---- constrained random
	rand_phase = 1;
	while (cycle < n_random + 5000) begin
		if (!M3) begin
			if ($urandom_range(0, 19) == 0) begin SRES = 0; tick($urandom_range(5, 60)); M3 = 1; tick(20); SRES = 1; end
			else z80_rand();
		end else begin
			case ($urandom_range(0, 39))
				0:       begin SRES = 0; tick($urandom_range(5, 60)); M3 = 0; tick(20); SRES = 1; end
				1, 2:    zbridge($urandom, 8'($urandom), 8'($urandom));
				3:       tick($urandom_range(1, 400));
				default: bus_rand();
			endcase
		end
	end
	rand_phase = 0;
	tick(10);
	$display("PASS: %0d MCLK cycles, %0d compare points, %0d signals per compare point, %0d mismatches, %0d directed warnings", cycle, ncmp, nsig, nmis, nwarn);
	$finish;
end

initial begin repeat (3000000) @(posedge MCLK); $display("TIMEOUT cycle=%0d", cycle); $finish; end

endmodule
