//============================================================================
//  Bring-up telemetry: a 64-byte record written to DDR3 every ~20ms.
//  Read from the HPS with tools/mcd_telemetry.py (mmap of /dev/mem).
//  Test-core only; remove for release.
//============================================================================

module mcd_debug
(
	input             clk,          // 107 MHz (DDRAM clock)

	// bus / chipset observations (107 MHz domain)
	input             exp_as,       // /AS
	input             exp_rw,
	input             exp_rom,
	input             exp_ras2,
	input             exp_fdc,
	input             mcd_dtack_n,  // gate array /DTACK (53 MHz domain, sampled)
	input             bus_dtack,    // /DTACK on the bus
	input      [23:1] va,
	input      [15:0] vd,
	input             cart_cs,
	input             cart_oe,
	input             vclk,
	input             vs,
	input             hs,
	input             prg_rd,
	input             prg_wr,
	input             md_reset,
	input             btn_reset,
	input             sys_reset,
	input             mcd_rst_n,
	input             rom_cart_mode,
	input       [1:0] region,
	input             led_r,
	input             led_g,
	input             locked,
	input             rom_download,
	input             ioctl_wr,
	input             m68k_reset,   // 68000 RESET pin level
	input             m68k_halt,    // 68000 HALT pin level

	// DDR3
	output reg  [7:0] DDRAM_BURSTCNT,
	output reg [28:0] DDRAM_ADDR,
	output reg [63:0] DDRAM_DIN,
	output reg  [7:0] DDRAM_BE,
	output reg        DDRAM_WE,
	output            DDRAM_RD,
	input             DDRAM_BUSY
);

assign DDRAM_RD = 0;

localparam [28:0] BASE = 29'h07C00000; // byte address 0x3E000000

reg [31:0] as_cnt, exp_rd_cnt, exp_wr_cnt, late_cnt, nodtack_cnt, vs_cnt, hs_cnt, vclk_cnt, prg_cnt, cart_cnt, dl_cnt, reg_wr_cnt;
reg [15:0] max_lat, lat;
reg [23:1] last_va;
reg [15:0] last_vd;
reg [15:0] last_exp_va_hi;
reg        in_cyc, seen_dtack, seen_rom, seen_ras2, seen_fdc, cyc_rw;
reg [1:0]  s_dtack, s_vs, s_hs, s_vclk, s_prg_rd, s_prg_wr, s_oe, s_as;
reg        old_dl;

always @(posedge clk) begin
	s_dtack <= {s_dtack[0], mcd_dtack_n};
	s_vs    <= {s_vs[0], vs};
	s_hs    <= {s_hs[0], hs};
	s_vclk  <= {s_vclk[0], vclk};
	s_prg_rd <= {s_prg_rd[0], prg_rd};
	s_prg_wr <= {s_prg_wr[0], prg_wr};
	s_oe    <= {s_oe[0], cart_oe & cart_cs};
	s_as    <= {s_as[0], exp_as};

	if(s_vs == 2'b01) vs_cnt <= vs_cnt + 1'd1;
	if(s_hs == 2'b01) hs_cnt <= hs_cnt + 1'd1;
	if(s_vclk == 2'b01) vclk_cnt <= vclk_cnt + 1'd1;
	if(s_prg_rd == 2'b01) prg_cnt <= prg_cnt + 1'd1;
	if(s_prg_wr == 2'b01) prg_cnt <= prg_cnt + 1'd1;
	if(s_oe == 2'b01) cart_cnt <= cart_cnt + 1'd1;
	if(rom_download & ioctl_wr) dl_cnt <= dl_cnt + 1'd1;
	old_dl <= rom_download;
	if(~old_dl & rom_download) dl_cnt <= 0;

	// expansion bus cycle tracking
	if(s_as == 2'b10) begin // /AS fell
		in_cyc <= 1;
		as_cnt <= as_cnt + 1'd1;
		seen_dtack <= 0; seen_rom <= 0; seen_ras2 <= 0; seen_fdc <= 0;
		cyc_rw <= exp_rw;
		lat <= 0;
		last_va <= va;
	end
	else if(in_cyc) begin
		if(~lat[15]) lat <= lat + 1'd1;
		if(~exp_rom)  seen_rom  <= 1;
		if(~exp_ras2) seen_ras2 <= 1;
		if(~exp_fdc)  seen_fdc  <= 1;
		if(~s_dtack[1] & ~seen_dtack) begin
			seen_dtack <= 1;
			if(lat > max_lat) max_lat <= lat;
		end
		if(s_as == 2'b01) begin // /AS rose: end of cycle
			in_cyc <= 0;
			last_vd <= vd;
			if(seen_rom | seen_ras2 | seen_fdc) begin
				if(cyc_rw) begin
					exp_rd_cnt <= exp_rd_cnt + 1'd1;
					if(~seen_dtack) begin
						// no gate array DTACK before the CPU finished the cycle: data was late or absent
						if(~s_dtack[1]) late_cnt <= late_cnt + 1'd1; else nodtack_cnt <= nodtack_cnt + 1'd1;
					end
				end
				else begin
					exp_wr_cnt <= exp_wr_cnt + 1'd1;
					if(seen_fdc) reg_wr_cnt <= reg_wr_cnt + 1'd1;
				end
				last_exp_va_hi <= {va[23:17], 9'd0};
			end
		end
	end
end

// periodic record write
reg [20:0] tick;
reg [31:0] seq;
reg  [3:0] idx;
reg        busy_w;
wire [15:0] flags = {locked, m68k_halt, m68k_reset, rom_download, led_g, led_r, mcd_rst_n, rom_cart_mode, region, sys_reset, btn_reset, md_reset, exp_fdc, exp_ras2, exp_rom};

always @(posedge clk) begin
	tick <= tick + 1'd1;
	if(!busy_w) begin
		DDRAM_WE <= 0;
		if(&tick) begin
			busy_w <= 1;
			idx <= 0;
			seq <= seq + 1'd1;
			DDRAM_ADDR <= BASE;
			DDRAM_BURSTCNT <= 8;
			DDRAM_BE <= 8'hFF;
		end
	end
	else if(!DDRAM_BUSY) begin
		DDRAM_WE <= 1;
		case(idx)
			0: DDRAM_DIN <= 64'h4D43445F4E554B45; // "MCD_NUKE"
			1: DDRAM_DIN <= {seq, 16'd0, flags};
			2: DDRAM_DIN <= {vs_cnt, as_cnt};
			3: DDRAM_DIN <= {exp_rd_cnt, late_cnt};
			4: DDRAM_DIN <= {nodtack_cnt, exp_wr_cnt};
			5: DDRAM_DIN <= {last_va, 1'b0, last_vd, max_lat};
			6: DDRAM_DIN <= {prg_cnt, cart_cnt};
			7: DDRAM_DIN <= {vclk_cnt, hs_cnt};
		endcase
		idx <= idx + 1'd1;
		if(idx == 7) busy_w <= 0;
		if(idx == 7 || idx == 0) ; // keep
	end
end

// unused but kept for reference in the record layout
wire [31:0] unused_reg_wr = reg_wr_cnt;
wire [31:0] unused_dl = dl_cnt;
wire [15:0] unused_hi = last_exp_va_hi;

endmodule
