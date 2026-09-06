// ym6045 A/B equivalence bench: die model `ym6045` (rtl/nuked-md/ym6045.v, the FC1004 bus
// arbiter / DRAM refresh / DTACK generator) against the 1:1 synthesis-friendly `ym6045_rtl`
// (rtl/nuked-md/ym6045_rtl.v). Identical stimulus into both; every output port and every
// storage register of both models compared twice per MCLK cycle:
//   - at posedge MCLK, before the non-blocking updates land (the values the flops sample)
//   - a quarter period after posedge (the values produced by that edge, same inputs)
// Stimulus is applied at negedge MCLK (+1 ps for the bus models, so that the clock phases and
// the bus resolution, which run exactly at negedge, are settled first). First mismatch prints
// cycle/signal/values and stops the run with FAIL.
//
// The stimulus is a small "board" around the arbiter, wired the way fc1004.v/md_board.v wire
// it (same wired-OR/AND of AS/UDS/LDS/RW, VA, ZA, MREQ/ZRD/ZWR, DTACK, BGACK; the arbiter's own
// outputs are fed back from the die model -- both models are compared to be identical anyway):
//   - clocks: MCLK_e (MCLK/2 as data), VCLK = MCLK/14 (7 high / 7 low), ZCLK = MCLK/30 (16 high /
//     14 low) -- the shapes the VDP prescaler (ym7101.v dff3-dff17, ym7101_dff semantics) really
//     produces on MCLK2, i.e. the 68000 clock at MCLK/7 and the Z80 clock at MCLK/15; HSYNC
//   - a 68000 bus-cycle model: S0..S7 at half-VCLK steps, R/W and data phases, DTACK/VPA
//     sampled at the end of S4 with wait states, BR/BG/BGACK arbitration, tri-state on grant
//   - a Z80 bus-cycle model: M1 (with refresh), memory read/write, I/O, WAIT sampled at T2,
//     BUSRQ/BUSAK, reset from ZRES; addresses over RAM, FM, bank register, 7Fxx and the
//     8000-FFFF bank window (68k bus request through the arbiter)
//   - a VDP model: DTACK for C000xx, CAS0/OE0 work-RAM strobes and DTACK for E00000-FFFFFF cycles
//     (held off while a refresh cycle requested on REF is in progress: the refresh stall),
//     DMA bursts (BR -> BG -> BGACK, address on VA, CAS0/OE0 per word)
//   - an expansion/TMSS model: DTACK for 400000-7FFFFF (gate array, early) and A14xxx
`timescale 1ps/1ps
module tb_ym6045;

// MCLK 107.38635 MHz (md_board MCLK2), same as sim_sub / tb_tmss
reg MCLK = 0;
always #4656 MCLK = ~MCLK;        // 9.312 ns
localparam T68 = 14;              // MCLK cycles per 68000 clock (VCLK)
localparam TZ80 = 30;             // MCLK cycles per Z80 clock (ZCLK)

// ---------------------------------------------------------------- inputs (shared)
reg        MCLK_e = 0;
reg        VCLK = 0, ZCLK = 0;
reg        VD8_i = 0;
reg [15:7] ZA_i = 0;
reg        ZA0_i = 0;
reg [22:7] VA_i = 0;
reg        ZRD_i = 1, M1 = 1, ZWR_i = 1;
reg        BGACK_i = 1, BG = 1, IORQ = 1;
reg        RW_i = 1, UDS_i = 1, AS_i = 1, DTACK_i = 1, LDS_i = 1;
reg        CAS0 = 1;
reg        M3 = 1, WRES = 1, CART = 0, OE0 = 1, WAIT_i = 1, ZBAK = 1, MREQ_i = 1;
reg        FC0 = 1, FC1 = 1;
reg        SRES = 0;
reg        test_mode_0 = 0;
reg        ZD0_i = 0;
reg        HSYNC = 1;

// ---------------------------------------------------------------- outputs A (die) / B (rtl)
wire        VD8_o_a, ZA0_o_a, ZRD_o_a, UDS_o_a, ZWR_o_a, BGACK_o_a, AS_o_a, RW_d_a, RW_o_a, LDS_o_a;
wire        strobe_dir_a, DTACK_o_a, BR_a, IA14_a, TIME_a, CE0_a, FDWR_a, FDC_a, ROM_a, ASEL_a;
wire        EOE_a, NOE_a, RAS2_a, CAS2_a, REF_a, ZRAM_a, WAIT_o_a, ZBR_a, NMI_a, ZRES_a, SOUND_a;
wire        VZ_a, MREQ_o_a, VRES_a, VPA_a, VDPM_a, IO_a, ZV_a, INTAK_a, EDCLK_a, vtoz_a;
wire        w12_a, w131_a, w142_a, w310_a, w353_a;
wire [15:8] ZA_o_a;
wire [22:7] VA_o_a;
wire        VD8_o_b, ZA0_o_b, ZRD_o_b, UDS_o_b, ZWR_o_b, BGACK_o_b, AS_o_b, RW_d_b, RW_o_b, LDS_o_b;
wire        strobe_dir_b, DTACK_o_b, BR_b, IA14_b, TIME_b, CE0_b, FDWR_b, FDC_b, ROM_b, ASEL_b;
wire        EOE_b, NOE_b, RAS2_b, CAS2_b, REF_b, ZRAM_b, WAIT_o_b, ZBR_b, NMI_b, ZRES_b, SOUND_b;
wire        VZ_b, MREQ_o_b, VRES_b, VPA_b, VDPM_b, IO_b, ZV_b, INTAK_b, EDCLK_b, vtoz_b;
wire        w12_b, w131_b, w142_b, w310_b, w353_b;
wire [15:8] ZA_o_b;
wire [22:7] VA_o_b;

ym6045 u_die (
	.MCLK(MCLK), .MCLK_e(MCLK_e), .VCLK(VCLK), .ZCLK(ZCLK), .VD8_i(VD8_i), .ZA_i(ZA_i), .ZA0_i(ZA0_i),
	.VA_i(VA_i), .ZRD_i(ZRD_i), .M1(M1), .ZWR_i(ZWR_i), .BGACK_i(BGACK_i), .BG(BG), .IORQ(IORQ),
	.RW_i(RW_i), .UDS_i(UDS_i), .AS_i(AS_i), .DTACK_i(DTACK_i), .LDS_i(LDS_i), .CAS0(CAS0), .M3(M3),
	.WRES(WRES), .CART(CART), .OE0(OE0), .WAIT_i(WAIT_i), .ZBAK(ZBAK), .MREQ_i(MREQ_i), .FC0(FC0),
	.FC1(FC1), .SRES(SRES), .test_mode_0(test_mode_0), .ZD0_i(ZD0_i), .HSYNC(HSYNC),
	.VD8_o(VD8_o_a), .ZA0_o(ZA0_o_a), .ZA_o(ZA_o_a), .VA_o(VA_o_a), .ZRD_o(ZRD_o_a), .UDS_o(UDS_o_a),
	.ZWR_o(ZWR_o_a), .BGACK_o(BGACK_o_a), .AS_o(AS_o_a), .RW_d(RW_d_a), .RW_o(RW_o_a), .LDS_o(LDS_o_a),
	.strobe_dir(strobe_dir_a), .DTACK_o(DTACK_o_a), .BR(BR_a), .IA14(IA14_a), .TIME(TIME_a), .CE0(CE0_a),
	.FDWR(FDWR_a), .FDC(FDC_a), .ROM(ROM_a), .ASEL(ASEL_a), .EOE(EOE_a), .NOE(NOE_a), .RAS2(RAS2_a),
	.CAS2(CAS2_a), .REF(REF_a), .ZRAM(ZRAM_a), .WAIT_o(WAIT_o_a), .ZBR(ZBR_a), .NMI(NMI_a), .ZRES(ZRES_a),
	.SOUND(SOUND_a), .VZ(VZ_a), .MREQ_o(MREQ_o_a), .VRES(VRES_a), .VPA(VPA_a), .VDPM(VDPM_a), .IO(IO_a),
	.ZV(ZV_a), .INTAK(INTAK_a), .EDCLK(EDCLK_a), .vtoz(vtoz_a), .w12(w12_a), .w131(w131_a), .w142(w142_a),
	.w310(w310_a), .w353(w353_a));

ym6045_rtl u_rtl (
	.MCLK(MCLK), .MCLK_e(MCLK_e), .VCLK(VCLK), .ZCLK(ZCLK), .VD8_i(VD8_i), .ZA_i(ZA_i), .ZA0_i(ZA0_i),
	.VA_i(VA_i), .ZRD_i(ZRD_i), .M1(M1), .ZWR_i(ZWR_i), .BGACK_i(BGACK_i), .BG(BG), .IORQ(IORQ),
	.RW_i(RW_i), .UDS_i(UDS_i), .AS_i(AS_i), .DTACK_i(DTACK_i), .LDS_i(LDS_i), .CAS0(CAS0), .M3(M3),
	.WRES(WRES), .CART(CART), .OE0(OE0), .WAIT_i(WAIT_i), .ZBAK(ZBAK), .MREQ_i(MREQ_i), .FC0(FC0),
	.FC1(FC1), .SRES(SRES), .test_mode_0(test_mode_0), .ZD0_i(ZD0_i), .HSYNC(HSYNC),
	.VD8_o(VD8_o_b), .ZA0_o(ZA0_o_b), .ZA_o(ZA_o_b), .VA_o(VA_o_b), .ZRD_o(ZRD_o_b), .UDS_o(UDS_o_b),
	.ZWR_o(ZWR_o_b), .BGACK_o(BGACK_o_b), .AS_o(AS_o_b), .RW_d(RW_d_b), .RW_o(RW_o_b), .LDS_o(LDS_o_b),
	.strobe_dir(strobe_dir_b), .DTACK_o(DTACK_o_b), .BR(BR_b), .IA14(IA14_b), .TIME(TIME_b), .CE0(CE0_b),
	.FDWR(FDWR_b), .FDC(FDC_b), .ROM(ROM_b), .ASEL(ASEL_b), .EOE(EOE_b), .NOE(NOE_b), .RAS2(RAS2_b),
	.CAS2(CAS2_b), .REF(REF_b), .ZRAM(ZRAM_b), .WAIT_o(WAIT_o_b), .ZBR(ZBR_b), .NMI(NMI_b), .ZRES(ZRES_b),
	.SOUND(SOUND_b), .VZ(VZ_b), .MREQ_o(MREQ_o_b), .VRES(VRES_b), .VPA(VPA_b), .VDPM(VDPM_b), .IO(IO_b),
	.ZV(ZV_b), .INTAK(INTAK_b), .EDCLK(EDCLK_b), .vtoz(vtoz_b), .w12(w12_b), .w131(w131_b), .w142(w142_b),
	.w310(w310_b), .w353(w353_b));

// ---------------------------------------------------------------- comparator
integer cycle = 0;                // MCLK edges seen
integer ncmp = 0;                 // compare points (2 per cycle)
integer nmis = 0;
integer nwarn = 0;
reg xcheck_en = 0;                // after the first SRES: no X allowed on any output
reg rand_phase = 0;

`define CMP(NAME, A, B) \
	if ((A) !== (B)) begin \
		$display("MISMATCH cycle %0d t=%0t (%s) %s: die=%h rtl=%h", cycle, $time, phase, NAME, A, B); \
		nmis = nmis + 1; \
	end

