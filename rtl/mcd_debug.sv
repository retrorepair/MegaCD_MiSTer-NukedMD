//============================================================================
//  Bring-up telemetry: a 320-byte record written to DDR3 every ~20ms.
//  Read from the HPS with tools/mcd_telemetry.py (mmap of /dev/mem).
//  Test-core only (compiled with MCD_TELEMETRY); not part of a release build.
//
//  Record (40 x 64-bit words):
//    0     magic "MCD_NUKE"
//    1     seq[63:32], flags[15:0]
//    2     vs_cnt[63:32], as_cnt[31:0]           main-CPU /AS cycles
//    3     exp_rd_cnt[63:32], late_cnt[31:0]     expansion reads / late data
//    4     ras2_ign[63:32], ras2_acc[31:0]
//    5     last_va, last_vd, max_lat
//    6     prg_cnt[63:32], cart_cnt[31:0]
//    7     vclk_cnt[63:32], dl_cnt[31:0]
//    8-17  sub-CPU bus cycle statistics, 5 regions x 2 words:
//            even: count[63:32], latency sum[31:0]   (latency = /AS low -> /DTACK low, 107 MHz clocks)
//            odd : max[63:48], min[47:32], cycles longer than 8 CPU clocks[31:0]
//          regions: 0 PRG-RAM (A19=0), 1 word RAM (8-D), 2 gate array regs (F8), 3 PCM (F0), 4 backup RAM (E)
//    18-23 unused
//    24-39 trace of the first 8 VDP DMA cycles from the expansion (2 words each)
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
	input      [15:0] mcd_do,       // gate array data out (EXT_VDO)
	input      [15:0] sdram_dout,   // SDRAM controller data
	input             rom_busy,     // SDRAM port 1 busy
	input             ras2_window,  // address inside the word RAM window
	input             cart_dma,     // VDP DMA in progress (BGACK)
	input             exp_asel,     // /ASEL
	input             dma_rd,       // VDP DMA read strobe on the expansion (cart_dma & cart_oe)

	// sub-CPU bus (53 MHz domain, sampled)
	input             s68k_as_n,
	input             s68k_dtack_n,
	input       [3:0] s68k_a,       // A19..A16

	// PCM chip (53 MHz domain, sampled)
	input             pcm_smp_ce,   // sample enable (should be 520832 Hz)
	input             pcm_late,     // sample fetch from SDRAM did not return before the next address
	input             pcm_we_n,     // PCM write strobe (from the sub-CPU or DMA)
	input             pcm_cs_n,     // PCM chip select
	input             s68k_ce_f,    // 12.5 MHz falling-edge enable (the PCM samples its strobes on it)

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

reg [31:0] as_cnt, exp_rd_cnt, exp_wr_cnt, late_cnt, nodtack_cnt, ras2_acc_cnt, ras2_ign_cnt, vs_cnt, hs_cnt, vclk_cnt, prg_cnt, cart_cnt, dl_cnt, reg_wr_cnt;
reg [15:0] max_lat, lat;
reg [11:0] lat_dtack, lat_busy;
reg        seen_busy;
reg  [1:0] s_busy;
// trace of the first VDP DMA cycles after the CPU leaves reset
reg [63:0] trace[16];
reg  [3:0] tr_n;
reg        cpu_live;
reg [23:1] last_va;
reg [15:0] last_vd;
reg [15:0] last_exp_va_hi;
reg        in_cyc, seen_dtack, seen_rom, seen_ras2, seen_fdc, cyc_rw, cyc_dma, seen_asel;
reg [1:0]  s_ras2, s_dma;
reg [1:0]  s_dtack, s_vs, s_hs, s_vclk, s_prg_rd, s_prg_wr, s_oe, s_as;
reg        old_dl;

