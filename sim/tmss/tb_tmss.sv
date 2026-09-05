// tmss A/B equivalence bench: die model `tmss` (rtl/nuked-md/tmss.v) against the 1:1
// synthesis-friendly `tmss_rtl` (rtl/nuked-md/tmss_rtl.v). Identical stimulus into both;
// every output and every storage element compared twice per MCLK cycle:
//   - at posedge MCLK, before the non-blocking updates land (the values the flops sample)
//   - a quarter period after posedge (the values produced by that edge, same inputs)
// Stimulus is applied at negedge MCLK only. First mismatch prints cycle/signal/values and
// stops the run with FAIL.
`timescale 1ps/1ps
module tb_tmss;

// MCLK 107.38635 MHz (md_board MCLK2), same as sim_sub
reg MCLK = 0;
always #4656 MCLK = ~MCLK;        // 9.312 ns
localparam T68 = 14;              // MCLK cycles per 68000 clock (107.386 / 7.67 MHz)

// ---------------------------------------------------------------- inputs (shared)
reg  [15:0] VD_i = 16'h0000;
reg  [2:0]  test = 3'h7;          // {TEST3,TEST2,TEST1} = 111 on md_board: normal mode (test_4 = 0)
reg         JAP = 1;
reg         AS = 1, LDS = 1, UDS = 1, RW = 1;
reg  [22:0] VA = 23'h0;
reg         SRES = 1;
reg         CE0_i = 1;
reg         M3 = 1;
reg         CART = 0;
reg         INTAK = 1;
reg         tmss_enable = 1;
reg  [15:0] tmss_data = 16'h4E71;

// ---------------------------------------------------------------- outputs A (die) / B (rtl)
wire [15:0] VD_o_a, VD_o_b;
wire        DTACK_a, DTACK_b, RESET_a, RESET_b, CE0_o_a, CE0_o_b;
wire        test_0_a, test_1_a, test_2_a, test_3_a, test_4_a;
wire        test_0_b, test_1_b, test_2_b, test_3_b, test_4_b;
wire        data_out_en_a, data_out_en_b;
wire [9:0]  tmss_address_a, tmss_address_b;

tmss u_die (
	.MCLK(MCLK), .VD_i(VD_i), .test(test), .JAP(JAP), .AS(AS), .LDS(LDS), .UDS(UDS), .RW(RW),
	.VA(VA), .SRES(SRES), .CE0_i(CE0_i), .M3(M3), .CART(CART), .INTAK(INTAK),
	.VD_o(VD_o_a), .DTACK(DTACK_a), .RESET(RESET_a), .CE0_o(CE0_o_a),
	.test_0(test_0_a), .test_1(test_1_a), .test_2(test_2_a), .test_3(test_3_a), .test_4(test_4_a),
	.data_out_en(data_out_en_a), .tmss_enable(tmss_enable), .tmss_data(tmss_data), .tmss_address(tmss_address_a));

tmss_rtl u_rtl (
	.MCLK(MCLK), .VD_i(VD_i), .test(test), .JAP(JAP), .AS(AS), .LDS(LDS), .UDS(UDS), .RW(RW),
	.VA(VA), .SRES(SRES), .CE0_i(CE0_i), .M3(M3), .CART(CART), .INTAK(INTAK),
	.VD_o(VD_o_b), .DTACK(DTACK_b), .RESET(RESET_b), .CE0_o(CE0_o_b),
	.test_0(test_0_b), .test_1(test_1_b), .test_2(test_2_b), .test_3(test_3_b), .test_4(test_4_b),
	.data_out_en(data_out_en_b), .tmss_enable(tmss_enable), .tmss_data(tmss_data), .tmss_address(tmss_address_b));

// ---------------------------------------------------------------- comparator
integer cycle = 0;                // MCLK edges seen
integer ncmp = 0;                 // compare points (2 per cycle)
integer nmis = 0;
integer nwarn = 0;
reg xcheck_en = 0;                // after the first SRES: no X allowed anywhere
reg rand_phase = 0;

`define CMP(NAME, A, B) \
	if ((A) !== (B)) begin \
		$display("MISMATCH cycle %0d t=%0t (%s) %s: die=%h rtl=%h", cycle, $time, phase, NAME, A, B); \
		nmis = nmis + 1; \
	end

wire [34:0] outs_a = {VD_o_a, DTACK_a, RESET_a, CE0_o_a, test_0_a, test_1_a, test_2_a, test_3_a, test_4_a, data_out_en_a, tmss_address_a};
wire [34:0] outs_b = {VD_o_b, DTACK_b, RESET_b, CE0_o_b, test_0_b, test_1_b, test_2_b, test_3_b, test_4_b, data_out_en_b, tmss_address_b};