// every output port, packed (one wide compare per point; the per-signal report runs on a difference)
wire [68:0] outs_a = {VD8_o_a, ZA0_o_a, ZA_o_a, VA_o_a, ZRD_o_a, UDS_o_a, ZWR_o_a, BGACK_o_a, AS_o_a, RW_d_a, RW_o_a, LDS_o_a,
	strobe_dir_a, DTACK_o_a, BR_a, IA14_a, TIME_a, CE0_a, FDWR_a, FDC_a, ROM_a, ASEL_a, EOE_a, NOE_a, RAS2_a, CAS2_a, REF_a,
	ZRAM_a, WAIT_o_a, ZBR_a, NMI_a, ZRES_a, SOUND_a, VZ_a, MREQ_o_a, VRES_a, VPA_a, VDPM_a, IO_a, ZV_a, INTAK_a, EDCLK_a,
	vtoz_a, w12_a, w131_a, w142_a, w310_a, w353_a};
wire [68:0] outs_b = {VD8_o_b, ZA0_o_b, ZA_o_b, VA_o_b, ZRD_o_b, UDS_o_b, ZWR_o_b, BGACK_o_b, AS_o_b, RW_d_b, RW_o_b, LDS_o_b,
	strobe_dir_b, DTACK_o_b, BR_b, IA14_b, TIME_b, CE0_b, FDWR_b, FDC_b, ROM_b, ASEL_b, EOE_b, NOE_b, RAS2_b, CAS2_b, REF_b,
	ZRAM_b, WAIT_o_b, ZBR_b, NMI_b, ZRES_b, SOUND_b, VZ_b, MREQ_o_b, VRES_b, VPA_b, VDPM_b, IO_b, ZV_b, INTAK_b, EDCLK_b,
	vtoz_b, w12_b, w131_b, w142_b, w310_b, w353_b};

// every storage element of both models, packed (generated from the primitive census of ym6045.v:
// l1/l2 of the 72 master-slave pairs incl. the 9-bit z80bank, dl of the 8 delay chains) plus the
// two inline registers edclk_buf / w45_mem
wire [184:0] sto_a = {
	u_die.dff1.l1,
	u_die.dff1.l2,
	u_die.dff2.l1,
	u_die.dff2.l2,
	u_die.dff3.l1,
	u_die.dff3.l2,
	u_die.dff4.l1,
	u_die.dff4.l2,
	u_die.dff5.l1,
	u_die.dff5.l2,
	u_die.dff6.l1,
	u_die.dff6.l2,
	u_die.dff7.l1,
	u_die.dff7.l2,
	u_die.dff9.l1,
	u_die.dff9.l2,
	u_die.dff8.l1,
	u_die.dff8.l2,
	u_die.dff49.l1,
	u_die.dff49.l2,
	u_die.dff50.l1,
	u_die.dff50.l2,
	u_die.dff51.l1,
	u_die.dff51.l2,
	u_die.dff61.l1,
	u_die.dff61.l2,
	u_die.dff62.l1,
	u_die.dff62.l2,
	u_die.d1.dl,
	u_die.d2.dl,
	u_die.d3.dl,
	u_die.d4.dl,
	u_die.d5.dl,
	u_die.d6.dl,
	u_die.d7.dl,
	u_die.d8.dl,
	u_die.dff34.l1,
	u_die.dff34.l2,
	u_die.dff10.l1,
	u_die.dff10.l2,
	u_die.dff28.l1,
	u_die.dff28.l2,
	u_die.dff22.l1,
	u_die.dff22.l2,
	u_die.dff18.l1,
	u_die.dff18.l2,
	u_die.dff21.l1,
	u_die.dff21.l2,
	u_die.dff60.l1,
	u_die.dff60.l2,
	u_die.dff68.l1,
	u_die.dff68.l2,
	u_die.dff71.l1,
	u_die.dff71.l2,
	u_die.dff72.l1,
	u_die.dff72.l2,
	u_die.dff76.l1,
	u_die.dff76.l2,
	u_die.dff63.l1,
	u_die.dff63.l2,
	u_die.dff52.l1,
	u_die.dff52.l2,
	u_die.dff65.l1,
	u_die.dff65.l2,
	u_die.dff67.l1,
	u_die.dff67.l2,
	u_die.dff74.l1,
	u_die.dff74.l2,
	u_die.nmi.l1,
	u_die.nmi.l2,
	u_die.dff57.l1,
	u_die.dff57.l2,
	u_die.dff58.l1,
	u_die.dff58.l2,
	u_die.dff69.l1,
	u_die.dff69.l2,
	u_die.dff29.l1,
	u_die.dff29.l2,
	u_die.dff27.l1,
	u_die.dff27.l2,
	u_die.dff30.l1,
	u_die.dff30.l2,
	u_die.dff44.l1,
	u_die.dff44.l2,
	u_die.zbr.l1,
	u_die.zbr.l2,
	u_die.dff59.l1,
	u_die.dff59.l2,
	u_die.dff75.l1,
	u_die.dff75.l2,
	u_die.dff66.l1,
	u_die.dff66.l2,
	u_die.dff73.l1,
	u_die.dff73.l2,
	u_die.dff64.l1,
	u_die.dff64.l2,
	u_die.dff47.l1,
	u_die.dff47.l2,
	u_die.dff70.l1,
	u_die.dff70.l2,
	u_die.dff26.l1,
	u_die.dff26.l2,
	u_die.dff45.l1,
	u_die.dff45.l2,
	u_die.dff25.l1,
	u_die.dff25.l2,
	u_die.dff46.l1,
	u_die.dff46.l2,
	u_die.dff17.l1,
	u_die.dff17.l2,
	u_die.dff20.l1,
	u_die.dff20.l2,
	u_die.dff19.l1,
	u_die.dff19.l2,
	u_die.dff16.l1,
	u_die.dff16.l2,
	u_die.dff11.l1,
	u_die.dff11.l2,
	u_die.dff12.l1,
	u_die.dff12.l2,
	u_die.dff15.l1,
	u_die.dff15.l2,
	u_die.dff78.l1,
	u_die.dff78.l2,
	u_die.dff80.l1,
	u_die.dff80.l2,
	u_die.dff79.l1,
	u_die.dff79.l2,
	u_die.dff77.l1,
	u_die.dff77.l2,
	u_die.dff48.l1,
	u_die.dff48.l2,
	u_die.dff54.l1,
	u_die.dff54.l2,
	u_die.dff53.l1,
	u_die.dff53.l2,
	u_die.dff55.l1,
	u_die.dff55.l2,
	u_die.dff33.l1,
	u_die.dff33.l2,
	u_die.dff23.l1,
	u_die.dff23.l2,
	u_die.dff13.l1,
	u_die.dff13.l2,
	u_die.dff24.l1,
	u_die.dff24.l2,
	u_die.dff31.l1,
	u_die.dff31.l2,
	u_die.sres_syncv.l1,
	u_die.sres_syncv.l2,
	u_die.z80bank.l1,
	u_die.z80bank.l2};
wire [184:0] sto_b = {
	u_rtl.dff1_l1,
	u_rtl.dff1_l2,
	u_rtl.dff2_l1,
	u_rtl.dff2_l2,
	u_rtl.dff3_l1,
	u_rtl.dff3_l2,
	u_rtl.dff4_l1,
	u_rtl.dff4_l2,
	u_rtl.dff5_l1,
	u_rtl.dff5_l2,
	u_rtl.dff6_l1,
	u_rtl.dff6_l2,
	u_rtl.dff7_l1,
	u_rtl.dff7_l2,
	u_rtl.dff9_l1,
	u_rtl.dff9_l2,
	u_rtl.dff8_l1,
	u_rtl.dff8_l2,
	u_rtl.dff49_l1,
	u_rtl.dff49_l2,
	u_rtl.dff50_l1,
	u_rtl.dff50_l2,
	u_rtl.dff51_l1,
	u_rtl.dff51_l2,
	u_rtl.dff61_l1,
	u_rtl.dff61_l2,
	u_rtl.dff62_l1,
	u_rtl.dff62_l2,
	u_rtl.d1_dl,
	u_rtl.d2_dl,
	u_rtl.d3_dl,
	u_rtl.d4_dl,
	u_rtl.d5_dl,
	u_rtl.d6_dl,
	u_rtl.d7_dl,
	u_rtl.d8_dl,
	u_rtl.dff34_l1,
	u_rtl.dff34_l2,
	u_rtl.dff10_l1,
	u_rtl.dff10_l2,
	u_rtl.dff28_l1,
	u_rtl.dff28_l2,
	u_rtl.dff22_l1,
	u_rtl.dff22_l2,
	u_rtl.dff18_l1,
	u_rtl.dff18_l2,
	u_rtl.dff21_l1,
	u_rtl.dff21_l2,
	u_rtl.dff60_l1,
	u_rtl.dff60_l2,
	u_rtl.dff68_l1,
	u_rtl.dff68_l2,
	u_rtl.dff71_l1,
	u_rtl.dff71_l2,
	u_rtl.dff72_l1,
	u_rtl.dff72_l2,
	u_rtl.dff76_l1,
	u_rtl.dff76_l2,
	u_rtl.dff63_l1,
	u_rtl.dff63_l2,
	u_rtl.dff52_l1,
	u_rtl.dff52_l2,
	u_rtl.dff65_l1,
	u_rtl.dff65_l2,
	u_rtl.dff67_l1,
	u_rtl.dff67_l2,
	u_rtl.dff74_l1,
	u_rtl.dff74_l2,
	u_rtl.nmi_l1,
	u_rtl.nmi_l2,
	u_rtl.dff57_l1,
	u_rtl.dff57_l2,
	u_rtl.dff58_l1,
	u_rtl.dff58_l2,
	u_rtl.dff69_l1,
	u_rtl.dff69_l2,
	u_rtl.dff29_l1,
	u_rtl.dff29_l2,
	u_rtl.dff27_l1,
	u_rtl.dff27_l2,
	u_rtl.dff30_l1,
	u_rtl.dff30_l2,
	u_rtl.dff44_l1,
	u_rtl.dff44_l2,
	u_rtl.zbr_l1,
	u_rtl.zbr_l2,
	u_rtl.dff59_l1,
	u_rtl.dff59_l2,
	u_rtl.dff75_l1,
	u_rtl.dff75_l2,
	u_rtl.dff66_l1,
	u_rtl.dff66_l2,
	u_rtl.dff73_l1,
	u_rtl.dff73_l2,
	u_rtl.dff64_l1,
	u_rtl.dff64_l2,
	u_rtl.dff47_l1,
	u_rtl.dff47_l2,
	u_rtl.dff70_l1,
	u_rtl.dff70_l2,
	u_rtl.dff26_l1,
	u_rtl.dff26_l2,
	u_rtl.dff45_l1,
	u_rtl.dff45_l2,
	u_rtl.dff25_l1,
	u_rtl.dff25_l2,
	u_rtl.dff46_l1,
	u_rtl.dff46_l2,
	u_rtl.dff17_l1,
	u_rtl.dff17_l2,
	u_rtl.dff20_l1,
	u_rtl.dff20_l2,
	u_rtl.dff19_l1,
	u_rtl.dff19_l2,
	u_rtl.dff16_l1,
	u_rtl.dff16_l2,
	u_rtl.dff11_l1,
	u_rtl.dff11_l2,
	u_rtl.dff12_l1,
	u_rtl.dff12_l2,
	u_rtl.dff15_l1,
	u_rtl.dff15_l2,
	u_rtl.dff78_l1,
	u_rtl.dff78_l2,
	u_rtl.dff80_l1,
	u_rtl.dff80_l2,
	u_rtl.dff79_l1,
	u_rtl.dff79_l2,
	u_rtl.dff77_l1,
	u_rtl.dff77_l2,
	u_rtl.dff48_l1,
	u_rtl.dff48_l2,
	u_rtl.dff54_l1,
	u_rtl.dff54_l2,
	u_rtl.dff53_l1,
	u_rtl.dff53_l2,
	u_rtl.dff55_l1,
	u_rtl.dff55_l2,
	u_rtl.dff33_l1,
	u_rtl.dff33_l2,
	u_rtl.dff23_l1,
	u_rtl.dff23_l2,
	u_rtl.dff13_l1,
	u_rtl.dff13_l2,
	u_rtl.dff24_l1,
	u_rtl.dff24_l2,
	u_rtl.dff31_l1,
	u_rtl.dff31_l2,
	u_rtl.sres_syncv_l1,
	u_rtl.sres_syncv_l2,
	u_rtl.z80bank_l1,
	u_rtl.z80bank_l2};