always @(posedge clk) begin
	s_dtack <= {s_dtack[0], mcd_dtack_n};
	if(~m68k_reset | ~m68k_halt) begin cpu_live <= 0; tr_n <= 0; end else cpu_live <= 1;
	s_vs    <= {s_vs[0], vs};
	s_hs    <= {s_hs[0], hs};
	s_vclk  <= {s_vclk[0], vclk};
	s_prg_rd <= {s_prg_rd[0], prg_rd};
	s_prg_wr <= {s_prg_wr[0], prg_wr};
	s_oe    <= {s_oe[0], cart_oe & cart_cs};
	s_as    <= {s_as[0], exp_as};
	s_busy  <= {s_busy[0], rom_busy};
	s_dma   <= {s_dma[0], dma_rd};
	if(s_ras2 == 2'b10) begin if(ras2_window) ras2_acc_cnt <= ras2_acc_cnt + 1'd1; else ras2_ign_cnt <= ras2_ign_cnt + 1'd1; end
	s_ras2 <= {s_ras2[0], exp_ras2};

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
	if((s_as == 2'b10 & ~cart_dma) | (s_dma == 2'b01)) begin // /AS fell (CPU) or DMA read strobe rose
		in_cyc <= 1;
		as_cnt <= as_cnt + 1'd1;
		seen_dtack <= 0; seen_rom <= 0; seen_ras2 <= 0; seen_fdc <= 0; seen_busy <= 0; lat_dtack <= 0; lat_busy <= 0;
		cyc_rw <= exp_rw;
		cyc_dma <= cart_dma | (s_dma == 2'b01); seen_asel <= 0;
		lat <= 0;
		last_va <= va;
	end
	else if(in_cyc) begin
		if(~lat[15]) lat <= lat + 1'd1;
		if(~exp_rom)  seen_rom  <= 1;
		if(~exp_ras2) seen_ras2 <= 1;
		if(~exp_fdc)  seen_fdc  <= 1;
		if(~exp_asel) seen_asel <= 1;
		if(~s_dtack[1] & ~seen_dtack) begin
			seen_dtack <= 1; lat_dtack <= lat[11:0];
			if(lat > max_lat) max_lat <= lat;
		end
		if(s_busy == 2'b10 && ~seen_busy) begin seen_busy <= 1; lat_busy <= lat[11:0]; end
		if((s_as == 2'b01 & ~cyc_dma) | (s_dma == 2'b10 & cyc_dma)) begin // /AS rose (CPU) or DMA strobe fell: end of cycle
			in_cyc <= 0;
			last_vd <= vd;
			if(cpu_live && (cyc_dma | cart_dma) && ~tr_n[3]) begin // DMA cycles only
				trace[{tr_n[2:0],1'b0}] <= {last_va, cyc_rw, seen_rom, seen_ras2, seen_fdc, cart_cs, seen_dtack, lat_dtack, vd, 4'd0, seen_asel, cyc_dma, seen_busy};
				trace[{tr_n[2:0],1'b1}] <= {mcd_do, sdram_dout, lat_busy, lat[11:0], 8'd0};
				tr_n <= tr_n + 1'd1;
			end
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

// sub-CPU bus cycle statistics: /AS low -> /DTACK low, in 107 MHz clocks, per address region
reg  [1:0] ss_as, ss_dtack;
reg        sub_in_cyc, sub_seen_dtack;
reg [15:0] sub_lat;
reg  [2:0] sub_region;
reg [31:0] sub_cnt[5], sub_sum[5], sub_long[5];
reg [15:0] sub_max[5], sub_min[5];
integer r;

wire [2:0] region_of = (s68k_a[3] == 1'b0) ? 3'd0 :                    // 00000-7FFFF PRG-RAM
                       (s68k_a >= 4'h8 && s68k_a <= 4'hD) ? 3'd1 :     // 80000-DFFFF word RAM
                       (s68k_a == 4'hF) ? 3'd2 :                        // F0000-FFFFF: PCM (F0-F7) or registers (F8-FF); split below by A16? no: A19..16 only
                       (s68k_a == 4'hE) ? 3'd4 : 3'd2;                  // E0000 backup RAM

always @(posedge clk) begin
	ss_as    <= {ss_as[0], s68k_as_n};
	ss_dtack <= {ss_dtack[0], s68k_dtack_n};
	if(~old_dl & rom_download) begin
		for(r = 0; r < 5; r = r + 1) begin sub_cnt[r] <= 0; sub_sum[r] <= 0; sub_long[r] <= 0; sub_max[r] <= 0; sub_min[r] <= 16'hFFFF; end
	end
	if(ss_as == 2'b10) begin
		sub_in_cyc <= 1; sub_seen_dtack <= 0; sub_lat <= 0; sub_region <= region_of;
	end
	else if(sub_in_cyc) begin
		if(~sub_lat[15]) sub_lat <= sub_lat + 1'd1;
		if(~ss_dtack[1] & ~sub_seen_dtack) begin
			sub_seen_dtack <= 1;
			sub_cnt[sub_region] <= sub_cnt[sub_region] + 1'd1;
			sub_sum[sub_region] <= sub_sum[sub_region] + sub_lat;
			if(sub_lat > sub_max[sub_region]) sub_max[sub_region] <= sub_lat;
			if(sub_lat < sub_min[sub_region]) sub_min[sub_region] <= sub_lat;
			if(sub_lat > 16'd68) sub_long[sub_region] <= sub_long[sub_region] + 1'd1; // > 8 CPU clocks of 12.5 MHz
		end
		if(ss_as == 2'b01) sub_in_cyc <= 0;
	end
end

// PCM statistics: sample enable rate, late fetches, write strobes issued vs. seen through the
// chip's CE_F sampling (a strobe edge that falls between two CE_F samples is a lost write)
reg  [1:0] sp_ce, sp_late, sp_we, sp_cef;
reg        we_at_cef, we_at_cef_old;
reg [31:0] smp_ce_cnt, pcm_late_cnt, pcm_wr_cnt, pcm_wr_seen_cnt, cef_cnt;
always @(posedge clk) begin
	sp_ce   <= {sp_ce[0], pcm_smp_ce};
	sp_late <= {sp_late[0], pcm_late};
	sp_we   <= {sp_we[0], pcm_we_n | pcm_cs_n};   // low = a PCM write is asserted
	sp_cef  <= {sp_cef[0], s68k_ce_f};
	if(~old_dl & rom_download) begin
		smp_ce_cnt <= 0; pcm_late_cnt <= 0; pcm_wr_cnt <= 0; pcm_wr_seen_cnt <= 0; cef_cnt <= 0;
	end
	if(sp_ce == 2'b01) smp_ce_cnt <= smp_ce_cnt + 1'd1;
	if(sp_late == 2'b01) pcm_late_cnt <= pcm_late_cnt + 1'd1;
	if(sp_we == 2'b10) pcm_wr_cnt <= pcm_wr_cnt + 1'd1;             // strobe asserted (raw)
	if(sp_cef == 2'b01) begin                                        // as the chip samples it: one sample per CE_F
		cef_cnt <= cef_cnt + 1'd1;
		we_at_cef <= sp_we[1];
		if(we_at_cef & ~sp_we[1]) pcm_wr_seen_cnt <= pcm_wr_seen_cnt + 1'd1; // 1 -> 0 between consecutive samples
	end
end

// periodic record write
reg [20:0] tick;
reg [31:0] seq;
reg  [5:0] idx;
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
			DDRAM_BURSTCNT <= 40;
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
			4: DDRAM_DIN <= {ras2_ign_cnt, ras2_acc_cnt};
			5: DDRAM_DIN <= {last_va, 1'b0, last_vd, max_lat};
			6: DDRAM_DIN <= {prg_cnt, cart_cnt};
			7: DDRAM_DIN <= {vclk_cnt, dl_cnt};
			8:  DDRAM_DIN <= {sub_cnt[0], sub_sum[0]};
			9:  DDRAM_DIN <= {sub_max[0], sub_min[0], sub_long[0]};
			10: DDRAM_DIN <= {sub_cnt[1], sub_sum[1]};
			11: DDRAM_DIN <= {sub_max[1], sub_min[1], sub_long[1]};
			12: DDRAM_DIN <= {sub_cnt[2], sub_sum[2]};
			13: DDRAM_DIN <= {sub_max[2], sub_min[2], sub_long[2]};
			14: DDRAM_DIN <= {sub_cnt[3], sub_sum[3]};
			15: DDRAM_DIN <= {sub_max[3], sub_min[3], sub_long[3]};
			16: DDRAM_DIN <= {sub_cnt[4], sub_sum[4]};
			17: DDRAM_DIN <= {sub_max[4], sub_min[4], sub_long[4]};
			18: DDRAM_DIN <= {smp_ce_cnt, cef_cnt};
			19: DDRAM_DIN <= {pcm_wr_cnt, pcm_wr_seen_cnt};
			20: DDRAM_DIN <= {pcm_late_cnt, 32'd0};
			21,22,23: DDRAM_DIN <= 64'd0;
			default: DDRAM_DIN <= trace[idx[3:0]];
		endcase
		idx <= idx + 1'd1;
		if(idx == 39) busy_w <= 0;
	end
end

// unused but kept for reference in the record layout
wire [31:0] unused_reg_wr = reg_wr_cnt;
wire [31:0] unused_dl = dl_cnt;
wire [15:0] unused_hi = last_exp_va_hi;

endmodule