task automatic check(input string phase);
	ncmp = ncmp + 1;
	// every output
	`CMP("VD_o",         VD_o_a,         VD_o_b)
	`CMP("DTACK",        DTACK_a,        DTACK_b)
	`CMP("RESET",        RESET_a,        RESET_b)
	`CMP("CE0_o",        CE0_o_a,        CE0_o_b)
	`CMP("test_0",       test_0_a,       test_0_b)
	`CMP("test_1",       test_1_a,       test_1_b)
	`CMP("test_2",       test_2_a,       test_2_b)
	`CMP("test_3",       test_3_a,       test_3_b)
	`CMP("test_4",       test_4_a,       test_4_b)
	`CMP("data_out_en",  data_out_en_a,  data_out_en_b)
	`CMP("tmss_address", tmss_address_a, tmss_address_b)
	// every storage element (hierarchical into the primitives / inline regs)
	`CMP("dff1.l1",  u_die.dff1.l1, u_rtl.dff1_l1)
	`CMP("dff1.l2",  u_die.dff1.l2, u_rtl.dff1_l2)
	`CMP("dff2.l1",  u_die.dff2.l1, u_rtl.dff2_l1)
	`CMP("dff2.l2",  u_die.dff2.l2, u_rtl.dff2_l2)
	`CMP("dff3.l1",  u_die.dff3.l1, u_rtl.dff3_l1)
	`CMP("dff3.l2",  u_die.dff3.l2, u_rtl.dff3_l2)
	`CMP("sl1.mem",  u_die.sl1.mem, u_rtl.sl1_mem)
	`CMP("sl2.mem",  u_die.sl2.mem, u_rtl.sl2_mem)
	// after the first reset nothing may be X in either model
	if (xcheck_en && ($isunknown(outs_a) || $isunknown(outs_b))) begin
		$display("MISMATCH cycle %0d t=%0t (%s) X on an output: die=%b rtl=%b", cycle, $time, phase, outs_a, outs_b);
		nmis = nmis + 1;
	end
	if (nmis != 0) begin
		$display("FAIL after %0d cycles (%0d compare points): %0d mismatch(es)", cycle, ncmp, nmis);
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
// Not part of the equivalence proof: confirms the stimulus really performs the TMSS
// sequence on the die model (so the comparison covers the real behaviour).
task automatic expect_(input bit cond, input string what);
	if (!cond) begin
		$display("WARN cycle %0d: expectation not met: %s", cycle, what);
		nwarn = nwarn + 1;
	end else
		$display("INFO cycle %0d: %s", cycle, what);
endtask

always @(RESET_a) if (!rand_phase) $display("INFO cycle %0d t=%0t RESET(die) -> %b", cycle, $time, RESET_a);
always @(CE0_o_a) if (!rand_phase) $display("INFO cycle %0d t=%0t CE0_o(die) -> %b (CE0_i=%b)", cycle, $time, CE0_o_a, CE0_i);

// ---------------------------------------------------------------- stimulus helpers
task automatic tick(input integer n);
	repeat (n) @(negedge MCLK);
endtask

// 68000-style bus cycle, no wait states: S0 addr, S1 R/W, S2 /AS (+strobes on read),
// S3 write data, S4 write strobes, S5-S6, S7 negate; R/W back high after.
// u/l = 1 -> that strobe asserted. addr is VA (A23..A1).
task automatic bus68k(input [22:0] addr, input bit read, input bit u, input bit l, input [15:0] wdata);
	@(negedge MCLK); VA = addr;                    // S0
	tick(T68/2);
	RW = read;                                     // S1
	tick(T68/2);
	AS = 0; if (read) begin UDS = ~u; LDS = ~l; end // S2
	tick(T68/2);
	if (!read) VD_i = wdata;                       // S3
	tick(T68/2);
	if (!read) begin UDS = ~u; LDS = ~l; end       // S4
	tick(3*T68/2);                                 // S4..S6
	AS = 1; UDS = 1; LDS = 1;                      // S7
	tick(T68/2);
	RW = 1; VD_i = $urandom;                       // bus released
	tick(T68/2);
endtask

// bus cycle with an asynchronous SRES pulse in the middle of it
task automatic bus68k_sres(input [22:0] addr, input bit read, input [15:0] wdata, input integer at, input integer len);
	@(negedge MCLK); VA = addr;
	tick(T68/2);
	RW = read;
	tick(T68/2);
	AS = 0; if (read) begin UDS = 0; LDS = 0; end
	tick(T68/2);
	if (!read) VD_i = wdata;
	tick(T68/2);
	if (!read) begin UDS = 0; LDS = 0; end
	tick(at);
	SRES = 0;
	tick(len);
	SRES = 1;
	tick(3*T68/2 - at - len);
	AS = 1; UDS = 1; LDS = 1;
	tick(T68/2);
	RW = 1; VD_i = $urandom;
	tick(T68/2);
endtask

// constrained-random bus cycle: AS/UDS/LDS low 2..20 MCLK, random ordering and data
task automatic bus_rand();
	integer cls, hold, pre, sdel, gl;
	reg [22:0] a;
	reg [15:0] d;
	reg rd, u, l;
	cls = $urandom_range(0, 11);
	case (cls)
		0, 1:    a = 23'h50A000;                                 // A14000 (SE)
		2, 3:    a = 23'h50A001;                                 // A14002 (GA)
		4, 5:    a = 23'h50A080;                                 // A14100/1 cart enable
		6:       a = {3'h6, 20'($urandom)};                      // VDP region (unlocks reset)
		7:       a = 23'h50A000 | (23'($urandom) & 23'h0000FF);  // near misses in the A14xxx page
		8:       a = 23'h50A080 ^ (23'h1 << $urandom_range(0, 22)); // one-bit-off near miss
		9:       a = 23'($urandom) & 23'h0003FF;                 // TMSS ROM (low addresses)
		default: a = 23'($urandom);
	endcase
	rd = $urandom_range(0, 1);
	u  = ($urandom_range(0, 3) != 0);
	l  = ($urandom_range(0, 3) != 0);
	case ($urandom_range(0, 6))
		0: d = 16'h5345; 1: d = 16'h4741; 2: d = 16'h0001; 3: d = 16'h0000; 4: d = 16'hFFFE;
		default: d = 16'($urandom);
	endcase
	hold = $urandom_range(2, 20);
	pre  = $urandom_range(0, 2);
	sdel = $urandom_range(0, 2); if (sdel >= hold) sdel = 0;
	gl   = $urandom_range(0, 9);
	@(negedge MCLK); VA = a; RW = rd;
	tick(pre);
	AS = 0; VD_i = d;
	tick(sdel);
	UDS = ~u; LDS = ~l;
	if (gl == 0 && hold - sdel > 2) begin        // data changes while the latch is open
		tick(1); VD_i = 16'($urandom); tick(hold - sdel - 1);
	end else if (gl == 1 && hold - sdel > 2) begin // address changes mid-cycle
		tick(1); VA = a ^ 23'h1; tick(hold - sdel - 1);
	end else
		tick(hold - sdel);
	if ($urandom_range(0, 1)) begin UDS = 1; LDS = 1; @(negedge MCLK); AS = 1; end
	else begin AS = 1; UDS = 1; LDS = 1; end
	if ($urandom_range(0, 3) == 0) VD_i = 16'($urandom);
	tick($urandom_range(0, 1));
	if ($urandom_range(0, 9) != 0) RW = 1;
	tick($urandom_range(0, 6));
endtask

// ---------------------------------------------------------------- random side processes
initial begin
	wait (rand_phase);
	while (rand_phase) begin
		@(negedge MCLK);
		if ($urandom_range(0, 99) < 8)  CE0_i = $urandom;
		if ($urandom_range(0, 99) < 2)  test = 3'($urandom);
		if ($urandom_range(0, 99) < 1)  JAP = $urandom;
		if ($urandom_range(0, 99) < 1)  M3 = $urandom;
		if ($urandom_range(0, 99) < 1)  CART = $urandom;
		if ($urandom_range(0, 99) < 5)  INTAK = $urandom;
		if ($urandom_range(0, 99) < 1)  tmss_enable = $urandom;
		if ($urandom_range(0, 99) < 10) tmss_data = 16'($urandom);
	end
end
initial begin
	wait (rand_phase);
	while (rand_phase) begin
		@(negedge MCLK);
		if ($urandom_range(0, 999) < 3) begin      // asynchronous SRES pulses, anywhere in a bus cycle
			SRES = 0;
			tick($urandom_range(1, 40));
			SRES = 1;
		end
	end
end

// ---------------------------------------------------------------- main
integer seed;
integer n_random;
initial begin
	if (!$value$plusargs("SEED=%d", seed)) seed = 1;
	if (!$value$plusargs("NRAND=%d", n_random)) n_random = 250000;
	void'($urandom(seed));
	$display("tb_tmss: seed=%0d random cycles=%0d", seed, n_random);

	// ---- directed: power-up, SRES
	tick(20);
	SRES = 0; tick(120); SRES = 1; tick(30);
	xcheck_en = 1;
	expect_(RESET_a == 1, "RESET (active low) not asserted after SRES");

	// TMSS ROM reads (cart region, CE0_i from the arbiter)
	CE0_i = 0; bus68k(23'h000000, 1, 1, 1, 16'h0); CE0_i = 1;
	CE0_i = 0; bus68k(23'h000002, 1, 1, 1, 16'h0); CE0_i = 1;
	bus68k(23'h000100, 1, 1, 0, 16'h0);
	expect_(CE0_o_a == 1, "CE0_o high (cart disabled) before cart enable");

	// VDP access before SEGA: must NOT release reset
	bus68k(23'h600002, 0, 1, 1, 16'h8004);
	expect_(RESET_a == 0, "RESET asserted by a VDP access without SEGA (TMSS lock)");

	// the real TMSS sequence: 'SE' to A14000, 'GA' to A14002
	bus68k(23'h50A000, 0, 1, 1, 16'h5345);
	bus68k(23'h50A001, 0, 1, 1, 16'h4741);
	expect_(u_die.sl1.mem == 16'h5345 && u_die.sl2.mem == 16'h4741, "SEGA latched in sl1/sl2");
	// read back
	bus68k(23'h50A000, 1, 1, 1, 16'h0);
	bus68k(23'h50A001, 1, 1, 1, 16'h0);
	expect_(RESET_a == 0, "RESET still asserted (locked) until the VDP access after SEGA");
	// VDP access releases RESET
	bus68k(23'h600002, 0, 1, 1, 16'h8004);
	expect_(RESET_a == 1, "RESET released after SEGA + VDP access");

	// cart enable: write $0001 to A14101 (LDS only)
	CE0_i = 0; bus68k(23'h000000, 1, 1, 1, 16'h0); CE0_i = 1;
	expect_(CE0_o_a == 1, "CE0_o still high before cart enable");
	bus68k(23'h50A080, 0, 0, 1, 16'h0001);
	CE0_i = 0; bus68k(23'h000000, 1, 1, 1, 16'h0);
	expect_(CE0_o_a == 0, "CE0_o follows CE0_i after cart enable");
	CE0_i = 1;
	// cart disable again, then re-enable via word write
	bus68k(23'h50A080, 0, 0, 1, 16'h0000);
	CE0_i = 0; tick(4); expect_(CE0_o_a == 1, "CE0_o high again after cart disable"); CE0_i = 1;
	bus68k(23'h50A080, 0, 1, 1, 16'h0101);
	CE0_i = 0; tick(4); expect_(CE0_o_a == 0, "CE0_o follows CE0_i after word-write enable"); CE0_i = 1;
	// byte writes to A14000 (no latch: w15 needs both strobes), wrong data, UDS-only read
	bus68k(23'h50A000, 0, 1, 0, 16'h1234);
	bus68k(23'h50A001, 0, 0, 1, 16'h1234);
	bus68k(23'h50A000, 1, 1, 0, 16'h0);
	bus68k(23'h50A000, 0, 1, 1, 16'h1234);
	bus68k(23'h50A000, 0, 1, 1, 16'h5345);
	// asynchronous SRES mid bus cycle (write to A14002, VDP access, cart enable, read)
	bus68k_sres(23'h50A001, 0, 16'h4741, 5, 3);
	bus68k_sres(23'h600004, 0, 16'h0000, 9, 7);
	bus68k_sres(23'h50A080, 0, 16'h0001, 2, 25);
	bus68k_sres(23'h000010, 1, 16'h0000, 12, 1);
	// input pins and test modes
	for (int k = 0; k < 8; k = k + 1) begin test = 3'(k); bus68k(23'h50A000, 1, 1, 1, 16'h0); end
	test = 3'h7;
	tmss_enable = 0; bus68k(23'h50A000, 0, 1, 1, 16'h5345); bus68k(23'h50A001, 1, 1, 1, 16'h0); tmss_enable = 1;
	JAP = 0; bus68k(23'h600000, 0, 1, 1, 16'h0); JAP = 1;
	M3 = 0; CART = 1; bus68k(23'h000000, 1, 1, 1, 16'h0); M3 = 1; CART = 0;
	INTAK = 0; bus68k(23'h50A000, 1, 1, 1, 16'h0); INTAK = 1;
	// full sequence again from a fresh SRES
	SRES = 0; tick(40); SRES = 1; tick(10);
	bus68k(23'h50A000, 0, 1, 1, 16'h5345);
	bus68k(23'h50A001, 0, 1, 1, 16'h4741);
	bus68k(23'h600002, 1, 1, 1, 16'h0);
	expect_(RESET_a == 1, "RESET released again after second SEGA + VDP read");
	bus68k(23'h50A080, 0, 0, 1, 16'h0001);
	$display("INFO directed phase done at cycle %0d, warnings=%0d", cycle, nwarn);

	// ---- constrained random
	rand_phase = 1;
	while (cycle < n_random + 5000) bus_rand();
	rand_phase = 0;
	tick(10);
	$display("PASS: %0d MCLK cycles, %0d compare points, %0d mismatches, %0d directed warnings", cycle, ncmp, nmis, nwarn);
	$finish;
end

initial begin repeat (2000000) @(posedge MCLK); $display("TIMEOUT cycle=%0d", cycle); $finish; end

endmodule