wire [1:0] inl_a = {u_die.edclk_buf, u_die.w45_mem};
wire [1:0] inl_b = {u_rtl.edclk_buf, u_rtl.w45_mem};

task automatic report(input string phase);
	`CMP("VD8_o",      VD8_o_a,      VD8_o_b)
	`CMP("ZA0_o",      ZA0_o_a,      ZA0_o_b)
	`CMP("ZA_o",       ZA_o_a,       ZA_o_b)
	`CMP("VA_o",       VA_o_a,       VA_o_b)
	`CMP("ZRD_o",      ZRD_o_a,      ZRD_o_b)
	`CMP("UDS_o",      UDS_o_a,      UDS_o_b)
	`CMP("ZWR_o",      ZWR_o_a,      ZWR_o_b)
	`CMP("BGACK_o",    BGACK_o_a,    BGACK_o_b)
	`CMP("AS_o",       AS_o_a,       AS_o_b)
	`CMP("RW_d",       RW_d_a,       RW_d_b)
	`CMP("RW_o",       RW_o_a,       RW_o_b)
	`CMP("LDS_o",      LDS_o_a,      LDS_o_b)
	`CMP("strobe_dir", strobe_dir_a, strobe_dir_b)
	`CMP("DTACK_o",    DTACK_o_a,    DTACK_o_b)
	`CMP("BR",         BR_a,         BR_b)
	`CMP("IA14",       IA14_a,       IA14_b)
	`CMP("TIME",       TIME_a,       TIME_b)
	`CMP("CE0",        CE0_a,        CE0_b)
	`CMP("FDWR",       FDWR_a,       FDWR_b)
	`CMP("FDC",        FDC_a,        FDC_b)
	`CMP("ROM",        ROM_a,        ROM_b)
	`CMP("ASEL",       ASEL_a,       ASEL_b)
	`CMP("EOE",        EOE_a,        EOE_b)
	`CMP("NOE",        NOE_a,        NOE_b)
	`CMP("RAS2",       RAS2_a,       RAS2_b)
	`CMP("CAS2",       CAS2_a,       CAS2_b)
	`CMP("REF",        REF_a,        REF_b)
	`CMP("ZRAM",       ZRAM_a,       ZRAM_b)
	`CMP("WAIT_o",     WAIT_o_a,     WAIT_o_b)
	`CMP("ZBR",        ZBR_a,        ZBR_b)
	`CMP("NMI",        NMI_a,        NMI_b)
	`CMP("ZRES",       ZRES_a,       ZRES_b)
	`CMP("SOUND",      SOUND_a,      SOUND_b)
	`CMP("VZ",         VZ_a,         VZ_b)
	`CMP("MREQ_o",     MREQ_o_a,     MREQ_o_b)
	`CMP("VRES",       VRES_a,       VRES_b)
	`CMP("VPA",        VPA_a,        VPA_b)
	`CMP("VDPM",       VDPM_a,       VDPM_b)
	`CMP("IO",         IO_a,         IO_b)
	`CMP("ZV",         ZV_a,         ZV_b)
	`CMP("INTAK",      INTAK_a,      INTAK_b)
	`CMP("EDCLK",      EDCLK_a,      EDCLK_b)
	`CMP("vtoz",       vtoz_a,       vtoz_b)
	`CMP("w12",        w12_a,        w12_b)
	`CMP("w131",       w131_a,       w131_b)
	`CMP("w142",       w142_a,       w142_b)
	`CMP("w310",       w310_a,       w310_b)
	`CMP("w353",       w353_a,       w353_b)
	`CMP("edclk_buf",  u_die.edclk_buf, u_rtl.edclk_buf)
	`CMP("w45_mem",    u_die.w45_mem,   u_rtl.w45_mem)
	`CMP("dff1.l1",   u_die.dff1.l1, u_rtl.dff1_l1)
	`CMP("dff1.l2",   u_die.dff1.l2, u_rtl.dff1_l2)
	`CMP("dff2.l1",   u_die.dff2.l1, u_rtl.dff2_l1)
	`CMP("dff2.l2",   u_die.dff2.l2, u_rtl.dff2_l2)
	`CMP("dff3.l1",   u_die.dff3.l1, u_rtl.dff3_l1)
	`CMP("dff3.l2",   u_die.dff3.l2, u_rtl.dff3_l2)
	`CMP("dff4.l1",   u_die.dff4.l1, u_rtl.dff4_l1)
	`CMP("dff4.l2",   u_die.dff4.l2, u_rtl.dff4_l2)
	`CMP("dff5.l1",   u_die.dff5.l1, u_rtl.dff5_l1)
	`CMP("dff5.l2",   u_die.dff5.l2, u_rtl.dff5_l2)
	`CMP("dff6.l1",   u_die.dff6.l1, u_rtl.dff6_l1)
	`CMP("dff6.l2",   u_die.dff6.l2, u_rtl.dff6_l2)
	`CMP("dff7.l1",   u_die.dff7.l1, u_rtl.dff7_l1)
	`CMP("dff7.l2",   u_die.dff7.l2, u_rtl.dff7_l2)
	`CMP("dff9.l1",   u_die.dff9.l1, u_rtl.dff9_l1)
	`CMP("dff9.l2",   u_die.dff9.l2, u_rtl.dff9_l2)
	`CMP("dff8.l1",   u_die.dff8.l1, u_rtl.dff8_l1)
	`CMP("dff8.l2",   u_die.dff8.l2, u_rtl.dff8_l2)
	`CMP("dff49.l1",  u_die.dff49.l1, u_rtl.dff49_l1)
	`CMP("dff49.l2",  u_die.dff49.l2, u_rtl.dff49_l2)
	`CMP("dff50.l1",  u_die.dff50.l1, u_rtl.dff50_l1)
	`CMP("dff50.l2",  u_die.dff50.l2, u_rtl.dff50_l2)
	`CMP("dff51.l1",  u_die.dff51.l1, u_rtl.dff51_l1)
	`CMP("dff51.l2",  u_die.dff51.l2, u_rtl.dff51_l2)
	`CMP("dff61.l1",  u_die.dff61.l1, u_rtl.dff61_l1)
	`CMP("dff61.l2",  u_die.dff61.l2, u_rtl.dff61_l2)
	`CMP("dff62.l1",  u_die.dff62.l1, u_rtl.dff62_l1)
	`CMP("dff62.l2",  u_die.dff62.l2, u_rtl.dff62_l2)
	`CMP("d1.dl",     u_die.d1.dl, u_rtl.d1_dl)
	`CMP("d2.dl",     u_die.d2.dl, u_rtl.d2_dl)
	`CMP("d3.dl",     u_die.d3.dl, u_rtl.d3_dl)
	`CMP("d4.dl",     u_die.d4.dl, u_rtl.d4_dl)
	`CMP("d5.dl",     u_die.d5.dl, u_rtl.d5_dl)
	`CMP("d6.dl",     u_die.d6.dl, u_rtl.d6_dl)
	`CMP("d7.dl",     u_die.d7.dl, u_rtl.d7_dl)
	`CMP("d8.dl",     u_die.d8.dl, u_rtl.d8_dl)
	`CMP("dff34.l1",  u_die.dff34.l1, u_rtl.dff34_l1)
	`CMP("dff34.l2",  u_die.dff34.l2, u_rtl.dff34_l2)
	`CMP("dff10.l1",  u_die.dff10.l1, u_rtl.dff10_l1)
	`CMP("dff10.l2",  u_die.dff10.l2, u_rtl.dff10_l2)
	`CMP("dff28.l1",  u_die.dff28.l1, u_rtl.dff28_l1)
	`CMP("dff28.l2",  u_die.dff28.l2, u_rtl.dff28_l2)
	`CMP("dff22.l1",  u_die.dff22.l1, u_rtl.dff22_l1)
	`CMP("dff22.l2",  u_die.dff22.l2, u_rtl.dff22_l2)
	`CMP("dff18.l1",  u_die.dff18.l1, u_rtl.dff18_l1)
	`CMP("dff18.l2",  u_die.dff18.l2, u_rtl.dff18_l2)
	`CMP("dff21.l1",  u_die.dff21.l1, u_rtl.dff21_l1)
	`CMP("dff21.l2",  u_die.dff21.l2, u_rtl.dff21_l2)
	`CMP("dff60.l1",  u_die.dff60.l1, u_rtl.dff60_l1)
	`CMP("dff60.l2",  u_die.dff60.l2, u_rtl.dff60_l2)
	`CMP("dff68.l1",  u_die.dff68.l1, u_rtl.dff68_l1)
	`CMP("dff68.l2",  u_die.dff68.l2, u_rtl.dff68_l2)
	`CMP("dff71.l1",  u_die.dff71.l1, u_rtl.dff71_l1)
	`CMP("dff71.l2",  u_die.dff71.l2, u_rtl.dff71_l2)
	`CMP("dff72.l1",  u_die.dff72.l1, u_rtl.dff72_l1)
	`CMP("dff72.l2",  u_die.dff72.l2, u_rtl.dff72_l2)
	`CMP("dff76.l1",  u_die.dff76.l1, u_rtl.dff76_l1)
	`CMP("dff76.l2",  u_die.dff76.l2, u_rtl.dff76_l2)
	`CMP("dff63.l1",  u_die.dff63.l1, u_rtl.dff63_l1)
	`CMP("dff63.l2",  u_die.dff63.l2, u_rtl.dff63_l2)
	`CMP("dff52.l1",  u_die.dff52.l1, u_rtl.dff52_l1)
	`CMP("dff52.l2",  u_die.dff52.l2, u_rtl.dff52_l2)
	`CMP("dff65.l1",  u_die.dff65.l1, u_rtl.dff65_l1)
	`CMP("dff65.l2",  u_die.dff65.l2, u_rtl.dff65_l2)
	`CMP("dff67.l1",  u_die.dff67.l1, u_rtl.dff67_l1)
	`CMP("dff67.l2",  u_die.dff67.l2, u_rtl.dff67_l2)
	`CMP("dff74.l1",  u_die.dff74.l1, u_rtl.dff74_l1)
	`CMP("dff74.l2",  u_die.dff74.l2, u_rtl.dff74_l2)
	`CMP("nmi.l1",    u_die.nmi.l1, u_rtl.nmi_l1)
	`CMP("nmi.l2",    u_die.nmi.l2, u_rtl.nmi_l2)
	`CMP("dff57.l1",  u_die.dff57.l1, u_rtl.dff57_l1)
	`CMP("dff57.l2",  u_die.dff57.l2, u_rtl.dff57_l2)
	`CMP("dff58.l1",  u_die.dff58.l1, u_rtl.dff58_l1)
	`CMP("dff58.l2",  u_die.dff58.l2, u_rtl.dff58_l2)
	`CMP("dff69.l1",  u_die.dff69.l1, u_rtl.dff69_l1)
	`CMP("dff69.l2",  u_die.dff69.l2, u_rtl.dff69_l2)
	`CMP("dff29.l1",  u_die.dff29.l1, u_rtl.dff29_l1)
	`CMP("dff29.l2",  u_die.dff29.l2, u_rtl.dff29_l2)
	`CMP("dff27.l1",  u_die.dff27.l1, u_rtl.dff27_l1)
	`CMP("dff27.l2",  u_die.dff27.l2, u_rtl.dff27_l2)
	`CMP("dff30.l1",  u_die.dff30.l1, u_rtl.dff30_l1)
	`CMP("dff30.l2",  u_die.dff30.l2, u_rtl.dff30_l2)
	`CMP("dff44.l1",  u_die.dff44.l1, u_rtl.dff44_l1)
	`CMP("dff44.l2",  u_die.dff44.l2, u_rtl.dff44_l2)
	`CMP("zbr.l1",    u_die.zbr.l1, u_rtl.zbr_l1)
	`CMP("zbr.l2",    u_die.zbr.l2, u_rtl.zbr_l2)
	`CMP("dff59.l1",  u_die.dff59.l1, u_rtl.dff59_l1)
	`CMP("dff59.l2",  u_die.dff59.l2, u_rtl.dff59_l2)
	`CMP("dff75.l1",  u_die.dff75.l1, u_rtl.dff75_l1)
	`CMP("dff75.l2",  u_die.dff75.l2, u_rtl.dff75_l2)
	`CMP("dff66.l1",  u_die.dff66.l1, u_rtl.dff66_l1)
	`CMP("dff66.l2",  u_die.dff66.l2, u_rtl.dff66_l2)
	`CMP("dff73.l1",  u_die.dff73.l1, u_rtl.dff73_l1)
	`CMP("dff73.l2",  u_die.dff73.l2, u_rtl.dff73_l2)
	`CMP("dff64.l1",  u_die.dff64.l1, u_rtl.dff64_l1)
	`CMP("dff64.l2",  u_die.dff64.l2, u_rtl.dff64_l2)
	`CMP("dff47.l1",  u_die.dff47.l1, u_rtl.dff47_l1)
	`CMP("dff47.l2",  u_die.dff47.l2, u_rtl.dff47_l2)
	`CMP("dff70.l1",  u_die.dff70.l1, u_rtl.dff70_l1)
	`CMP("dff70.l2",  u_die.dff70.l2, u_rtl.dff70_l2)
	`CMP("dff26.l1",  u_die.dff26.l1, u_rtl.dff26_l1)
	`CMP("dff26.l2",  u_die.dff26.l2, u_rtl.dff26_l2)
	`CMP("dff45.l1",  u_die.dff45.l1, u_rtl.dff45_l1)
	`CMP("dff45.l2",  u_die.dff45.l2, u_rtl.dff45_l2)
	`CMP("dff25.l1",  u_die.dff25.l1, u_rtl.dff25_l1)
	`CMP("dff25.l2",  u_die.dff25.l2, u_rtl.dff25_l2)
	`CMP("dff46.l1",  u_die.dff46.l1, u_rtl.dff46_l1)
	`CMP("dff46.l2",  u_die.dff46.l2, u_rtl.dff46_l2)
	`CMP("dff17.l1",  u_die.dff17.l1, u_rtl.dff17_l1)
	`CMP("dff17.l2",  u_die.dff17.l2, u_rtl.dff17_l2)
	`CMP("dff20.l1",  u_die.dff20.l1, u_rtl.dff20_l1)
	`CMP("dff20.l2",  u_die.dff20.l2, u_rtl.dff20_l2)
	`CMP("dff19.l1",  u_die.dff19.l1, u_rtl.dff19_l1)
	`CMP("dff19.l2",  u_die.dff19.l2, u_rtl.dff19_l2)
	`CMP("dff16.l1",  u_die.dff16.l1, u_rtl.dff16_l1)
	`CMP("dff16.l2",  u_die.dff16.l2, u_rtl.dff16_l2)
	`CMP("dff11.l1",  u_die.dff11.l1, u_rtl.dff11_l1)
	`CMP("dff11.l2",  u_die.dff11.l2, u_rtl.dff11_l2)
	`CMP("dff12.l1",  u_die.dff12.l1, u_rtl.dff12_l1)
	`CMP("dff12.l2",  u_die.dff12.l2, u_rtl.dff12_l2)
	`CMP("dff15.l1",  u_die.dff15.l1, u_rtl.dff15_l1)
	`CMP("dff15.l2",  u_die.dff15.l2, u_rtl.dff15_l2)
	`CMP("dff78.l1",  u_die.dff78.l1, u_rtl.dff78_l1)
	`CMP("dff78.l2",  u_die.dff78.l2, u_rtl.dff78_l2)
	`CMP("dff80.l1",  u_die.dff80.l1, u_rtl.dff80_l1)
	`CMP("dff80.l2",  u_die.dff80.l2, u_rtl.dff80_l2)
	`CMP("dff79.l1",  u_die.dff79.l1, u_rtl.dff79_l1)
	`CMP("dff79.l2",  u_die.dff79.l2, u_rtl.dff79_l2)
	`CMP("dff77.l1",  u_die.dff77.l1, u_rtl.dff77_l1)
	`CMP("dff77.l2",  u_die.dff77.l2, u_rtl.dff77_l2)
	`CMP("dff48.l1",  u_die.dff48.l1, u_rtl.dff48_l1)
	`CMP("dff48.l2",  u_die.dff48.l2, u_rtl.dff48_l2)
	`CMP("dff54.l1",  u_die.dff54.l1, u_rtl.dff54_l1)
	`CMP("dff54.l2",  u_die.dff54.l2, u_rtl.dff54_l2)
	`CMP("dff53.l1",  u_die.dff53.l1, u_rtl.dff53_l1)
	`CMP("dff53.l2",  u_die.dff53.l2, u_rtl.dff53_l2)
	`CMP("dff55.l1",  u_die.dff55.l1, u_rtl.dff55_l1)
	`CMP("dff55.l2",  u_die.dff55.l2, u_rtl.dff55_l2)
	`CMP("dff33.l1",  u_die.dff33.l1, u_rtl.dff33_l1)
	`CMP("dff33.l2",  u_die.dff33.l2, u_rtl.dff33_l2)
	`CMP("dff23.l1",  u_die.dff23.l1, u_rtl.dff23_l1)
	`CMP("dff23.l2",  u_die.dff23.l2, u_rtl.dff23_l2)
	`CMP("dff13.l1",  u_die.dff13.l1, u_rtl.dff13_l1)
	`CMP("dff13.l2",  u_die.dff13.l2, u_rtl.dff13_l2)
	`CMP("dff24.l1",  u_die.dff24.l1, u_rtl.dff24_l1)
	`CMP("dff24.l2",  u_die.dff24.l2, u_rtl.dff24_l2)
	`CMP("dff31.l1",  u_die.dff31.l1, u_rtl.dff31_l1)
	`CMP("dff31.l2",  u_die.dff31.l2, u_rtl.dff31_l2)
	`CMP("sres_syncv.l1", u_die.sres_syncv.l1, u_rtl.sres_syncv_l1)
	`CMP("sres_syncv.l2", u_die.sres_syncv.l2, u_rtl.sres_syncv_l2)
	`CMP("z80bank.l1", u_die.z80bank.l1, u_rtl.z80bank_l1)
	`CMP("z80bank.l2", u_die.z80bank.l2, u_rtl.z80bank_l2)
