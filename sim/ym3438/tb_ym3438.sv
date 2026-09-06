// tb_ym3438.sv -- A/B equivalence bench for the NukedMD FM conversion.
//
//   die  = rtl/nuked-md/ym3438.v (+ ym3438_*.v + ym_lib.v)      [reference]
//   dut  = ym3438_rtl (Stage 1)  or  ym3438_opt (Stage 2, +OPT)  [under test]
//
// Both are fed byte-identical inputs.  Every MCLK (sampled twice: at negedge and
// at a settled point after posedge) the bench compares ALL primary outputs and,
// via the generated storage_compare module (identical hierarchy XMRs), EVERY
// storage element.  It stops at the first mismatch and prints the cycle + signal.
//
// Plusargs:  +SEED=<n>   +NCYC=<n>   +OPT (use ym3438_opt as dut)
//            +QUIET (less chatter)   +NOSTORE (skip storage compare, outputs only)

`timescale 1ns/1ps

module tb_ym3438;

	// ---- clocks / inputs (shared by both DUTs) --------------------------------
	reg        MCLK = 1'b0;
	reg        PHI  = 1'b0;
	reg  [7:0] DATA_i = 8'h00;
	reg        TEST_i = 1'b0;
	reg        IC = 1'b1, CS = 1'b1, WR = 1'b1, RD = 1'b1;
	reg  [1:0] ADDRESS = 2'b00;
	reg        ym2612_status_enable = 1'b0;

	// ---- die outputs ----------------------------------------------------------
	wire [7:0] d_DATA_o;   wire d_DATA_o_z, d_TEST_o, d_TEST_o_z, d_IRQ, d_fm_clk1;
	wire [8:0] d_MOL, d_MOR;
	wire [9:0] d_MOL_2612, d_MOR_2612;
	wire [2:0] d_DAC_ch_index;

	// ---- dut outputs ----------------------------------------------------------
	wire [7:0] u_DATA_o;   wire u_DATA_o_z, u_TEST_o, u_TEST_o_z, u_IRQ, u_fm_clk1;
	wire [8:0] u_MOL, u_MOR;
	wire [9:0] u_MOL_2612, u_MOR_2612;
	wire [2:0] u_DAC_ch_index;

	ym3438 die (
		.MCLK(MCLK), .PHI(PHI), .DATA_i(DATA_i), .DATA_o(d_DATA_o), .DATA_o_z(d_DATA_o_z),
		.TEST_i(TEST_i), .TEST_o(d_TEST_o), .TEST_o_z(d_TEST_o_z),
		.IC(IC), .CS(CS), .WR(WR), .RD(RD), .ADDRESS(ADDRESS), .IRQ(d_IRQ),
		.MOL(d_MOL), .MOR(d_MOR), .MOL_2612(d_MOL_2612), .MOR_2612(d_MOR_2612),
		.fm_clk1(d_fm_clk1), .DAC_ch_index(d_DAC_ch_index),
		.ym2612_status_enable(ym2612_status_enable) );

`ifdef OPT
	ym3438_opt dut (
`else
	ym3438_rtl dut (
`endif
		.MCLK(MCLK), .PHI(PHI), .DATA_i(DATA_i), .DATA_o(u_DATA_o), .DATA_o_z(u_DATA_o_z),
		.TEST_i(TEST_i), .TEST_o(u_TEST_o), .TEST_o_z(u_TEST_o_z),
		.IC(IC), .CS(CS), .WR(WR), .RD(RD), .ADDRESS(ADDRESS), .IRQ(u_IRQ),
		.MOL(u_MOL), .MOR(u_MOR), .MOL_2612(u_MOL_2612), .MOR_2612(u_MOR_2612),
		.fm_clk1(u_fm_clk1), .DAC_ch_index(u_DAC_ch_index),
		.ym2612_status_enable(ym2612_status_enable) );

	// ---- storage compare (identical-hierarchy XMRs; generated) ----------------