endtask

task automatic check(input string phase);
	ncmp = ncmp + 1;
	if (outs_a !== outs_b || sto_a !== sto_b || inl_a !== inl_b) begin
		report(phase);
		if (nmis == 0) begin           // cannot happen: the packed compare fired
			$display("MISMATCH cycle %0d (%s): packed vectors differ but no field reported", cycle, phase);
			nmis = 1;
		end
	end
	// after the first reset nothing may be X on an output of either model
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

// ---------------------------------------------------------------- clocks (as md_board / the VDP prescaler make them)
integer vph = 0;                  // 0 = VCLK just rose, 7 = just fell
integer zph = 0;                  // 0 = ZCLK just rose, 15 = just fell
always @(negedge MCLK) begin
	MCLK_e = ~MCLK_e;                                 // md_board: MCLK_e <= ~MCLK_e every MCLK2
	vph = (vph == 13) ? 0 : vph + 1;  VCLK = (vph < 7);   // CLK1: MCLK/14, 7 high / 7 low
	zph = (zph == 29) ? 0 : zph + 1;  ZCLK = (zph < 16);  // CLK0: MCLK/30, 16 high / 14 low (ym7101 prescaler dff15-17 on mclk_clk2, emulated with ym7101_dff semantics)
end

// wait n MCLK cycles; returns 1 ps after a negedge, i.e. after the clock/bus blocks of that negedge
task automatic tick(input integer n);
	repeat (n) begin @(negedge MCLK); #1; end