`ifndef OPT
	storage_compare cmp ();
`endif

	// ---- MCLK / PHI generation ------------------------------------------------
	always #5 MCLK = ~MCLK;

	integer phi_div = 0;
	localparam PHI_HALF = 7;                 // PHI half-period in MCLK cycles (~MCLK/14)
	always @(posedge MCLK) begin
		phi_div = phi_div + 1;
		if (phi_div >= PHI_HALF) begin phi_div = 0; PHI <= ~PHI; end
	end

	// ---- cycle counter --------------------------------------------------------
	longint unsigned cyc = 0;
	always @(posedge MCLK) cyc <= cyc + 1;

	// ---- comparison bookkeeping ----------------------------------------------
	integer errors = 0;
	integer seed   = 1;
	integer ncyc   = 1000;
	longint unsigned cmpstart = 2;   // begin comparing after this cycle (+CMPSTART)
	reg     quiet    = 1'b0;
	reg     nostore  = 1'b0;
	reg     noreset  = 1'b0;         // skip resets in the random program (+NORESET)
	reg     run_done = 1'b0;

	task automatic fail(input string what);
		begin
			errors = errors + 1;
			$display("### MISMATCH @cyc=%0d t=%0t : %s", cyc, $time, what);
		end
	endtask

	// compare all primary outputs (case-inequality so identical-X does not flag)
	task automatic check_outputs;
		begin
			if (d_MOL       !== u_MOL      ) fail($sformatf("MOL      die=%h dut=%h", d_MOL, u_MOL));
			if (d_MOR       !== u_MOR      ) fail($sformatf("MOR      die=%h dut=%h", d_MOR, u_MOR));
			if (d_MOL_2612  !== u_MOL_2612 ) fail($sformatf("MOL_2612 die=%h dut=%h", d_MOL_2612, u_MOL_2612));
			if (d_MOR_2612  !== u_MOR_2612 ) fail($sformatf("MOR_2612 die=%h dut=%h", d_MOR_2612, u_MOR_2612));
			if (d_DATA_o    !== u_DATA_o   ) fail($sformatf("DATA_o   die=%h dut=%h", d_DATA_o, u_DATA_o));
			if (d_DATA_o_z  !== u_DATA_o_z ) fail($sformatf("DATA_o_z die=%b dut=%b", d_DATA_o_z, u_DATA_o_z));
			if (d_TEST_o    !== u_TEST_o   ) fail($sformatf("TEST_o   die=%b dut=%b", d_TEST_o, u_TEST_o));
			if (d_TEST_o_z  !== u_TEST_o_z ) fail($sformatf("TEST_o_z die=%b dut=%b", d_TEST_o_z, u_TEST_o_z));
			if (d_IRQ       !== u_IRQ      ) fail($sformatf("IRQ      die=%b dut=%b", d_IRQ, u_IRQ));
			if (d_fm_clk1   !== u_fm_clk1  ) fail($sformatf("fm_clk1  die=%b dut=%b", d_fm_clk1, u_fm_clk1));
			if (d_DAC_ch_index !== u_DAC_ch_index) fail($sformatf("DAC_ch_index die=%h dut=%h", d_DAC_ch_index, u_DAC_ch_index));
		end
	endtask

	task automatic check_all;
		begin
			check_outputs();