endtask
task automatic v_edge(input bit rising);     // next VCLK edge (S-state boundary)
	do tick(1); while (vph != (rising ? 0 : 7));
endtask
task automatic z_edge(input bit rising);     // next ZCLK edge (T-state boundary)
	do tick(1); while (zph != (rising ? 0 : 16));
endtask

// HSYNC from the VDP: ~63.5 us line (6840 MCLK), ~4.7 us low; random widths in the random phase
integer hs_period = 6840, hs_low = 505;
initial begin
	#1;
	forever begin
		tick(hs_period - hs_low); HSYNC = 0; tick(hs_low); HSYNC = 1;
		if (rand_phase && $urandom_range(0, 3) == 0) begin hs_low = $urandom_range(40, 900); hs_period = hs_low + $urandom_range(600, 8000); end
		else begin hs_low = 505; hs_period = 6840; end
	end
end

// ---------------------------------------------------------------- bus drivers of the models
// 68000
reg        cpu_AS = 1, cpu_UDS = 1, cpu_LDS = 1, cpu_RW = 1, cpu_BG = 1, cpu_D8 = 0;
reg        cpu_Sz = 0, cpu_Az = 1, cpu_Dz = 1, cpu_FCz = 0;   // z = released (tri-state)
reg [22:0] cpu_VA = 0;
reg [2:0]  cpu_FC = 3'd6;
// VDP
reg        vdp_VAz = 1, vdp_cas0 = 1, vdp_oe0 = 1, vdp_br = 1, vdp_bgack = 1, vdp_dtack = 1, vdp_ram_dtack = 1;
reg [22:0] vdp_VA = 0;
// expansion / TMSS
reg        exp_dtack = 1, tmss_dtack = 1;
// Z80
reg [15:0] z80_A = 0;
reg        z80_Az = 1, z80_MREQ = 1, z80_IORQ = 1, z80_RD = 1, z80_WR = 1, z80_M1 = 1, z80_BUSAK = 1, z80_D0 = 0, z80_Dz = 1;
// other bus drivers (memory / I/O chip data)
reg        vd8_other = 0, zd0_other = 0;
// bus state
reg [22:0] VA_bus = 0;
reg [15:0] ZA_bus = 0;
wire       BR_bus = BR_a & vdp_br;          // md_board: BR = arbiter & VDP (wired-AND, active low)