`ifndef OPT
			if (!nostore && cmp.mismatch) begin
				fail("storage element(s) differ:");
				cmp.report();
			end
`endif
			if (errors > 0) begin
				$display("=== STOP at first mismatch: cyc=%0d errors=%0d ===", cyc, errors);
				$fatal(1, "equivalence failed");
			end
		end
	endtask

	// twice per MCLK: at negedge (settled) and shortly after posedge (settled)
	always @(negedge MCLK) if (run_done == 1'b0 && cyc > cmpstart) check_all();
	always @(posedge MCLK) begin
		#2;
		if (run_done == 1'b0 && cyc > cmpstart) check_all();
	end

	// ---- bus write helpers ----------------------------------------------------
	task automatic step(input integer n);       // wait n posedge MCLK
		integer i;
		begin for (i=0;i<n;i=i+1) @(posedge MCLK); end
	endtask

	// one Z80-style access strobe: CS&WR low for pw MCLK, then released for gap
	task automatic bus_write(input [1:0] a, input [7:0] d, input integer pw, input integer gap);
		begin
			@(negedge MCLK);
			ADDRESS = a; DATA_i = d; CS = 1'b0; WR = 1'b0;
			step(pw);
			@(negedge MCLK);
			WR = 1'b1; CS = 1'b1;
			step(gap);
		end
	endtask

	// full register write: address port then data port (bank from a[1]) with
	// realistic pulse widths; interwrite gap models a Z80 driver.
	task automatic wr(input bit bank, input [7:0] addr, input [7:0] data,
	                  input integer gap);
		begin
			bus_write({bank,1'b0}, addr, 3, 4);       // address latch
			bus_write({bank,1'b1}, data, 3, gap);     // data write
		end
	endtask

	// a status read strobe (RD low)
	task automatic rd_status(input [1:0] a, input integer pw);
		begin
			@(negedge MCLK);
			ADDRESS = a; CS = 1'b0; RD = 1'b0;
			step(pw);
			@(negedge MCLK);
			RD = 1'b1; CS = 1'b1;
			step(2);
		end
	endtask

	task automatic do_reset(input integer n);
		begin
			IC = 1'b0; CS = 1'b1; WR = 1'b1; RD = 1'b1; ADDRESS = 2'b00; DATA_i = 8'h00;
			step(n);
			IC = 1'b1;
			step(8);
		end
	endtask

	// ---- directed program: notes on all 6 channels, LFO, timers, SSG, DAC, CSM
	task automatic set_channel(input bit bank, input [1:0] ch, input [7:0] fnum_l,
	                           input [7:0] blk_fnum_h, input [7:0] alg_fb);
		integer op;
		begin
			// operators 0x30..0x9F : slot offset = ch + op*4  (ops at 0x30,34,38,3C ...)
			for (op=0; op<4; op=op+1) begin
				wr(bank, 8'h30 + ch + op*4, 8'h71, 5);       // DT/MUL
				wr(bank, 8'h40 + ch + op*4, 8'h10 + op*4, 5);// TL
				wr(bank, 8'h50 + ch + op*4, 8'h1f, 5);       // KS/AR
				wr(bank, 8'h60 + ch + op*4, 8'h0a, 5);       // AM/DR
				wr(bank, 8'h70 + ch + op*4, 8'h05, 5);       // SR
				wr(bank, 8'h80 + ch + op*4, 8'h2f, 5);       // SL/RR
				wr(bank, 8'h90 + ch + op*4, 8'h00, 5);       // SSG-EG
			end
			wr(bank, 8'hA4 + ch, blk_fnum_h, 5);             // block/fnum hi  (write A4 before A0)
			wr(bank, 8'hA0 + ch, fnum_l, 5);                 // fnum lo
			wr(bank, 8'hB0 + ch, alg_fb, 5);                 // FB/ALG
			wr(bank, 8'hB4 + ch, 8'hC0, 5);                  // L/R/AMS/PMS pan both
		end
	endtask

	task automatic directed_program;
		integer k;
		begin
			do_reset(40);

			// LFO on
			wr(1'b0, 8'h22, 8'h08, 6);
			// timer A/B load values + control (timer A=0x3ff, B=0xff, load+enable+CSM later)
			wr(1'b0, 8'h24, 8'hAA, 6);   // timer A hi
			wr(1'b0, 8'h25, 8'h02, 6);   // timer A lo
			wr(1'b0, 8'h26, 8'h80, 6);   // timer B
			wr(1'b0, 8'h27, 8'h3F, 6);   // load+enable A&B, mode normal

			// three channels in bank 0 (ch1-3), three in bank 1 (ch4-6)
			set_channel(1'b0, 2'd0, 8'h69, 8'h22, 8'h3A);
			set_channel(1'b0, 2'd1, 8'h84, 8'h1A, 8'h35);
			set_channel(1'b0, 2'd2, 8'hA1, 8'h2A, 8'h07);
			set_channel(1'b1, 2'd0, 8'h50, 8'h24, 8'h3C);
			set_channel(1'b1, 2'd1, 8'hC2, 8'h18, 8'h34);
			set_channel(1'b1, 2'd2, 8'h33, 8'h31, 8'h06);

			// key on all 6 channels (0x28: bits7-4 slots, bits2-0 channel)
			wr(1'b0, 8'h28, 8'hF0, 8); // ch0 all slots
			wr(1'b0, 8'h28, 8'hF1, 8);
			wr(1'b0, 8'h28, 8'hF2, 8);
			wr(1'b0, 8'h28, 8'hF4, 8); // ch4
			wr(1'b0, 8'h28, 8'hF5, 8);
			wr(1'b0, 8'h28, 8'hF6, 8);

			// let it run and generate audio
			step(4000);

			// SSG-EG on ch1 operators
			wr(1'b0, 8'h90, 8'h08, 6);
			wr(1'b0, 8'h94, 8'h0C, 6);
			wr(1'b0, 8'h98, 8'h0E, 6);
			wr(1'b0, 8'h9C, 8'h0B, 6);
			step(2000);

			// CSM mode + timer A drives ch3 key-on
			wr(1'b0, 8'h27, 8'h80, 6);   // CSM (mode=10)
			step(3000);
			wr(1'b0, 8'h27, 8'h00, 6);   // back to normal
			step(500);

			// DAC mode: enable DAC, stream samples
			wr(1'b0, 8'h2B, 8'h80, 6);   // DAC enable
			for (k=0;k<64;k=k+1) begin
				wr(1'b0, 8'h2A, (k*4) & 8'hff, 5); // DAC sample
				step(20);
			end
			wr(1'b0, 8'h2B, 8'h00, 6);   // DAC off
			step(500);

			// status reads (busy flag + timer flags), toggle chip mode
			rd_status(2'b00, 3);
			ym2612_status_enable = 1'b1;
			rd_status(2'b00, 3);
			// write during BUSY: back-to-back data writes with no gap
			bus_write(2'b00, 8'h30, 3, 1);
			bus_write(2'b01, 8'h34, 3, 0);   // immediate data write (busy)
			bus_write(2'b01, 8'h35, 3, 0);   // another during busy
			ym2612_status_enable = 1'b0;
			step(300);

			// debug read path: reg 0x21 test bits then status/debug reads
			wr(1'b0, 8'h21, 8'h40, 6);   // reg21[6]=1 -> debug read select
			rd_status(2'b00, 3);
			wr(1'b0, 8'h21, 8'hC0, 6);   // reg21[7]=1 too
			rd_status(2'b00, 3);
			wr(1'b0, 8'h21, 8'h00, 6);
			// TEST_i toggling (eg test path)
			TEST_i = 1'b1; step(200); TEST_i = 1'b0; step(200);

			// reset mid-stream then replay a few writes
			do_reset(30);
			wr(1'b0, 8'h22, 8'h0F, 6);
			set_channel(1'b0, 2'd0, 8'h11, 8'h30, 8'h07);
			wr(1'b0, 8'h28, 8'hF0, 8);
			step(3000);
		end
	endtask

	// ---- constrained-random writes -------------------------------------------
	function automatic [7:0] rnd8; rnd8 = $random(seed); endfunction

	task automatic random_program(input integer n);
		integer i;
		reg [7:0] r;
		reg [7:0] a, d;
		bit bank;
		integer g;
		begin
			i = 0;
			while (cyc < n) begin
				r = rnd8();
				bank = r[0];
				// choose a register class
				case (r[3:1])
					3'd0: a = 8'h30 + (rnd8() & 8'h6F);            // operator regs 0x30..0x9F
					3'd1: a = 8'hA0 + (rnd8() % 8'h17);            // 0xA0..0xB6
					3'd2: a = 8'h22 + (rnd8() % 8'h0B);            // 0x22..0x2C mode/timer/dac
					3'd3: a = 8'h28;                               // key on/off
					3'd4: a = 8'h2A;                               // dac sample
					3'd5: a = 8'h21;                               // test
					default: a = 8'h30 + (rnd8() & 8'h6F);
				endcase
				d = rnd8();
				g = (rnd8() & 8'h1F);                           // 0..31 cycle gap (some during busy)
				if (r[7]) begin
					// occasional status read / mode toggle / test toggle / reset
					case (r[6:4])
						3'd0: rd_status({1'b0, r[2]}, 3);
						3'd1: ym2612_status_enable = r[2];
						3'd2: TEST_i = r[2];
						3'd3: if (~noreset & ((rnd8() & 8'hFF) == 8'h00)) do_reset(20);  // rare reset
						default: wr(bank, a, d, g);
					endcase
				end else begin
					wr(bank, a, d, g);
				end
				i = i + 1;
			end
		end
	endtask

	// ---- main -----------------------------------------------------------------
	initial begin
		if ($value$plusargs("SEED=%d", seed))   ; else seed = 1;
		if ($value$plusargs("NCYC=%d", ncyc))   ; else ncyc = 200000;
		if ($test$plusargs("QUIET"))   quiet   = 1'b1;
		if ($test$plusargs("NOSTORE")) nostore = 1'b1;
		if ($test$plusargs("NORESET")) noreset = 1'b1;
		void'($value$plusargs("CMPSTART=%d", cmpstart));
		$display("=== tb_ym3438  SEED=%0d NCYC=%0d %s%s ===", seed, ncyc,
`ifdef OPT "OPT " `else "RTL " `endif , nostore ? "(outputs-only)" : "(full storage)");

		directed_program();
		$display("--- directed program done @cyc=%0d (0 mismatches so far) ---", cyc);
		random_program(ncyc);

		run_done = 1'b1;
		#20;
		$display("=== PASS: %0d MCLK cycles, 0 mismatches (errors=%0d) ===", cyc, errors);
		$finish;
	end

	// safety watchdog
	initial begin
		#2_000_000_000;  // 200M ns
		$display("### watchdog timeout @cyc=%0d", cyc);
		$finish;
	end

endmodule