// ---------------------------------------------------------------- bus resolution (fc1004.v + md_board.v muxes)
// All die outputs are read into temporaries first, then every DUT input is assigned: the inputs
// seen at the next posedge are a function of the state after the previous posedge (md_board's
// registered bus, phase-shifted by half an MCLK).
always @(negedge MCLK) begin : bus
	reg [22:0] ym_va_o, ym_va_d, m68k_va_d, cart_va_d, va_new;
	reg [15:0] ym_za_o, ym_za_d, z80_za_d, za_new;
	reg t_strobe_dir, t_as_o, t_uds_o, t_lds_o, t_rw_d, t_rw_o, t_dtack_o, t_bgack_o, t_w12, t_vd8_o;
	reg t_w131, t_w142, t_vtoz, t_vz, t_za0_o, t_mreq_o, t_zrd_o, t_zwr_o, t_wait_o;
	reg [15:8] t_za_o;
	reg [22:7] t_va_o;
	t_strobe_dir = strobe_dir_a; t_as_o = AS_o_a; t_uds_o = UDS_o_a; t_lds_o = LDS_o_a;
	t_rw_d = RW_d_a; t_rw_o = RW_o_a; t_dtack_o = DTACK_o_a; t_bgack_o = BGACK_o_a;
	t_w12 = w12_a; t_vd8_o = VD8_o_a; t_w131 = w131_a; t_w142 = w142_a; t_vtoz = vtoz_a; t_vz = VZ_a;
	t_za0_o = ZA0_o_a; t_mreq_o = MREQ_o_a; t_zrd_o = ZRD_o_a; t_zwr_o = ZWR_o_a; t_wait_o = WAIT_o_a;
	t_za_o = ZA_o_a; t_va_o = VA_o_a;
	// 68k address bus: fc1004 VA_o/VA_d (VDP, arbiter [19:7] when w131 low, [22:20] when w142 low),
	// the 68000, the SMS cart (drives A23..A21 when M3 = 0), else hold (md_board VA register)
	ym_va_o = (vdp_VAz ? 23'h0 : vdp_VA) | (t_w131 ? 23'h0 : {3'h0, t_va_o[19:7], 7'h0}) | (t_w142 ? 23'h0 : {t_va_o[22:20], 20'h0});
	ym_va_d = ((vdp_VAz & t_w142) ? 23'h700000 : 23'h0) | ((vdp_VAz & t_w131) ? 23'h0fff80 : 23'h0) | (vdp_VAz ? 23'h7f : 23'h0);
	m68k_va_d = {23{cpu_Az}};
	cart_va_d = {M3, M3, M3, 20'hfffff};
	va_new = (~ym_va_d & ym_va_o) | (~m68k_va_d & cpu_VA) | (~cart_va_d & 23'h500000) | (ym_va_d & m68k_va_d & cart_va_d & VA_bus);
	// Z80 address bus: fc1004 ZA_o (arbiter [15:8] unless vtoz, [7:1] = VA[6:0] via the I/O chip, [0] = ZA0_o),
	// driven while the arbiter owns the Z80 bus (VZ low); else the Z80; else hold
	ym_za_o = {(t_vtoz ? 8'h0 : t_za_o), va_new[6:0], t_za0_o};
	ym_za_d = {16{t_vz}};
	z80_za_d = {16{z80_Az}};
	za_new = (~ym_za_d & ym_za_o) | (~z80_za_d & z80_A) | (ym_za_d & z80_za_d & ZA_bus);
	// ---- assign the DUT inputs
	VA_bus = va_new; VA_i = va_new[22:7];
	ZA_bus = za_new; ZA_i = za_new[15:7]; ZA0_i = za_new[0];
	AS_i  = (t_strobe_dir & cpu_Sz) ? 1'b1 : ((~t_strobe_dir & t_as_o)  | (~cpu_Sz & cpu_AS));
	UDS_i = (t_strobe_dir & cpu_Sz) ? 1'b1 : ((~t_strobe_dir & t_uds_o) | (~cpu_Sz & cpu_UDS));
	LDS_i = (t_strobe_dir & cpu_Sz) ? 1'b1 : ((~t_strobe_dir & t_lds_o) | (~cpu_Sz & cpu_LDS));
	RW_i  = (t_rw_d & cpu_Sz)       ? 1'b1 : ((~t_rw_d & t_rw_o)        | (~cpu_Sz & cpu_RW));
	DTACK_i = t_dtack_o & vdp_dtack & vdp_ram_dtack & exp_dtack & tmss_dtack;
	BGACK_i = t_bgack_o & vdp_bgack;
	BG = cpu_BG;
	FC0 = cpu_FCz | cpu_FC[0];
	FC1 = cpu_FCz | cpu_FC[1];
	VD8_i = ~t_w12 ? t_vd8_o : (cpu_Dz ? vd8_other : cpu_D8);
	CAS0 = vdp_cas0;
	OE0 = vdp_oe0;
	MREQ_i = (t_vz & z80_Az) ? 1'b1 : ((~t_vz & t_mreq_o) | (~z80_Az & z80_MREQ));
	ZRD_i  = (t_vz & z80_Az) ? 1'b1 : ((~t_vz & t_zrd_o)  | (~z80_Az & z80_RD));
	ZWR_i  = (t_vz & z80_Az) ? 1'b1 : ((~t_vz & t_zwr_o)  | (~z80_Az & z80_WR));
	IORQ = z80_Az ? 1'b1 : z80_IORQ;
	M1 = z80_M1;
	ZBAK = z80_BUSAK;
	WAIT_i = t_wait_o;                       // md_board: WAIT = ~WAIT_pull, nothing else pulls it
	ZD0_i = z80_Dz ? zd0_other : z80_D0;
end

// ---------------------------------------------------------------- directed-phase sanity (not part of the proof)
task automatic expect_(input bit cond, input string what);
	if (!cond) begin
		$display("WARN cycle %0d: expectation not met: %s", cycle, what);
		nwarn = nwarn + 1;
	end else
		$display("INFO cycle %0d: %s", cycle, what);
endtask

// event counters on the die model
integer n_vres_fall = 0, n_dff23 = 0, n_w287 = 0, n_br = 0, n_bgack_arb = 0, n_dma = 0, n_vpa = 0, n_ce0 = 0, n_rom = 0, n_ras2 = 0;
integer n_fdc = 0, n_time = 0, n_noe = 0, n_mreq_o = 0, n_as_o = 0, n_zwait = 0, n_zbank = 0, n_refstall = 0;
integer last_w287 = 0, w287_period = 0;
integer vres_release_cycle = -1;
always @(negedge VRES_a) n_vres_fall = n_vres_fall + 1;
always @(posedge VRES_a) if (vres_release_cycle < 0) vres_release_cycle = cycle;
always @(posedge u_die.dff23.l2) n_dff23 = n_dff23 + 1;
always @(posedge u_die.w287) begin n_w287 = n_w287 + 1; w287_period = cycle - last_w287; last_w287 = cycle; end
always @(negedge BR_a) n_br = n_br + 1;
always @(negedge BGACK_o_a) n_bgack_arb = n_bgack_arb + 1;
always @(negedge VPA_a) n_vpa = n_vpa + 1;
always @(negedge CE0_a) n_ce0 = n_ce0 + 1;
always @(negedge ROM_a) n_rom = n_rom + 1;
always @(negedge RAS2_a) n_ras2 = n_ras2 + 1;
always @(negedge FDC_a) n_fdc = n_fdc + 1;
always @(negedge TIME_a) n_time = n_time + 1;
always @(negedge NOE_a) n_noe = n_noe + 1;
always @(negedge MREQ_o_a) n_mreq_o = n_mreq_o + 1;
always @(negedge AS_o_a) if (!strobe_dir_a) n_as_o = n_as_o + 1;
always @(negedge WAIT_o_a) n_zwait = n_zwait + 1;
// RAM-cycle DTACK latency histogram (68000 wait states), refresh stalls show up as the tail
integer ram_wait_hist [0:8];
initial for (int k = 0; k < 9; k++) ram_wait_hist[k] = 0;

// ---------------------------------------------------------------- 68000 bus-cycle model
localparam MAXWAIT = 24;          // clocks of wait states before a cycle is abandoned (stimulus only)
integer cpu_skew = 1;             // output delay after the VCLK edge, MCLK cycles (re-drawn per cycle)
bit cpu_honour_vres = 1;          // directed: the 68000 is in reset while VRES is low (RESET_pull)

// one 68000 bus cycle; addr is A23..A1 (VA), u/l = strobe asserted, returns wait clocks
task automatic cyc68k(input [22:0] addr, input [2:0] fc, input bit read, input bit u, input bit l, input bit d8, output integer waits);
	cpu_skew = $urandom_range(0, 3);
	// S0: address, FC
	v_edge(1); tick(cpu_skew);
	cpu_VA = addr; cpu_FC = fc; cpu_Az = 0; cpu_FCz = 0; cpu_Sz = 0;
	// S1
	v_edge(0);
	// S2: AS; strobes on a read; R/W low on a write
	v_edge(1); tick(cpu_skew);
	cpu_AS = 0;
	if (read) begin cpu_UDS = ~u; cpu_LDS = ~l; end else cpu_RW = 0;
	// S3: write data out
	v_edge(0); tick(cpu_skew);
	if (!read) begin cpu_D8 = d8; cpu_Dz = 0; end
	// S4: write strobes; DTACK (or VPA, autovector) sampled at the end of S4, wait states in pairs
	v_edge(1); tick(cpu_skew);
	if (!read) begin cpu_UDS = ~u; cpu_LDS = ~l; end
	waits = 0;
	v_edge(0);
	while (!(DTACK_i == 1'b0 || VPA_a == 1'b0) && waits < MAXWAIT) begin
		v_edge(1); v_edge(0); waits = waits + 1;
	end
	// S5, S6 (data latched at the end of S6)
	v_edge(1);
	// S7: negate AS and strobes; R/W high and data released at the end of S7
	v_edge(0); tick(cpu_skew);
	cpu_AS = 1; cpu_UDS = 1; cpu_LDS = 1;
	tick(3);
	cpu_RW = 1; cpu_Dz = 1;
	if (addr[22:20] == 3'b111) ram_wait_hist[waits > 8 ? 8 : waits] = ram_wait_hist[waits > 8 ? 8 : waits] + 1;
endtask

// bus arbitration side of the 68000: BG follows BR with a clock of latency; strobes/address/FC
// released while BGACK is asserted (between bus cycles)
bit cpu_in_cycle = 0;
initial begin
	#1;
	forever begin
		v_edge(0); tick(1);
		cpu_BG = (BR_bus == 1'b0) ? 1'b0 : 1'b1;
		if (!cpu_in_cycle) begin
			if (BGACK_i == 1'b0) begin cpu_Sz = 1; cpu_Az = 1; cpu_FCz = 1; cpu_Dz = 1; end
			else if (cpu_Sz) begin cpu_Sz = 0; cpu_Az = 0; cpu_FCz = 0; end
		end
	end
end

// a bus cycle when the 68000 may run one: not reset (directed), not granted away
task automatic bus68k(input [22:0] addr, input [2:0] fc, input bit read, input bit u, input bit l, input bit d8);
	integer w;
	while ((cpu_honour_vres && VRES_a == 1'b0) || cpu_BG == 1'b0 || BGACK_i == 1'b0) v_edge(1);
	cpu_in_cycle = 1;
	cyc68k(addr, fc, read, u, l, d8, w);
	cpu_in_cycle = 0;
endtask
task automatic idle68k(input integer clocks);
	repeat (clocks) v_edge(1);
endtask

// byte address -> VA (A23..A1)
function automatic [22:0] va(input [23:0] a);
	va = a[23:1];
endfunction

// ---------------------------------------------------------------- Z80 bus-cycle model
bit z80_enable = 0;
integer z80_skew = 1;
integer z80_maxtw = 400;

task automatic z80_wait_states();
	integer n;
	n = 0;
	while (WAIT_i == 1'b0 && n < z80_maxtw) begin z_edge(1); z_edge(0); tick(1); n = n + 1; end
endtask
// M1 (opcode fetch) with the refresh cycle in T3/T4
task automatic z80_m1(input [15:0] addr);
	z80_skew = $urandom_range(1, 3);
	z_edge(1); tick(z80_skew); z80_A = addr; z80_Az = 0; z80_M1 = 0;                      // T1 rise
	z_edge(0); tick(z80_skew); z80_MREQ = 0; z80_RD = 0;                                   // T1 fall
	z_edge(1);                                                                              // T2 rise
	z_edge(0); tick(1); z80_wait_states();                                                  // T2 fall: WAIT sampled
	z_edge(1); tick(z80_skew); z80_MREQ = 1; z80_RD = 1; z80_M1 = 1; z80_A = {8'h00, 8'($urandom)}; // T3 rise: refresh address
	z_edge(0); tick(z80_skew); z80_MREQ = 0;                                                // T3 fall: refresh MREQ
	z_edge(1);                                                                              // T4 rise
	z_edge(0); tick(z80_skew); z80_MREQ = 1;                                                // T4 fall
endtask
// memory read / write (3 T)
task automatic z80_mem(input [15:0] addr, input bit write, input bit d0);
	z80_skew = $urandom_range(1, 3);
	z_edge(1); tick(z80_skew); z80_A = addr; z80_Az = 0;                                    // T1 rise
	z_edge(0); tick(z80_skew); z80_MREQ = 0; if (!write) z80_RD = 0; else begin z80_D0 = d0; z80_Dz = 0; end // T1 fall
	z_edge(1);                                                                              // T2 rise
	z_edge(0); tick(z80_skew); if (write) z80_WR = 0;                                       // T2 fall: WR, WAIT sampled
	z80_wait_states();
	z_edge(1);                                                                              // T3 rise
	z_edge(0); tick(z80_skew); z80_MREQ = 1; z80_RD = 1; z80_WR = 1; z80_Dz = 1;            // T3 fall
endtask
// I/O read / write (4 T, one automatic wait state)
task automatic z80_io(input [15:0] port, input bit write, input bit d0);
	z80_skew = $urandom_range(1, 3);
	z_edge(1); tick(z80_skew); z80_A = port; z80_Az = 0;                                    // T1 rise
	z_edge(0);
	z_edge(1); tick(z80_skew); z80_IORQ = 0; if (!write) z80_RD = 0; else begin z80_WR = 0; z80_D0 = d0; z80_Dz = 0; end // T2 rise
	z_edge(0);
	z_edge(1); z_edge(0); tick(1); z80_wait_states();                                       // TW
	z_edge(1);                                                                              // T3 rise
	z_edge(0); tick(z80_skew); z80_IORQ = 1; z80_RD = 1; z80_WR = 1; z80_Dz = 1;            // T3 fall
endtask
task automatic z80_release();
	z80_Az = 1; z80_MREQ = 1; z80_IORQ = 1; z80_RD = 1; z80_WR = 1; z80_M1 = 1; z80_Dz = 1;
endtask

// the Z80 program: reset from ZRES, BUSRQ/BUSAK from ZBR, otherwise random machine cycles
initial begin
	#1;
	forever begin
		integer cls;
		reg [15:0] a;
		if (!z80_enable) begin z80_release(); z80_BUSAK = 1; tick(10); continue; end
		if (ZRES_a == 1'b0) begin                                        // RESET: bus released, BUSAK inactive
			z80_release(); z80_BUSAK = 1;
			while (ZRES_a == 1'b0 && z80_enable) z_edge(1);
			repeat (2) z_edge(1);
			continue;
		end
		if (ZBR_a == 1'b0) begin                                         // BUSRQ sampled at the end of a machine cycle
			z_edge(0); tick(z80_skew); z80_release(); z80_BUSAK = 0;
			while (ZBR_a == 1'b0 && ZRES_a == 1'b1 && z80_enable) z_edge(1);
			z_edge(0); tick(z80_skew); z80_BUSAK = 1; z80_Az = 0;
			continue;
		end
		cls = $urandom_range(0, 99);
		if (cls < 40)      z80_m1(16'($urandom) & 16'h1fff);                            // fetch from Z80 RAM
		else if (cls < 42) z80_m1(16'h8000 | 16'($urandom));                             // fetch from the bank window
		else if (cls < 60) z80_mem(16'($urandom) & 16'h1fff, $urandom, $urandom);        // RAM read/write
		else if (cls < 68) z80_mem(16'h4000 | (16'($urandom) & 16'h3), ($urandom_range(0, 3) != 0), $urandom); // FM
		else if (cls < 72) z80_mem(16'h6000 | (16'($urandom) & 16'hff), 1, $urandom);    // bank register (shift ZD0)
		else if (cls < 77) z80_mem(16'h7f00 | (16'($urandom) & 16'h1f), ($urandom_range(0, 3) != 0), $urandom); // VDP/PSG via the 68k bus
		else if (cls < 89) begin z80_mem(16'h8000 | 16'($urandom), ($urandom_range(0, 2) == 0), $urandom); n_zbank = n_zbank + 1; end // bank window -> 68k bus
		else if (cls < 92) z80_io(16'($urandom), $urandom, $urandom);                     // I/O
		else if (cls < 95) z80_mem(16'h2000 | (16'($urandom) & 16'h1fff), $urandom, $urandom); // RAM mirror
		else               z80_mem(16'($urandom), $urandom, $urandom);                    // anything
		if ($urandom_range(0, 3) == 0) repeat ($urandom_range(1, 4)) z_edge(1);          // internal T-states
	end
end

// ---------------------------------------------------------------- VDP model
bit vdp_enable = 0;
// DTACK for its own registers: C00000-C0001F and mirrors (A23:A21 = 110, A18:A16 = 000, A7:A5 = 000)
initial begin
	#1;
	forever begin
		tick(1);
		if (vdp_enable && AS_i == 1'b0 && vdp_VAz && ((VA_bus & 23'h738070) == 23'h600000)) begin
			tick($urandom_range(14, 42));
			if (AS_i == 1'b0) begin vdp_dtack = 0; while (AS_i == 1'b0) tick(1); tick($urandom_range(0, 2)); vdp_dtack = 1; end
		end
	end
end
// work RAM strobes and DTACK for 68k-bus cycles at E00000-FFFFFF (the VDP is the DRAM controller
// and the DTACK source for work RAM). A refresh cycle in progress (REF from the arbiter: its
// 128-VCLK timer between bus cycles, or the Z80's M1 refresh) holds the access off for ~2 VCLK:
// this is where the refresh stall lands on the 68000 in the real machine.
integer ref_busy = 0;
always @(negedge REF_a) ref_busy = 2 * T68;
always @(negedge MCLK) if (ref_busy > 0) ref_busy = ref_busy - 1;
initial begin
	#1;
	forever begin
		tick(1);
		if (vdp_enable && AS_i == 1'b0 && vdp_VAz && VA_bus[22:20] == 3'b111 && M3) begin
			tick($urandom_range(6, 12));
			while (ref_busy > 0 && AS_i == 1'b0) begin n_refstall = n_refstall + 1; tick(1); end
			if (AS_i == 1'b0) begin
				vdp_cas0 = 0; if (RW_i) vdp_oe0 = 0;
				tick($urandom_range(4, 8)); if (AS_i == 1'b0) vdp_ram_dtack = 0;
				while (AS_i == 1'b0) tick(1);
				vdp_ram_dtack = 1;
				tick($urandom_range(0, 3)); vdp_cas0 = 1; vdp_oe0 = 1;
			end
		end
	end
end
// DMA from the 68k bus: BR, wait for BG with the bus idle, BGACK, one CAS0/OE0 strobe per word
reg dma_req = 0;
reg [22:0] dma_src = 0;
integer dma_len = 0;
task automatic dma(input [22:0] src, input integer len);
	dma_src = src; dma_len = len; dma_req = 1;
endtask
initial begin
	#1;
	forever begin
		integer i, t;
		wait (dma_req);
		v_edge(1); vdp_br = 0;
		t = 0;
		while (!(cpu_BG == 1'b0 && AS_i == 1'b1 && BGACK_i == 1'b1 && DTACK_i == 1'b1) && t < 400) begin v_edge(1); t = t + 1; end
		if (t < 400) begin
			vdp_bgack = 0; v_edge(1); vdp_br = 1;
			tick($urandom_range(2, 6));
			vdp_VA = dma_src; vdp_VAz = 0;
			for (i = 0; i < dma_len; i = i + 1) begin
				tick($urandom_range(10, 14));
				vdp_oe0 = 0; vdp_cas0 = 0;
				tick($urandom_range(12, 16));
				vdp_cas0 = 1; vdp_oe0 = 1;
				tick($urandom_range(4, 8));
				vdp_VA = vdp_VA + 1;
			end
			tick(6); vdp_VAz = 1; vdp_bgack = 1;
			n_dma = n_dma + 1;
		end else begin
			vdp_br = 1;
			$display("INFO cycle %0d: DMA bus grant not obtained (bus busy), request dropped", cycle);
		end
		dma_req = 0;
	end
end
// occasional data-bus activity from memories / I/O chip (D8, ZD0 when nobody in the models drives)
initial begin
	#1;
	forever begin
		tick($urandom_range(3, 40));
		vd8_other = $urandom; zd0_other = $urandom;
	end
end

// ---------------------------------------------------------------- expansion (Mega CD gate array) and TMSS DTACK
initial begin
	#1;
	forever begin
		tick(1);
		if (vdp_enable && AS_i == 1'b0 && vdp_VAz && VA_bus[22:21] == 2'b01 && $urandom_range(0, 1)) begin // 400000-7FFFFF, half the time early
			tick($urandom_range(8, 11));
			if (AS_i == 1'b0) begin exp_dtack = 0; while (AS_i == 1'b0) tick(1); exp_dtack = 1; end
		end
	end
end
initial begin
	#1;
	forever begin
		tick(1);
		if (vdp_enable && AS_i == 1'b0 && vdp_VAz && VA_bus[22:8] == 15'h50a0) begin                 // A14000-A141FF
			tick($urandom_range(10, 20));
			if (AS_i == 1'b0) begin tmss_dtack = 0; while (AS_i == 1'b0) tick(1); tmss_dtack = 1; end
		end
	end
end

// ---------------------------------------------------------------- 68000 programs
localparam [2:0] FC_UD = 3'd1, FC_UP = 3'd2, FC_SD = 3'd5, FC_SP = 3'd6, FC_IACK = 3'd7;
bit directed_done = 0;

task automatic rd(input [23:0] a, input [2:0] fc = FC_SD);  bus68k(va(a), fc, 1, 1, 1, 0); endtask
task automatic rdb(input [23:0] a, input [2:0] fc = FC_SD); bus68k(va(a), fc, 1, ~a[0], a[0], 0); endtask
task automatic wr(input [23:0] a, input bit d8, input [2:0] fc = FC_SD);  bus68k(va(a), fc, 0, 1, 1, d8); endtask
task automatic wrb(input [23:0] a, input bit d8, input [2:0] fc = FC_SD); bus68k(va(a), fc, 0, ~a[0], a[0], d8); endtask
task automatic iack(input [2:0] level); bus68k(va({20'hfffff, 1'b1, level}), FC_IACK, 1, 1, 1, 0); endtask

task automatic directed_68k();
	integer k, w0;
	// reset vector fetch (cart present: CE0 region)
	rd(24'h000000, FC_SP); rd(24'h000002, FC_SP); rd(24'h000004, FC_SP); rd(24'h000006, FC_SP);
	expect_(n_ce0 >= 4, "CE0 asserted for the vector fetch (CART = 0, 000000-3FFFFF)");
	// ROM: back-to-back word and byte reads, program and data spaces
	for (k = 0; k < 8; k = k + 1) rd(24'h000200 + 2 * k, FC_SP);
	rdb(24'h000301); rdb(24'h000300); rd(24'h3ffffe, FC_UD);
	// work RAM: writes, byte writes, reads, then a long back-to-back run to meet refresh windows
	wr(24'hff0000, 1); wr(24'hff0002, 0); wrb(24'hff0005, 1); wrb(24'hff0004, 0);
	rd(24'hff0000); rd(24'hff0002); rdb(24'hff0005); rd(24'he00000);
	w0 = n_dff23;
	for (k = 0; k < 60; k = k + 1) begin
		if (k & 1) rd(24'hff0000 + 2 * k); else wr(24'hff0000 + 2 * k, k[1]);
	end
	expect_(n_dff23 > w0, "refresh stall flag (dff23) pulsed during the back-to-back RAM run");
	// VDP
	wr(24'hc00004, 1); wr(24'hc00004, 0); rd(24'hc00004); wr(24'hc00000, 1); rd(24'hc00000); rd(24'hc00008); wrb(24'hc00011, 0);
	// I/O chip
	rd(24'ha10000); rd(24'ha10003); wr(24'ha10009, 0); rdb(24'ha10005);
	// Z80 bring-up: BUSREQ, release reset, wait for BUSAK, poll A11100
	wr(24'ha11100, 1);
	wr(24'ha11200, 1);
	expect_(ZRES_a == 1'b1, "ZRES released by the A11200 write");
	for (k = 0; k < 12 && ZBAK == 1'b1; k = k + 1) rd(24'ha11100);
	expect_(ZBAK == 1'b0, "Z80 BUSAK after BUSREQ (A11100 <- 0100) and reset release");
	// 68000 -> Z80 bus (A00000-A0FFFF): RAM, FM, bank register, PSG window
	wrb(24'ha00000, 1); wrb(24'ha00001, 0); wr(24'ha00100, 1); rdb(24'ha00000); rdb(24'ha00001); rd(24'ha01ffe);
	wrb(24'ha04000, 0); wrb(24'ha04001, 1); rdb(24'ha04000); wrb(24'ha06000, 1); wrb(24'ha07f11, 0);
	expect_(n_mreq_o > 0, "arbiter drove MREQ_o for 68000 accesses to the Z80 bus");
	// release the Z80 (it then runs its own cycles incl. bank-window accesses through the arbiter)
	wr(24'ha11100, 0);
	for (k = 0; k < 40; k = k + 1) begin
		case (k % 4)
			0: rd(24'h000400 + 2 * k, FC_SP);
			1: rd(24'hff0100 + 2 * k);
			2: wr(24'hff0200 + 2 * k, k[0]);
			default: rd(24'h000800 + 2 * k, FC_UP);
		endcase
	end
	expect_(n_br > 0, "Z80 bank-window access requested the 68k bus (BR)");
	expect_(n_bgack_arb > 0, "arbiter became bus master (BGACK_o)");
	expect_(n_as_o > 0, "arbiter drove AS_o as bus master");
	// VDP DMA from ROM, RAM and the expansion, with the 68000 and the Z80 running
	dma(va(24'h000100), 24); wr(24'hc00004, 1);
	for (k = 0; k < 12; k = k + 1) rd(24'h001000 + 2 * k, FC_SP);
	dma(va(24'hff0000), 16); wr(24'hc00004, 0);
	for (k = 0; k < 12; k = k + 1) rd(24'hff0300 + 2 * k);
	dma(va(24'h420000), 20); wr(24'hc00004, 1);
	for (k = 0; k < 12; k = k + 1) rd(24'h002000 + 2 * k, FC_SP);
	dma(va(24'h600000), 12); wr(24'hc00004, 1);
	for (k = 0; k < 12; k = k + 1) rd(24'h002100 + 2 * k, FC_SP);
	wait (!dma_req);
	expect_(n_dma >= 4, "VDP DMA bursts completed (BR/BG/BGACK, CAS0 per word)");
	// expansion: BIOS window (ROM), word RAM (RAS2), FDC, TIME
	rd(24'h400000, FC_SP); rd(24'h400002, FC_SP); rd(24'h41fffe);
	expect_(n_rom > 0, "ROM asserted for 400000-41FFFF with a cart present");
	wr(24'h600000, 1); wr(24'h600002, 0); rd(24'h600000); rdb(24'h63ffff); wrb(24'h600004, 1);
	expect_(n_ras2 > 0, "RAS2 asserted for word RAM accesses (600000-63FFFF)");
	rd(24'ha12000); wr(24'ha12002, 1); rdb(24'ha12001);
	expect_(n_fdc > 0, "FDC asserted for A12000");
	wr(24'ha130f1, 1); rd(24'ha13000); wrb(24'ha130f1, 0);
	expect_(n_time > 0, "TIME asserted for A13000");
	// interrupt acknowledge (autovector via VPA)
	iack(3'd6); rd(24'h000078, FC_SD); iack(3'd4); rd(24'h000070, FC_SD); iack(3'd2);
	expect_(n_vpa > 0, "VPA asserted for the IACK cycles");
	// memory mode register (A11000, D8) changes the decode; access ROM/RAM/expansion in both states
	wr(24'ha11000, 1);
	rd(24'h000000, FC_SP); rd(24'hff0000); rd(24'h400000); rd(24'h600000); wr(24'hff0000, 0);
	wr(24'ha11000, 0);
	rd(24'h000000, FC_SP); rd(24'hff0000); rd(24'h400000);
	// no cartridge: CART = 1 swaps the CE0/ROM windows
	CART = 1;
	rd(24'h000000, FC_SP); rd(24'h000002, FC_SP); rd(24'h400000); rd(24'h600000); wr(24'hff0000, 1);
	dma(va(24'h000000), 8); wr(24'hc00004, 1); for (k = 0; k < 8; k = k + 1) rd(24'h000010 + 2 * k, FC_SP); wait (!dma_req);
	CART = 0;
	// Z80 BUSREQ while it is running (contention), Z80 reset and release
	wr(24'ha11100, 1);
	for (k = 0; k < 12 && ZBAK == 1'b1; k = k + 1) rd(24'ha11100);
	rdb(24'ha00000); wrb(24'ha00001, 1);
	wr(24'ha11200, 0); wr(24'ha11200, 1);
	wr(24'ha11100, 0);
	for (k = 0; k < 24; k = k + 1) begin if (k & 1) rd(24'h000600 + 2 * k, FC_SP); else rd(24'hff0400 + 2 * k); end
	// TMSS register addresses (external DTACK), unmapped, ROM byte reads in user mode
	rd(24'ha14000); wr(24'ha14000, 0); wrb(24'ha14101, 1); rd(24'h800000); rdb(24'h000101, FC_UP);
	// RAM stress: 200 back-to-back RAM cycles (refresh stalls land inside bus cycles)
	for (k = 0; k < 200; k = k + 1) begin
		case (k % 3) 0: rd(24'hff1000 + 2 * k); 1: wr(24'hff2000 + 2 * k, k[0]); default: rdb(24'hff3001 + 2 * k); endcase
	end
endtask

// constrained-random 68000 traffic with the same cycle shapes
task automatic random_68k();
	integer cls, gap;
	reg [23:0] a;
	reg [2:0] fc;
	reg wrt, u, l, d8;
	cls = $urandom_range(0, 99);
	if (cls < 20)      a = 24'($urandom) & 24'h3ffffe;                                     // cart ROM
	else if (cls < 40) a = ($urandom_range(0, 3) == 0) ? (24'he00000 | (24'($urandom) & 24'h1ffffe)) : (24'hff0000 | (24'($urandom) & 24'hfffe)); // work RAM
	else if (cls < 48) a = 24'hc00000 | (24'($urandom) & 24'h1e) | (($urandom_range(0, 7) == 0) ? (24'($urandom) & 24'h1c7f00) : 24'h0); // VDP (+mirrors)
	else if (cls < 53) a = 24'ha10000 | (24'($urandom) & 24'h1e);                           // I/O chip
	else if (cls < 61) a = 24'ha11000 | (24'($urandom) & 24'h3fe);                          // memory mode / Z80 BUSREQ / Z80 RESET (+A11300)
	else if (cls < 64) a = ($urandom & 1) ? (24'ha12000 | (24'($urandom) & 24'hfe)) : (24'ha13000 | (24'($urandom) & 24'hfe)); // FDC / TIME
	else if (cls < 72) a = 24'ha00000 | (24'($urandom) & 24'hffff);                         // Z80 bus
	else if (cls < 82) a = 24'h400000 | (24'($urandom) & 24'h3ffffe);                       // expansion
	else if (cls < 85) a = 24'hfffff0 | (24'($urandom) & 24'he);                            // IACK (FC = 7)
	else if (cls < 88) a = 24'ha14000 | (24'($urandom) & 24'h1fe);                          // TMSS regs
	else if (cls < 91) a = 24'h200000 | (24'($urandom) & 24'h1ffffe);                       // upper cart
	else               a = 24'($urandom);                                                    // anything
	fc = (cls >= 82 && cls < 85) ? FC_IACK : 3'($urandom_range(0, 3) == 0 ? ($urandom & 1 ? FC_UD : FC_UP) : ($urandom & 1 ? FC_SD : FC_SP));
	wrt = (fc == FC_IACK) ? 0 : ($urandom_range(0, 9) < 4);
	if (cls >= 53 && cls < 61) wrt = ($urandom_range(0, 4) != 0);
	case ($urandom_range(0, 9)) 0, 1: begin u = 1; l = 0; end 2, 3: begin u = 0; l = 1; end default: begin u = 1; l = 1; end endcase
	d8 = $urandom;
	bus68k(va(a), fc, ~wrt, u, l, d8);
	gap = $urandom_range(0, 9);
	if (gap >= 6) idle68k(gap == 9 ? $urandom_range(3, 30) : $urandom_range(1, 2));
	if ($urandom_range(0, 39) == 0 && !dma_req) dma(va(($urandom_range(0, 2) == 0) ? 24'hff0000 : (($urandom & 1) ? 24'h000000 : 24'h400000)) + 23'($urandom & 23'h1fff), $urandom_range(2, 48));
endtask

// ---------------------------------------------------------------- random side processes (stress: SRES, M3, test, CART, WRES)
initial begin
	#1;
	wait (rand_phase);
	while (rand_phase) begin
		tick(1);
		if ($urandom_range(0, 99999) < 2) begin CART = ~CART; end
		if ($urandom_range(0, 99999) < 1) begin M3 = 0; tick($urandom_range(200, 3000)); M3 = 1; end
		if ($urandom_range(0, 99999) < 1) begin test_mode_0 = 1; tick($urandom_range(20, 400)); test_mode_0 = 0; end
		if ($urandom_range(0, 99999) < 2) begin WRES = 0; tick($urandom_range(100, 20000)); WRES = 1; end
	end
end
initial begin
	#1;
	wait (rand_phase);
	while (rand_phase) begin
		tick(1);
		if ($urandom_range(0, 199999) < 1) begin SRES = 0; tick($urandom_range(1, 300)); SRES = 1; end
	end
end

// ---------------------------------------------------------------- main
integer seed;
integer n_random;
integer t0;
initial begin
	if (!$value$plusargs("SEED=%d", seed)) seed = 1;
	if (!$value$plusargs("NRAND=%d", n_random)) n_random = 300000;
	void'($urandom(seed));
	$display("tb_ym6045: seed=%0d random cycles=%0d", seed, n_random);
	#1;

	// ---- power-up: SRES low, clocks running, bus idle
	tick(50);
	SRES = 0; tick(300); SRES = 1; tick(30);
	xcheck_en = 1;
	expect_(VRES_a == 1'b0, "VRES asserted after SRES (power-on timer running)");
	expect_(ZRES_a == 1'b0, "ZRES asserted after SRES");
	vdp_enable = 1; z80_enable = 1;
	// the arbiter's power-on timer: 768 refresh periods of the 8-bit VCLK refresh counter chain
	t0 = cycle;
	while (VRES_a == 1'b0 && cycle - t0 < 2500000) tick(100);
	expect_(VRES_a == 1'b1, "VRES released by the power-on timer");
	$display("INFO cycle %0d: power-on timer expired after %0d MCLK cycles (%0d refresh requests, refresh period %0d MCLK = %0d VCLK)",
		cycle, cycle - t0, n_w287, w287_period, w287_period / T68);
	idle68k(8);

	// ---- directed 68000 / Z80 / VDP traffic
	directed_68k();
	directed_done = 1;
	$display("INFO cycle %0d: directed phase done, warnings=%0d", cycle, nwarn);
	$display("INFO RAM-cycle wait-state histogram (0..7, 8+): %0d %0d %0d %0d %0d %0d %0d %0d %0d; dff23 refresh-stall pulses %0d",
		ram_wait_hist[0], ram_wait_hist[1], ram_wait_hist[2], ram_wait_hist[3], ram_wait_hist[4], ram_wait_hist[5], ram_wait_hist[6], ram_wait_hist[7], ram_wait_hist[8], n_dff23);

	// ---- reset button: WRES held low across a rising edge of the timer's last stage (period 512
	// refresh periods, ~0.93M MCLK); the 68000 keeps running its cycles and re-fetches vectors
	// when VRES pulses (dff69 -> w334 -> VRES for one refresh period)
	t0 = n_vres_fall;
	WRES = 0;
	fork
		begin tick(1000000); end
		begin
			while (WRES == 1'b0) begin random_68k(); end
		end
	join_any
	WRES = 1;
	expect_(n_vres_fall > t0, "VRES pulsed while the reset button was held (dff69/dff60/w334 path)");
	directed_done = 1;

	// ---- constrained random; the 68000 no longer waits for VRES (a random SRES would idle it for 1.4M cycles)
	cpu_honour_vres = 0;
	rand_phase = 1;
	t0 = cycle;
	while (cycle - t0 < n_random) random_68k();
	rand_phase = 0;
	M3 = 1; test_mode_0 = 0; WRES = 1;
	// ---- run out the timer chain once more so the WRES release propagates (dff69 <- 1 on the next dff74 edge)
	while (cycle < 3400000) random_68k();
	tick(20);
	$display("INFO RAM-cycle wait-state histogram (0..7, 8+): %0d %0d %0d %0d %0d %0d %0d %0d %0d; dff23 refresh-stall pulses %0d",
		ram_wait_hist[0], ram_wait_hist[1], ram_wait_hist[2], ram_wait_hist[3], ram_wait_hist[4], ram_wait_hist[5], ram_wait_hist[6], ram_wait_hist[7], ram_wait_hist[8], n_dff23);
	$display("INFO events (die): VRES falls %0d, refresh requests %0d, BR %0d, arbiter BGACK %0d, arbiter AS %0d, Z80 bank accesses %0d, WAIT %0d, DMA bursts %0d, VPA %0d, CE0 %0d, ROM %0d, RAS2 %0d, FDC %0d, TIME %0d, NOE %0d, MREQ_o %0d",
		n_vres_fall, n_w287, n_br, n_bgack_arb, n_as_o, n_zbank, n_zwait, n_dma, n_vpa, n_ce0, n_rom, n_ras2, n_fdc, n_time, n_noe, n_mreq_o);
	$display("PASS: %0d MCLK cycles, %0d compare points, %0d mismatches, %0d directed warnings", cycle, ncmp, nmis, nwarn);
	$finish;
end

initial begin repeat (6000000) @(posedge MCLK); $display("TIMEOUT cycle=%0d", cycle); $finish; end

endmodule
