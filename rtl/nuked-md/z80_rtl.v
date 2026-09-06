/*
 * Copyright (C) 2022-2023 nukeykt
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
 *  Z80 emulator
 *  Thanks:
 *      Antoine Bercovici:
 *          Z80 decap & die shot.
 *      Visual6502 team:
 *          VisualZ80 simulator.
 *      org, andkorzh, HardWareMan (emu-russia):
 *          help & support.
 */
 
 // Z80(NMOS)

/*
 * z80cpu_rtl -- 1:1 synthesis-friendly representation of z80cpu (rtl/nuked-md/z80.v), the die-level
 * Z80 (NMOS) model.
 *
 * Same port list, same logic, same storage, same MCLK (the 107.386 MHz sampling clock, md_board's
 * MCLK2). CLK (= ZCLK, the Z80 clock, MCLK/30, 16 high / 14 low as the VDP prescaler makes it) stays
 * a data input exactly as in z80.v (`wire clk = CLK;`). Nothing behavioural was added or removed:
 * every `assign`, every wire/reg declaration, the pla, the register file (`regs`, `regs2` and their
 * `initial` block), the bus resolution wires and all 41 inline `always @(posedge MCLK)` blocks are
 * copied verbatim from z80.v (same names, same expressions, same order); only the 180 instances of
 * the three z80.v helper modules (z80_dlatch, z80_rs_trig_nor, z80_rs_trig_nand) are replaced by
 * inline registered logic that produces the same value at every posedge MCLK, so no helper module
 * remains. The original instance line is kept as a comment above each block; storage registers are
 * named <instance>_<reg> after the instance name and the helper module's register (outp / q / nq);
 * the instance's output wires keep their original names, assigned from that storage.
 *
 * Primitive census of z80cpu in z80.v (180 instances of 3 kinds, 41 inline register blocks):
 *   z80_dlatch       128  dl1-dl84 (dl69/dl74/dl78/dl80 do not exist; dl46/dl47/dl48/dl49 have a
 *                         second instance dlNN_i), dl_w38, dw98 dw99 dw104 dw107 dw112 dw130 dw134
 *                         dw292 dw293 dw298 dw301 dw305 dw307 dw319 dw341 dw345 dw346 dw347 dw359
 *                         dw369 dw370 dw372 dw373 dw377 dw378_1 dw378_2 dw379_1 dw379_2 dw381 dw390
 *                         dw391 dw400 dw404 dw416 dw417 dw418 dw419 dw430 dw431 dw449 dw452 dw453
 *                         dw470. Enable: clk for 116 of them; w324 (dl46 dl46_i dl47 dl47_i dl48
 *                         dl48_i), w360 (dl49 dl49_i), w432 (dl83 dl84), clk & w446 (dw449 dl75)
 *   z80_rs_trig_nor   34  rs1 rs2 rs5 rs7 rs6 rs9 rs18 rs19 rs21 rs22 rs31 rs33 rs39 rs44 rs51 rs54
 *                         rs56 rs59 rs66 rs115 rs120 rs121 rs123 rs127 rsrfsh rs131 rs322 rs327
 *                         rs330 rs332 rs361 rs442 haltrs m1rs
 *   z80_rs_trig_nand  18  rs4 rs8 rs34 rs37 rs48 rs50 rs58 rs61 rs63 rs68 rs109 rs111 rs114 rs144
 *                         rs205 rs210 rs321 rs380
 *   inline blocks     41  already plain posedge-MCLK registers in z80.v, copied verbatim: w9, w30,
 *                         w40/w40_i (cross-coupled pair), w73, w74, w78_i, w80, w92, w95_i, w100,
 *                         w145, w147_prev, w302, w304_r, w320, w329_r, w331_r, w327, w392, w420,
 *                         w425, w441, w445, w450, w464, w473, w476, w496, w498, w499, w503, w510,
 *                         w511, w514/w515/w520/w521 (register-file buses), w522, w524, w526, w527,
 *                         regs[12][2], regs2[2][2], w146/w484/w513 (internal data buses)
 * Storage: 128 dlatch bits + 52 x 2 rs-trigger bits + 667 inline bits (27 x 1 + 9 x 8 + 2 x 4 +
 * 7 x 16 + regs 384 + regs2 64) = 899 register bits, the same set as the die model, one for one.
 * No master-slave (ym_sdff-style) pair exists in this module.
 *
 * Conversion rule per primitive kind (the semantics are those of the helper modules in z80.v as
 * sampled on MCLK, not idealised latch semantics; each rule is the helper's own always block written
 * inline):
 *
 *  z80_dlatch        z80.v: `always @(posedge MCLK) if (en) outp <= inp;`   (outp initial 0)
 *      ->  always @(posedge MCLK) if (en) <inst>_outp <= inp;   assign <outp wire> = <inst>_outp;
 *          Already the enable form; kept as is, initial value 1'h0 kept. The enables are the Z80
 *          clock carried as data (clk) or logic nets (w324, w360, w432, clk & w446), exactly as
 *          instantiated; nothing is merged into a single-register form ("if (clk_rise_en) q <= d")
 *          because no ym_sdff-style master-slave pair exists here: every dlatch is one register
 *          that the die reads while it is open (l16 -> w47 = ~clk & ~l16 etc.), so the closed-latch
 *          value and the open-latch value are both consumed and both are this register.
 *
 *  z80_rs_trig_nor   z80.v (blocking, gate order = priority):
 *                        always @(posedge MCLK) begin q = ~(rst | nq); nq = ~(set | q); end
 *      ->  reg <inst>_q = 1'h0, <inst>_nq = 1'h1;
 *          wire <inst>_qn = ~((rst) | <inst>_nq);                 // q as the first statement makes it
 *          always @(posedge MCLK) begin
 *              <inst>_q  <= <inst>_qn;
 *              <inst>_nq <= ~((set) | <inst>_qn);                 // nq from that *new* q, as the second
 *          end
 *  z80_rs_trig_nand  z80.v: always @(posedge MCLK) begin q = ~(nq & nset); nq = ~(q & nrst); end
 *      ->  wire <inst>_qn = ~(<inst>_nq & (nset));
 *          always @(posedge MCLK) begin <inst>_q <= <inst>_qn; <inst>_nq <= ~(<inst>_qn & (nrst)); end
 *      Exact by construction for the two registers themselves: the next-state equations are the
 *      helper's two statements with the data dependency of the second on the first made explicit
 *      (<inst>_qn). The priorities this encodes, reproduced as-is (they are the die model's, not
 *      the textbook RS latch's):
 *        nor : rst=1 -> q 0 at once, nq = ~set; set=1 (from the reset state q=0,nq=1) -> nq 0 at
 *              once, q 1 one MCLK later (one MCLK with q = nq = 0); rst=1 & set=1 -> q = nq = 0 and,
 *              when both drop, q rises (set wins after release).
 *        nand: nset=0 -> q 1 and nq 0 at once; nrst=0 (from q=1,nq=0) -> nq 1 at once, q 0 one MCLK
 *              later (one MCLK with q = nq = 1); both low -> q = nq = 1 and, when both rise, nq
 *              stays 1 and q drops (reset wins after release).
 *      The helper modules use blocking assignments, so in the die model the readers of q/nq that
 *      run in the same MCLK time step could in principle see either the old or the new value (a
 *      simulation race). Verified on ModelSim ASE 17.0 with the bench's compile options: every
 *      reader (rs triggers, dlatches, inline registers, declared before or after the producer)
 *      sees the previous-cycle value, i.e. plain register semantics, which is also what Quartus
 *      synthesises for the die model; the nonblocking form above is therefore exact for the
 *      readers as well. The equivalence bench (sim/z80) compares every q and nq of both models
 *      twice per MCLK.
 *
 *  inline `always @(posedge MCLK)` blocks (41)   `if (cx) reg <= expr;` chains, cross-coupled pairs
 *      (w40/w40_i), plain registers (w302, w304_r, w329_r, w331_r, w392, w147_prev), the register
 *      file and the three internal data buses
 *      ->  copied verbatim; they are already the enable form on the master clock. The three
 *          registers declared without an initialiser in z80.v (w92, w95_i, w100) are kept without
 *          one (same power-up representation for Quartus; in simulation both models start X there
 *          until the internal reset w55 writes them).
 *
 * Initial values: dlatch outp = 0, rs q = 0 / nq = 1 (from the helper modules), the inline
 * registers' own initialisers and the `initial` block of regs/regs2 -> all kept.
 */

module z80cpu_rtl
	(
	input MCLK,
	input CLK,
	output [15:0] ADDRESS,
	output ADDRESS_z,
	input [7:0] DATA_i,
	output [7:0] DATA_o,
	output DATA_z,
	output M1,
	output MREQ,
	output MREQ_z,
	output IORQ,
	output IORQ_z,
	output RD,
	output RD_z,
	output WR,
	output WR_z,
	output RFSH,
	output HALT,
	input WAIT,
	input INT,
	input NMI,
	input RESET,
	input BUSRQ,
	output BUSAK
	);
	
	wire clk = CLK;
	
	wire w1;
	wire w2;
	wire w3;
	wire w4, w4_i;
	wire w5;
	wire w6, w6_i;
	wire w7;
	wire w8, w8_i;
	wire w9_n, w9_i;
	reg w9 = 1'h0;
	wire w10;
	wire w11;
	wire w12;
	wire w13;
	wire w14;
	wire w15;
	wire w16;
	wire w18, w18_i;
	wire w19, w19_i;
	wire w21, w21_i;
	wire w22, w22_i;
	wire w23;
	wire w24;
	wire w25;
	wire w26;
	wire w27;
	wire w28;
	reg w30 = 1'h0;
	wire w31, w31_i;
	wire w32;
	wire w33, w33_i;
	wire w34, w34_i;
	wire w35;
	wire w36;
	wire w37, w37_i; //
	wire w38;
	wire w39, w39_i;
	reg w40 = 1'h0, w40_i = 1'h1;
	wire w41;
	wire w42;
	wire w43;
	wire w44, w44_n, w44_i;
	wire w45;
	wire w46;
	wire w47;
	wire w48, w48_i;
	wire w49;
	wire w50, w50_i;
	wire w51, w51_i;
	wire w52;
	wire w53;
	wire w54;
	wire w55;
	wire w56;
	wire w57;
	wire w58, w58_i;
	wire w59;
	wire w60;
	wire w61, w61_i;
	wire w62;
	wire w63, w63_t;
	wire w65;
	wire w66, w66_i;
	wire w67;
	wire o_busak;
	wire w68, w68_i;
	wire w69;
	wire w71;
	reg w73 = 1'h0;
	reg w74 = 1'h0;
	wire w75;
	wire w76;
	wire w77;
	reg w78_i = 1'h0;
	wire w78;
	wire w79;
	reg w80 = 1'h0;
	wire w81;
	wire w82;
	wire w83;
	wire w84;
	wire w85;
	wire w86;
	wire w87;
	wire w88;
	wire w89;
	wire w90;
	wire w91;
	reg w92;
	wire w93;
	wire w94;
	reg w95_i;
	wire w95;
	wire w96;
	wire w97;
	wire w98;
	wire w99;
	reg w100;
	wire w101;
	wire w102;
	wire w103;
	wire w104;
	wire w105;
	wire w106;
	wire w107;
	wire w109_i;
	wire w109;
	wire w110;
	wire w111;
	wire w112;
	wire w113;
	wire w114, w114_i;
	wire w115, w115_i;
	wire w116;
	wire w117;
	wire w118;
	wire w119;
	wire w120, w120_i;
	wire w121, w121_i;
	wire w122;
	wire w123, w123_i;
	wire w124;
	wire w125;
	wire w126;
	wire w127, w127_i;
	wire w128;
	wire w129;
	wire rfsh_rs, rfsh;
	wire w130;
	wire w131, w131_i;
	wire w132;
	wire w133;
	wire w134;
	wire w135;
	wire w136;
	wire w137;
	wire w138;
	wire w139;
	wire w140;
	wire w141;
	wire w142;
	wire w143;
	wire w144;
	reg [7:0] w145 = 8'h0;
	reg [7:0] w146 = 8'h0; // bus 1
	reg [7:0] w147_prev = 8'h0;
	wire [7:0] w147;
	wire w148;
	wire w149;
	wire w150;
	wire w151;
	wire w152;
	wire w153;
	wire w154;
	wire w155;
	wire w156;
	wire w157;
	wire w158;
	wire w159;
	wire w160;
	wire w161;
	wire w162;
	wire w163;
	wire w164;
	wire w165;
	wire w166;
	wire w167;
	wire w168;
	wire w169;
	wire w170;
	wire w171;
	wire w172;
	wire w173;
	wire w174;
	wire w175;
	wire w176;
	wire w177;
	wire w178;
	wire w179;
	wire w180;
	wire w181;
	wire w182;
	wire w183;
	wire w184;
	wire w185;
	wire w186;
	wire w187;
	wire w188;
	wire w189;
	wire w190;
	wire w191;
	wire w192;
	wire w193;
	wire w194;
	wire w195;
	wire w196;
	wire w197;
	wire w198;
	wire w199;
	wire w200;
	wire w201;
	wire w202;
	wire w203;
	wire w204;
	wire w205;
	wire w206;
	wire w207;
	wire w208;
	wire w209;
	wire w210, w210_i;
	wire w211;
	wire w212;
	wire w213;
	wire w214;
	wire w215;
	wire w216;
	wire w217;
	wire w218;
	wire w219;
	wire w220;
	wire w221;
	wire w222;
	wire w223;
	wire w224;
	wire w225;
	wire w226;
	wire w227;
	wire w228;
	wire w229;
	wire w230;
	wire w231;
	wire w232;
	wire w233;
	wire w234;
	wire w235;
	wire w236;
	wire w237;
	wire w238;
	wire w239;
	wire w240;
	wire w241;
	wire w242;
	wire w243;
	wire w244;
	wire w245;
	wire w246;
	wire w247;
	wire w248;
	wire w249;
	wire w250;
	wire w251;
	wire w252;
	wire w253;
	wire w254;
	wire w255;
	wire w256;
	wire w257;
	wire w258;
	wire w259;
	wire w260;
	wire w261;
	wire w262;
	wire w263;
	wire w264;
	wire w265;
	wire w266;
	wire w267;
	wire w268;
	wire w269;
	wire w270;
	wire w271;
	wire w272;
	wire w273;
	wire w274;
	wire w275;
	wire w276;
	wire w277;
	wire w278;
	wire w279;
	wire w280;
	wire w281;
	wire w282;
	wire w283;
	wire w284;
	wire w285;
	wire w286;
	wire w287;
	wire w288;
	wire w289;
	wire w290;
	wire w291;
	wire w292;
	wire w293;
	wire w294;
	wire w295;
	wire w296;
	wire w297;
	wire w298;
	wire w299;
	wire w300;
	wire w301;
	reg w302 = 1'h0;
	wire w303;
	wire w304;
	reg w304_r = 1'h0;
	wire w305;
	wire w306;
	wire w307;
	wire w308;
	wire w309;
	wire w310;
	wire w311;
	wire w312;
	wire w313;
	wire w314;
	wire w315;
	wire w316;
	wire w317;
	wire w318;
	wire w319;
	reg w320 = 1'h0;
	wire w321;
	wire w322;
	wire w323;
	wire w324;
	wire w325;
	wire w326;
	wire w327_n, w327_i;
	reg w327 = 1'h0;
	wire w328;
	wire w329;
	reg w329_r = 1'h0;
	wire w330_n, w330_i;
	wire w331;
	reg w331_r = 1'h0;
	wire w332_n, w332_i;
	wire w333;
	wire w334;
	wire w335;
	wire w336;
	wire w337;
	wire w338;
	wire w339;
	wire w340;
	wire w341;
	wire w342;
	wire w343;
	wire w344;
	wire w345;
	wire w346;
	wire w347;
	wire w348;
	wire w349;
	wire w350;
	wire w351;
	wire w352;
	wire w353;
	wire w354;
	wire w355;
	wire w356;
	wire w357;
	wire w358;
	wire w359;
	wire w360;
	wire w361_n, w361_i;
	wire w362;
	wire w363;
	wire w364;
	wire w365;
	wire w366;
	wire w367;
	wire w368;
	wire w369;
	wire w370;
	wire w371;
	wire w372;
	wire w373;
	wire w374;
	wire w375;
	wire w376;
	wire w377;
	wire w378_1, w378_2, w378;
	wire w379_1, w379_2, w379;
	wire w380, w380_i;
	wire w381;
	wire w382;
	wire w383;
	wire w384;
	wire w385;
	wire w386;
	wire w387;
	wire w388;
	wire w389;
	wire w390;
	wire w391;
	reg w392 = 1'h0;
	wire w393;
	wire w394;
	wire w395;
	wire w396;
	wire w397;
	wire w398;
	wire w399;
	wire w400, w400_v;
	wire w401;
	wire w402;
	wire w403;
	wire w404;
	wire w405;
	wire w406;
	wire w407;
	wire w408;
	wire w409;
	wire w410;
	wire w411;
	wire w412;
	wire w413;
	wire w414;
	wire w415;
	wire w416;
	wire w417;
	wire w418;
	wire w419;
	reg w420 = 1'h0;
	wire w421;
	wire w422;
	wire w423;
	wire w424;
	reg w425 = 1'h0;
	wire w426;
	wire w427;
	wire w428;
	wire w429;
	wire w430;
	wire w431;
	wire w432;
	wire w433;
	wire w434;
	wire w435;
	wire w436;
	wire w437;
	wire w438;
	wire w439;
	wire w440;
	reg w441 = 1'h0;
	wire w442, w442_i;
	wire w443;
	wire w444;
	reg w445 = 1'h0;
	wire w446;
	wire w448;
	wire w449;
	reg w450 = 1'h0;
	wire w452;
	wire w453;
	wire w454;
	wire w455;
	wire w456;
	wire w457;
	wire w458;
	wire w459;
	wire w460;
	wire w461;
	wire w462;
	wire w463;
	reg w464 = 1'h0;
	wire w465;
	wire w466;
	wire w467;
	wire w468;
	wire w469;
	wire w470;
	wire w471;
	wire w472;
	reg w473 = 1'h0;
	wire w474;
	wire w475;
	reg w476 = 1'h0;
	wire w477;
	wire w479;
	wire w480;
	wire w481;
	wire w483;
	reg [7:0] w484 = 8'h0; // bus 2
	wire w485;
	wire w486;
	wire w487;
	wire w490;
	wire w491;
	wire w492;
	wire w493;
	wire w494;
	wire w495;
	reg [7:0] w496 = 8'h0;
	wire [7:0] w497;
	reg [7:0] w498 = 8'h0;
	reg [3:0] w499 = 4'h0;
	wire [3:0] w500;
	wire w501;
	wire w502;
	reg [3:0] w503 = 4'h0;
	wire [3:0] w504;
	wire w505;
	wire w506;
	wire w507;
	wire w508;
	reg [7:0] w510 = 8'h0;
	reg [7:0] w511 = 8'h0;
	wire [3:0] w512;
	reg [7:0] w513 = 8'h0; // bus 3
	
	wire [15:0] rpull1[1:0];
	wire [15:0] rpull2[1:0];
	wire [15:0] rpull1_comb[1:0];
	wire [15:0] rpull2_comb[1:0];
	wire [15:0] rpullup1[1:0];
	wire [15:0] rpullup2[1:0];
	wire [15:0] rpullup1_comb[1:0];
	wire [15:0] rpullup2_comb[1:0];
	reg [15:0] regs[11:0][1:0];
	reg [15:0] regs2[1:0][1:0];
	
	reg [15:0] w514 = 16'h0;
	reg [15:0] w515 = 16'h0;
	
	wire w516;
	wire w517;
	wire w518;
	wire w519;
	
	reg [15:0] w520 = 16'h0;
	reg [15:0] w521 = 16'h0;
	reg [15:0] w522 = 16'h0;
	wire [15:0] w523;
	reg w524 = 1'h0;
	wire [14:0] w525;
	reg [15:0] w526 = 16'h0;
	reg [15:0] w527 = 16'h0;
	wire [15:0] w528;

	wire w530;
	wire w531;
	wire w532;
	
	wire halt, halt_i;
	
	wire m1;
	
	wire l1;
	wire l2;
	wire l3;
	wire l4;
	wire l5;
	wire l6;
	wire l7;
	wire l8;
	wire l9;
	wire l10;
	wire l11;
	wire l12;
	wire l13;
	wire l14;
	wire l15;
	wire l16;
	wire l17;
	wire l18;
	wire l19;
	wire l20;
	wire l21;
	wire l22;
	wire l23;
	wire l24;
	wire l25;
	wire l26;
	wire l27;
	wire l28;
	wire l29;
	wire l30;
	wire l31;
	wire l32;
	wire l33;
	wire l34;
	wire l35;
	wire l36;
	wire l37;
	wire l38;
	wire l39;
	wire l40;
	wire l41;
	wire l42;
	wire l43;
	wire l44;
	wire l45;
	wire l46, l46_i;
	wire l47, l47_i;
	wire l48, l48_i;
	wire l49, l49_i;
	wire l50;
	wire l51;
	wire l52;
	wire l53;
	wire l54;
	wire l55;
	wire l56;
	wire l57;
	wire l58;
	wire l59;
	wire l60;
	wire l61;
	wire l62;
	wire l63;
	wire l64;
	wire l65;
	wire l66;
	wire l67;
	wire l68;
	wire l70;
	wire l71;
	wire l72;
	wire l73;
	wire l75;
	wire l76;
	wire l77;
	wire l79;
	wire l81;
	wire l82;
	wire l83;
	wire l84;
	
	// pla
	
	wire [98:0] pla;
	
	
	//
	
	wire w1_i;
	
	assign w1 = ~w1_i;
	
	// z80_rs_trig_nor rs1(.MCLK(MCLK), .rst(clk & w3 & w41), .set(w55 | (clk & (w114 | w201))), .q(w1_i), .nq());
	reg rs1_q = 1'h0, rs1_nq = 1'h1;
	wire rs1_qn = ~((clk & w3 & w41) | rs1_nq);
	always @(posedge MCLK)
	begin
		rs1_q <= rs1_qn;
		rs1_nq <= ~((w55 | (clk & (w114 | w201))) | rs1_qn);
	end
	assign w1_i = rs1_q;
		
	// z80_dlatch dl1(.MCLK(MCLK), .en(clk), .inp(w69), .outp(l1));
	reg dl1_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl1_outp <= w69;
	end
	assign l1 = dl1_outp;
	
	// z80_rs_trig_nor rs2(.MCLK(MCLK), .rst((clk & w131 & w41) | (~clk & ~l1)), .set(clk & w15), .q(w2), .nq());
	reg rs2_q = 1'h0, rs2_nq = 1'h1;
	wire rs2_qn = ~(((clk & w131 & w41) | (~clk & ~l1)) | rs2_nq);
	always @(posedge MCLK)
	begin
		rs2_q <= rs2_qn;
		rs2_nq <= ~((clk & w15) | rs2_qn);
	end
	assign w2 = rs2_q;
	
	
	assign w3 = ~(w201 | w202);
	
	
	// z80_rs_trig_nand rs4(.MCLK(MCLK), .nset(clk | ~INT), .nrst(clk | INT), .q(w4), .nq(w4_i));
	reg rs4_q = 1'h0, rs4_nq = 1'h1;
	wire rs4_qn = ~(rs4_nq & (clk | ~INT));
	always @(posedge MCLK)
	begin
		rs4_q <= rs4_qn;
		rs4_nq <= ~(rs4_qn & (clk | INT));
	end
	assign w4 = rs4_q;
	assign w4_i = rs4_nq;
	
	
	// z80_rs_trig_nor rs5(.MCLK(MCLK), .rst(clk & w4_i), .set(clk & w4), .q(w5), .nq());
	reg rs5_q = 1'h0, rs5_nq = 1'h1;
	wire rs5_qn = ~((clk & w4_i) | rs5_nq);
	always @(posedge MCLK)
	begin
		rs5_q <= rs5_qn;
		rs5_nq <= ~((clk & w4) | rs5_qn);
	end
	assign w5 = rs5_q;
		
	// z80_dlatch dl2(.MCLK(MCLK), .en(clk), .inp(~(w55 | w19)), .outp(l2));
	reg dl2_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl2_outp <= ~(w55 | w19);
	end
	assign l2 = dl2_outp;
	
	wire nmi = ~NMI;
	
	// z80_rs_trig_nor rs7(.MCLK(MCLK), .rst(~l2), .set(~nmi), .q(w7), .nq());
	reg rs7_q = 1'h0, rs7_nq = 1'h1;
	wire rs7_qn = ~((~l2) | rs7_nq);
	always @(posedge MCLK)
	begin
		rs7_q <= rs7_qn;
		rs7_nq <= ~((~nmi) | rs7_qn);
	end
	assign w7 = rs7_q;
	
	// z80_rs_trig_nor rs6(.MCLK(MCLK), .rst(~l2 | (nmi & ~w7)), .set(nmi & w7), .q(w6), .nq(w6_i));
	reg rs6_q = 1'h0, rs6_nq = 1'h1;
	wire rs6_qn = ~((~l2 | (nmi & ~w7)) | rs6_nq);
	always @(posedge MCLK)
	begin
		rs6_q <= rs6_qn;
		rs6_nq <= ~((nmi & w7) | rs6_qn);
	end
	assign w6 = rs6_q;
	assign w6_i = rs6_nq;
	
	
	// z80_rs_trig_nand rs8(.MCLK(MCLK), .nset(clk | w6_i), .nrst(clk | w6), .q(w8), .nq(w8_i));
	reg rs8_q = 1'h0, rs8_nq = 1'h1;
	wire rs8_qn = ~(rs8_nq & (clk | w6_i));
	always @(posedge MCLK)
	begin
		rs8_q <= rs8_qn;
		rs8_nq <= ~(rs8_qn & (clk | w6));
	end
	assign w8 = rs8_q;
	assign w8_i = rs8_nq;
	
	// z80_rs_trig_nor rs9(.MCLK(MCLK), .rst(clk & w8_i), .set(clk & w8), .q(w9_n), .nq(w9_i));
	reg rs9_q = 1'h0, rs9_nq = 1'h1;
	wire rs9_qn = ~((clk & w8_i) | rs9_nq);
	always @(posedge MCLK)
	begin
		rs9_q <= rs9_qn;
		rs9_nq <= ~((clk & w8) | rs9_qn);
	end
	assign w9_n = rs9_q;
	assign w9_i = rs9_nq;
	
	always @(posedge MCLK)
	begin
		if (w9_i)
			w9 <= 1'h0;
		else if (w9_n)
			w9 <= 1'h1;
	end
	
	assign w10 = ~(w12 | w9 | w11);
	
	assign w11 = ~(w12 | w9 | ~pla[3]);
		
	// z80_dlatch dl3(.MCLK(MCLK), .en(clk), .inp(~w73 | pla[1]), .outp(l3));
	reg dl3_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl3_outp <= ~w73 | pla[1];
	end
	assign l3 = dl3_outp;
	
	assign w12 = ~(w5 | w9 | l3);
	
	assign w13 = ~((w16 & ~w10) | w18 | w19 | halt);
	
	assign w14 = ~(w13 | (w16 & w10));
	
	assign w15 = ~(~w114 | w202 | w201);
		
	// z80_dlatch dl4(.MCLK(MCLK), .en(clk), .inp(~(w55 | ~w97 | ~w118 | w133)), .outp(l4));
	reg dl4_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl4_outp <= ~(w55 | ~w97 | ~w118 | w133);
	end
	assign l4 = dl4_outp;
	
	assign w16 = l4 & ~clk;
	
	// z80_rs_trig_nor rs18(.MCLK(MCLK), .rst(w16 & w12), .set((w16 & ~w12) | w55), .q(w18_i), .nq());
	reg rs18_q = 1'h0, rs18_nq = 1'h1;
	wire rs18_qn = ~((w16 & w12) | rs18_nq);
	always @(posedge MCLK)
	begin
		rs18_q <= rs18_qn;
		rs18_nq <= ~(((w16 & ~w12) | w55) | rs18_qn);
	end
	assign w18_i = rs18_q;
	
	assign w18 = ~w18_i;
	
	// z80_rs_trig_nor rs19(.MCLK(MCLK), .rst(w16 & w9), .set((w16 & ~w9) | w55), .q(w19_i), .nq());
	reg rs19_q = 1'h0, rs19_nq = 1'h1;
	wire rs19_qn = ~((w16 & w9) | rs19_nq);
	always @(posedge MCLK)
	begin
		rs19_q <= rs19_qn;
		rs19_nq <= ~(((w16 & ~w9) | w55) | rs19_qn);
	end
	assign w19_i = rs19_q;
	
	assign w19 = ~w19_i;
	
	// z80_rs_trig_nor rs21(.MCLK(MCLK), .rst(w32 | w26), .set(w24), .q(w21), .nq(w21_i));
	reg rs21_q = 1'h0, rs21_nq = 1'h1;
	wire rs21_qn = ~((w32 | w26) | rs21_nq);
	always @(posedge MCLK)
	begin
		rs21_q <= rs21_qn;
		rs21_nq <= ~((w24) | rs21_qn);
	end
	assign w21 = rs21_q;
	assign w21_i = rs21_nq;
	
	//assign MREQ = ~w21_i ? 1'h0 : ((~w21 & ~w62) ? 1'h1 : 1'hz);
	assign MREQ = w21_i;
	assign MREQ_z = w21_i & w62;
	
	// z80_rs_trig_nor rs22(.MCLK(MCLK), .rst(w26 | w32), .set(w23 | (w36 & clk)), .q(w22), .nq(w22_i));
	reg rs22_q = 1'h0, rs22_nq = 1'h1;
	wire rs22_qn = ~((w26 | w32) | rs22_nq);
	always @(posedge MCLK)
	begin
		rs22_q <= rs22_qn;
		rs22_nq <= ~((w23 | (w36 & clk)) | rs22_qn);
	end
	assign w22 = rs22_q;
	assign w22_i = rs22_nq;
	
	//assign IORQ = ~w22_i ? 1'h0 : ((~w22 & ~w62) ? 1'h1 : 1'hz);
	assign IORQ = w22_i;
	assign IORQ_z = w22_i & w62;
		
	// z80_dlatch dl5(.MCLK(MCLK), .en(clk), .inp(w35), .outp(l5));
	reg dl5_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl5_outp <= w35;
	end
	assign l5 = dl5_outp;
	
	assign w23 = ~clk & ~l5;
		
	// z80_dlatch dl6(.MCLK(MCLK), .en(clk), .inp(w27), .outp(l6));
	reg dl6_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl6_outp <= w27;
	end
	assign l6 = dl6_outp;
	
	assign w24 = ~clk & ~w202 & ~l6;
	
	assign w25 = ~(w24 | w23 | (w36 & clk));
	
	assign w26 = w131 & w41 & clk;
	
	assign w27 = !((w110 & w93) | (w131 & (w41 | (w110 & ~w18))));
		
	// z80_dlatch dl7(.MCLK(MCLK), .en(clk), .inp(w57), .outp(l7));
	reg dl7_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl7_outp <= w57;
	end
	assign l7 = dl7_outp;
	
	assign w28 = ~(halt | (w18 & w80) | w55 | w19 | ~(w18 | l7));
	
	always @(posedge MCLK)
	begin
		if (w55)
			w30 <= 1'h1;
		else if (clk)
			w30 <= w30;
		else if (w103)
			w30 <= ~w28;
	end
		
	// z80_dlatch dl8(.MCLK(MCLK), .en(clk), .inp(w101), .outp(l8));
	reg dl8_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl8_outp <= w101;
	end
	assign l8 = dl8_outp;
	
	// z80_rs_trig_nor rs31(.MCLK(MCLK), .rst(w26 | w32), .set(~w25 & l8), .q(w31), .nq(w31_i));
	reg rs31_q = 1'h0, rs31_nq = 1'h1;
	wire rs31_qn = ~((w26 | w32) | rs31_nq);
	always @(posedge MCLK)
	begin
		rs31_q <= rs31_qn;
		rs31_nq <= ~((~w25 & l8) | rs31_qn);
	end
	assign w31 = rs31_q;
	assign w31_i = rs31_nq;
	
	//assign RD = ~w31_i ? 1'h0 : ((~w31 & ~w62) ? 1'h1 : 1'hz);
	assign RD = w31_i;
	assign RD_z = w31_i & w62;
	
		
	// z80_dlatch dl9(.MCLK(MCLK), .en(clk), .inp(w94), .outp(l9));
	reg dl9_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl9_outp <= w94;
	end
	assign l9 = dl9_outp;
	
	
	assign w32 = ~clk & l9;
	
	// z80_rs_trig_nor rs33(.MCLK(MCLK), .rst(~clk & ~l10), .set(~l11 | (clk & w106 & w114 & w201)), .q(w33), .nq(w33_i));
	reg rs33_q = 1'h0, rs33_nq = 1'h1;
	wire rs33_qn = ~((~clk & ~l10) | rs33_nq);
	always @(posedge MCLK)
	begin
		rs33_q <= rs33_qn;
		rs33_nq <= ~((~l11 | (clk & w106 & w114 & w201)) | rs33_qn);
	end
	assign w33 = rs33_q;
	assign w33_i = rs33_nq;
	
	//assign WR = ~w33_i ? 1'h0 : ((~w33 & ~w62) ? 1'h1 : 1'hz);
	assign WR = w33_i;
	assign WR_z = w33_i & w62;
		
	// z80_dlatch dl10(.MCLK(MCLK), .en(clk), .inp(~w41 & ~w55), .outp(l10));
	reg dl10_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl10_outp <= ~w41 & ~w55;
	end
	assign l10 = dl10_outp;
		
	// z80_dlatch dl11(.MCLK(MCLK), .en(clk), .inp(~(w114 & w201)), .outp(l11));
	reg dl11_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl11_outp <= ~(w114 & w201);
	end
	assign l11 = dl11_outp;
	
	wire w34_v = ~(l12 & w112);
	
	// z80_rs_trig_nand rs34(.MCLK(MCLK), .nset(clk | ~w34_v), .nrst(clk | w34_v), .q(w34), .nq(w34_i));
	reg rs34_q = 1'h0, rs34_nq = 1'h1;
	wire rs34_qn = ~(rs34_nq & (clk | ~w34_v));
	always @(posedge MCLK)
	begin
		rs34_q <= rs34_qn;
		rs34_nq <= ~(rs34_qn & (clk | w34_v));
	end
	assign w34 = rs34_q;
	assign w34_i = rs34_nq;
		
	// z80_dlatch dl12(.MCLK(MCLK), .en(clk), .inp(~w41 & ~(~w114 & ~w34_i)), .outp(l12));
	reg dl12_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl12_outp <= ~w41 & ~(~w114 & ~w34_i);
	end
	assign l12 = dl12_outp;
	
	assign w35 = ~(~w37 & w131 & w18);
	
	assign w36 = w114 & w106;
		
	// z80_dlatch dl82(.MCLK(MCLK), .en(clk), .inp(w114), .outp(l82));
	reg dl82_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl82_outp <= w114;
	end
	assign l82 = dl82_outp;
	
	assign w531 = ~(w131 & w18 & l82);
	
	// z80_rs_trig_nand rs37(.MCLK(MCLK), .nset(clk | ~w531), .nrst(clk | w531), .q(w37), .nq(w37_i));
	reg rs37_q = 1'h0, rs37_nq = 1'h1;
	wire rs37_qn = ~(rs37_nq & (clk | ~w531));
	always @(posedge MCLK)
	begin
		rs37_q <= rs37_qn;
		rs37_nq <= ~(rs37_qn & (clk | w531));
	end
	assign w37 = rs37_q;
	assign w37_i = rs37_nq;
	
	// z80_dlatch dl_w38(.MCLK(MCLK), .en(clk), .inp(~(((w18 & w131) | w106) & (~w37 | w114))), .outp(w38));
	reg dl_w38_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl_w38_outp <= ~(((w18 & w131) | w106) & (~w37 | w114));
	end
	assign w38 = dl_w38_outp;
	
	// z80_rs_trig_nor rs39(.MCLK(MCLK), .rst(clk & ~(w38 & WAIT)), .set(clk & (w38 & WAIT)), .q(w39), .nq(w39_i));
	reg rs39_q = 1'h0, rs39_nq = 1'h1;
	wire rs39_qn = ~((clk & ~(w38 & WAIT)) | rs39_nq);
	always @(posedge MCLK)
	begin
		rs39_q <= rs39_qn;
		rs39_nq <= ~((clk & (w38 & WAIT)) | rs39_qn);
	end
	assign w39 = rs39_q;
	assign w39_i = rs39_nq;
	
	always @(posedge MCLK)
	begin
		w40 <= ~(w202 | (w40_i & (clk | w39)));
		w40_i <= ~(w40 & (clk | w39_i));
	end
	
	assign w41 = ~w40 & ~w34;
	
	assign w42 = ~clk & ~w43;
	
	assign w43 = ~(~pla[35] & l13);
	
	// z80_dlatch dl13(.MCLK(MCLK), .en(clk), .inp(w110 & w201), .outp(l13));
	reg dl13_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl13_outp <= w110 & w201;
	end
	assign l13 = dl13_outp;
	
	// z80_rs_trig_nor rs44(.MCLK(MCLK), .rst(w45), .set(l14 | (clk & w110)), .q(w44_n), .nq(w44_i));
	reg rs44_q = 1'h0, rs44_nq = 1'h1;
	wire rs44_qn = ~((w45) | rs44_nq);
	always @(posedge MCLK)
	begin
		rs44_q <= rs44_qn;
		rs44_nq <= ~((l14 | (clk & w110)) | rs44_qn);
	end
	assign w44_n = rs44_q;
	assign w44_i = rs44_nq;
	
	// z80_dlatch dl14(.MCLK(MCLK), .en(clk), .inp(w113), .outp(l14));
	reg dl14_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl14_outp <= w113;
	end
	assign l14 = dl14_outp;
		
	assign w44 = ~w44_i;
	
	// z80_dlatch dl15(.MCLK(MCLK), .en(clk), .inp(~(w201 & w110)), .outp(l15));
	reg dl15_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl15_outp <= ~(w201 & w110);
	end
	assign l15 = dl15_outp;
	
	assign w45 = ~clk & ~l15;
	
	assign w46 = ~(w131 | (w127 & pla[35]) | (w127 & w107));
	
	assign w47 = ~clk & ~l16;
	
	// z80_dlatch dl16(.MCLK(MCLK), .en(clk), .inp(~(w107 & w127 & w41)), .outp(l16));
	reg dl16_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl16_outp <= ~(w107 & w127 & w41);
	end
	assign l16 = dl16_outp;
	
	// z80_dlatch dl17(.MCLK(MCLK), .en(clk), .inp(~(w114 & w131)), .outp(l17));
	reg dl17_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl17_outp <= ~(w114 & w131);
	end
	assign l17 = dl17_outp;
	
	// z80_dlatch dl18(.MCLK(MCLK), .en(clk), .inp(~(w41 | w55)), .outp(l18));
	reg dl18_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl18_outp <= ~(w41 | w55);
	end
	assign l18 = dl18_outp;
	
	// z80_rs_trig_nand rs48(.MCLK(MCLK), .nset(clk | l17), .nrst(clk | l18), .q(w48), .nq(w48_i));
	reg rs48_q = 1'h0, rs48_nq = 1'h1;
	wire rs48_qn = ~(rs48_nq & (clk | l17));
	always @(posedge MCLK)
	begin
		rs48_q <= rs48_qn;
		rs48_nq <= ~(rs48_qn & (clk | l18));
	end
	assign w48 = rs48_q;
	assign w48_i = rs48_nq;
	
	assign w49 = ~(w48 | w47);
	
	// z80_rs_trig_nand rs50(.MCLK(MCLK), .nset(clk | RESET), .nrst(clk | ~RESET), .q(w50), .nq(w50_i));
	reg rs50_q = 1'h0, rs50_nq = 1'h1;
	wire rs50_qn = ~(rs50_nq & (clk | RESET));
	always @(posedge MCLK)
	begin
		rs50_q <= rs50_qn;
		rs50_nq <= ~(rs50_qn & (clk | ~RESET));
	end
	assign w50 = rs50_q;
	assign w50_i = rs50_nq;
	
	// z80_rs_trig_nor rs51(.MCLK(MCLK), .rst(clk & w50_i), .set(clk & w50), .q(w51), .nq(w51_i));
	reg rs51_q = 1'h0, rs51_nq = 1'h1;
	wire rs51_qn = ~((clk & w50_i) | rs51_nq);
	always @(posedge MCLK)
	begin
		rs51_q <= rs51_qn;
		rs51_nq <= ~((clk & w50) | rs51_qn);
	end
	assign w51 = rs51_q;
	assign w51_i = rs51_nq;
		
	assign w52 = ~clk & l19;
	
	// z80_dlatch dl19(.MCLK(MCLK), .en(clk), .inp(~(w131 & w114)), .outp(l19));
	reg dl19_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl19_outp <= ~(w131 & w114);
	end
	assign l19 = dl19_outp;
		
	assign w53 = ~clk & ~l20 & ~w55;
	
	// z80_dlatch dl20(.MCLK(MCLK), .en(clk), .inp(~(w131 & w114)), .outp(l20));
	reg dl20_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl20_outp <= ~(w131 & w114);
	end
	assign l20 = dl20_outp;
	
	// z80_rs_trig_nor rs54(.MCLK(MCLK), .rst(w52 & w51), .set(w52 & w51_i), .q(w54), .nq());
	reg rs54_q = 1'h0, rs54_nq = 1'h1;
	wire rs54_qn = ~((w52 & w51) | rs54_nq);
	always @(posedge MCLK)
	begin
		rs54_q <= rs54_qn;
		rs54_nq <= ~((w52 & w51_i) | rs54_qn);
	end
	assign w54 = rs54_q;
	
	assign w55 = ~w54;
	
	// z80_rs_trig_nor rs56(.MCLK(MCLK), .rst(w53 & w51), .set((w53 & w104 & ~w51) | w55), .q(w56), .nq());
	reg rs56_q = 1'h0, rs56_nq = 1'h1;
	wire rs56_qn = ~((w53 & w51) | rs56_nq);
	always @(posedge MCLK)
	begin
		rs56_q <= rs56_qn;
		rs56_nq <= ~(((w53 & w104 & ~w51) | w55) | rs56_qn);
	end
	assign w56 = rs56_q;
	
	assign w57 = w56 | ~w104;
	
	// z80_rs_trig_nand rs58(.MCLK(MCLK), .nset(clk | BUSRQ), .nrst(clk | ~BUSRQ), .q(w58), .nq(w58_i));
	reg rs58_q = 1'h0, rs58_nq = 1'h1;
	wire rs58_qn = ~(rs58_nq & (clk | BUSRQ));
	always @(posedge MCLK)
	begin
		rs58_q <= rs58_qn;
		rs58_nq <= ~(rs58_qn & (clk | ~BUSRQ));
	end
	assign w58 = rs58_q;
	assign w58_i = rs58_nq;
	
	// z80_rs_trig_nor rs59(.MCLK(MCLK), .rst(clk & w58_i), .set(clk & w58), .q(w59), .nq());
	reg rs59_q = 1'h0, rs59_nq = 1'h1;
	wire rs59_qn = ~((clk & w58_i) | rs59_nq);
	always @(posedge MCLK)
	begin
		rs59_q <= rs59_qn;
		rs59_nq <= ~((clk & w58) | rs59_qn);
	end
	assign w59 = rs59_q;
	
	// z80_dlatch dl21(.MCLK(MCLK), .en(clk), .inp(w68), .outp(l21));
	reg dl21_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl21_outp <= w68;
	end
	assign l21 = dl21_outp;
	
	assign w60 = l21 & w112;
	
	// z80_rs_trig_nand rs61(.MCLK(MCLK), .nset(clk | ~w60), .nrst(clk | w60), .q(), .nq(w61_i));
	reg rs61_q = 1'h0, rs61_nq = 1'h1;
	wire rs61_qn = ~(rs61_nq & (clk | ~w60));
	always @(posedge MCLK)
	begin
		rs61_q <= rs61_qn;
		rs61_nq <= ~(rs61_qn & (clk | w60));
	end
	assign w61_i = rs61_nq;
	
	assign w61 = ~w61_i;
	
	assign w62 = l22 | o_busak;
	
	// z80_dlatch dl22(.MCLK(MCLK), .en(clk), .inp(o_busak), .outp(l22));
	reg dl22_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl22_outp <= o_busak;
	end
	assign l22 = dl22_outp;
	
	assign o_busak = ~w65 & ~w66_i & ~w67;
	
	assign BUSAK = ~o_busak;
	
	// z80_dlatch dl23(.MCLK(MCLK), .en(clk), .inp(w55), .outp(l23));
	reg dl23_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl23_outp <= w55;
	end
	assign l23 = dl23_outp;
	
	// z80_rs_trig_nand rs63(.MCLK(MCLK), .nset(clk | ~l23), .nrst(clk | l23), .q(), .nq(w63_t));
	reg rs63_q = 1'h0, rs63_nq = 1'h1;
	wire rs63_qn = ~(rs63_nq & (clk | ~l23));
	always @(posedge MCLK)
	begin
		rs63_q <= rs63_qn;
		rs63_nq <= ~(rs63_qn & (clk | l23));
	end
	assign w63_t = rs63_nq;
	
	assign w63 = ~(w63_t | ~(clk | ~l23));
	
	// z80_dlatch dl24(.MCLK(MCLK), .en(clk), .inp(~w63 & ~w133), .outp(l24));
	reg dl24_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl24_outp <= ~w63 & ~w133;
	end
	assign l24 = dl24_outp;
	
	assign w65 = ~(~l24 | clk | ~w59);
	
	// z80_rs_trig_nor rs66(.MCLK(MCLK), .rst(w63 | w67), .set(w65), .q(w66), .nq(w66_i));
	reg rs66_q = 1'h0, rs66_nq = 1'h1;
	wire rs66_qn = ~((w63 | w67) | rs66_nq);
	always @(posedge MCLK)
	begin
		rs66_q <= rs66_qn;
		rs66_nq <= ~((w65) | rs66_qn);
	end
	assign w66 = rs66_q;
	assign w66_i = rs66_nq;
	
	assign w67 = ~clk & ~w59;
	
	// z80_dlatch dl25(.MCLK(MCLK), .en(clk), .inp(w109), .outp(l25));
	reg dl25_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl25_outp <= w109;
	end
	assign l25 = dl25_outp;
	
	assign w68 = ~w68_i;
	
	wire w68_v = ~(l25 & w112);
	
	// z80_rs_trig_nand rs68(.MCLK(MCLK), .nset(clk | w68_v), .nrst(clk | ~w68_v), .q(), .nq(w68_i));
	reg rs68_q = 1'h0, rs68_nq = 1'h1;
	wire rs68_qn = ~(rs68_nq & (clk | w68_v));
	always @(posedge MCLK)
	begin
		rs68_q <= rs68_qn;
		rs68_nq <= ~(rs68_qn & (clk | ~w68_v));
	end
	assign w68_i = rs68_nq;
	
	assign w69 = ~(w55 | (w41 & ~w131));
	
	// z80_dlatch dl26(.MCLK(MCLK), .en(clk), .inp(~(w131 & pla[1] & w110)), .outp(l26));
	reg dl26_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl26_outp <= ~(w131 & pla[1] & w110);
	end
	assign l26 = dl26_outp;
	
	assign w71 = ~clk & ~l26;
	
	always @(posedge MCLK)
	begin
		if (w19 | w18 | w55)
			w73 <= 0;
		else if (clk)
			w73 <= w73;
		else if (w71)
			w73 <= w147[3];
		else if (w75)
			w73 <= w74;
	end
	
	always @(posedge MCLK)
	begin
		if (w18 | w55)
			w74 <= 0;
		else if (clk)
			w74 <= w74;
		else if (w71)
			w74 <= w147[3];
	end
	
	// z80_dlatch dl27(.MCLK(MCLK), .en(clk), .inp(w76), .outp(l27));
	reg dl27_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl27_outp <= w76;
	end
	assign l27 = dl27_outp;
	
	assign w75 = ~clk & ~l27 & ~w19;
	
	assign w76 = ~(pla[52] & w131 & w114);
	
	assign w77 = w89 & w19;
	
	always @(posedge MCLK)
	begin
		if (w55)
			w78_i <= 0;
		else if (clk)
			w78_i <= w78_i;
		else if (w79)
			w78_i <= w147[3];
	end
	
	assign w78 = ~w78_i;
	
	// z80_dlatch dl28(.MCLK(MCLK), .en(clk), .inp(~(pla[2] & w131 & w110)), .outp(l28));
	reg dl28_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl28_outp <= ~(pla[2] & w131 & w110);
	end
	assign l28 = dl28_outp;
	
	
	assign w79 = ~clk & ~l28;
	
	always @(posedge MCLK)
	begin
		if (w55)
			w80 <= 0;
		else if (clk)
			w80 <= w80;
		else if (w79)
			w80 <= w147[4];
	end
	
	assign w81 = w80 & (w89 & w78 & w18);
	
	assign w82 = ~(pla[33] | pla[34]);
	
	assign w83 = ~(w77 | ~w86);
	
	assign w84 = ~(~w80 | w85);
	
	assign w85 = ~(w78 & w18);
	
	assign w86 = (w89 & (w84 | w19)) | (~w89 & pla[42]);
	
	assign w87 = ~(w78 | ~w80);
	
	assign w88 = ~(w87 & w89 & w18);
	
	assign w89 = ~(w103 | ~w30);
	
	assign w90 = ~(~w91 | w30);
	
	assign w91 = ~(w92 | ~w95);
	
	// z80_dlatch dl43(.MCLK(MCLK), .en(clk), .inp(~pla[47]), .outp(l43));
	reg dl43_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl43_outp <= ~pla[47];
	end
	assign l43 = dl43_outp;
	
	always @(posedge MCLK)
	begin
		if (w55)
			w92 <= 0;
		else if (clk)
			w92 <= w92;
		else if (w103)
			w92 <= ~l43;
	end
	
	assign w93 = ~(w131 | w106);
	
	assign w94 = (w41 & ~w131) | w55 | w109;
	
	always @(posedge MCLK)
	begin
		if (w55)
			w95_i <= 0;
		else if (clk)
			w95_i <= w95_i;
		else if (w103)
			w95_i <= w98;
	end
	
	assign w95 = ~w95_i;
	
	assign w96 = w95 | w103;
	
	assign w97 = ~(pla[47] | pla[54] | pla[57]);
	
	// z80_dlatch dw98(.MCLK(MCLK), .en(clk), .inp(pla[54]), .outp(w98));
	reg dw98_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw98_outp <= pla[54];
	end
	assign w98 = dw98_outp;
	
	// z80_dlatch dw99(.MCLK(MCLK), .en(clk), .inp(~pla[57]), .outp(w99));
	reg dw99_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw99_outp <= ~pla[57];
	end
	assign w99 = dw99_outp;
		
	always @(posedge MCLK)
	begin
		if (w55)
			w100 <= 1'h1;
		else if (clk)
			w100 <= w100;
		else if (!w98 & w103)
			w100 <= w99;
	end
	
	assign w101 = ~(w202 | w201 | (w131 & (w41 | w18)));
	
	assign w102 = ~((w131 & w114) | (w110 & w127 & w107));
	
	// z80_dlatch dl29(.MCLK(MCLK), .en(clk), .inp(w102), .outp(l29));
	reg dl29_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl29_outp <= w102;
	end
	assign l29 = dl29_outp;
	
	assign w103 = ~l29 & ~clk;
	
	// z80_dlatch dw104(.MCLK(MCLK), .en(clk), .inp(w97), .outp(w104));
	reg dw104_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw104_outp <= w97;
	end
	assign w104 = dw104_outp;
	
	assign w105 = pla[61] | pla[71];
	
	assign w106 = (pla[77] & w120) | (w127 & pla[78]) | (w105 & w123);
	
	// z80_dlatch dw107(.MCLK(MCLK), .en(clk), .inp(pla[76]), .outp(w107));
	reg dw107_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw107_outp <= pla[76];
	end
	assign w107 = dw107_outp;
	
	assign w109 = ~w109_i;
	
	// z80_dlatch dl30(.MCLK(MCLK), .en(clk), .inp(w41), .outp(l30));
	reg dl30_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl30_outp <= w41;
	end
	assign l30 = dl30_outp;
	
	assign w530 = ~(w112 & l30);
	
	// z80_rs_trig_nand rs109(.MCLK(MCLK), .nset(clk | w530), .nrst(clk | ~w530), .q(), .nq(w109_i));
	reg rs109_q = 1'h0, rs109_nq = 1'h1;
	wire rs109_qn = ~(rs109_nq & (clk | w530));
	always @(posedge MCLK)
	begin
		rs109_q <= rs109_qn;
		rs109_nq <= ~(rs109_qn & (clk | ~w530));
	end
	assign w109_i = rs109_nq;
	
	assign w110 = ~(w113 | w111);
	
	// z80_rs_trig_nand rs111(.MCLK(MCLK), .nset(clk | ~w112), .nrst(clk | w112), .q(w111), .nq());
	reg rs111_q = 1'h0, rs111_nq = 1'h1;
	wire rs111_qn = ~(rs111_nq & (clk | ~w112));
	always @(posedge MCLK)
	begin
		rs111_q <= rs111_qn;
		rs111_nq <= ~(rs111_qn & (clk | w112));
	end
	assign w111 = rs111_q;
	
	// z80_dlatch dw112(.MCLK(MCLK), .en(clk), .inp(~w113 & w133), .outp(w112));
	reg dw112_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw112_outp <= ~w113 & w133;
	end
	assign w112 = dw112_outp;
	
	assign w113 = w66 | w63 | w65;
	
	// z80_dlatch dl31(.MCLK(MCLK), .en(clk), .inp(w110), .outp(l31));
	reg dl31_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl31_outp <= w110;
	end
	assign l31 = dl31_outp;
	
	assign w532 = ~(w112 & l31);
	
	// z80_rs_trig_nand rs114(.MCLK(MCLK), .nset(clk | w532), .nrst(clk | ~w532), .q(), .nq(w114_i));
	reg rs114_q = 1'h0, rs114_nq = 1'h1;
	wire rs114_qn = ~(rs114_nq & (clk | w532));
	always @(posedge MCLK)
	begin
		rs114_q <= rs114_qn;
		rs114_nq <= ~(rs114_qn & (clk | ~w532));
	end
	assign w114_i = rs114_nq;
	
	assign w114 = ~w114_i;
	
	// z80_rs_trig_nor rs115(.MCLK(MCLK), .rst(clk & (w131 | w123)), .set(clk & w116), .q(), .nq(w115_i));
	reg rs115_q = 1'h0, rs115_nq = 1'h1;
	wire rs115_qn = ~((clk & (w131 | w123)) | rs115_nq);
	always @(posedge MCLK)
	begin
		rs115_q <= rs115_qn;
		rs115_nq <= ~((clk & w116) | rs115_qn);
	end
	assign w115_i = rs115_nq;
	
	assign w115 = ~w115_i;
	
	assign w116 = w114 & w120 & w126;
	
	assign w117 = w55 | w121 | (w123 & ~w164) | (w120 & w138 & ~w159)
		| (w127 & (pla[98] | (w155 & (~(~w164 | ~w151) | ~w151))));
	
	assign w118 = w117 | w299 | (w131 & w139);
	
	// z80_dlatch dl32(.MCLK(MCLK), .en(clk), .inp(w131), .outp(l32));
	reg dl32_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl32_outp <= w131;
	end
	assign l32 = dl32_outp;
	
	assign w119 = l32 & ~w134 & ~w130;
	
	// z80_rs_trig_nor rs120(.MCLK(MCLK), .rst(w132 & ~w119), .set(w132 & w119), .q(), .nq(w120_i));
	reg rs120_q = 1'h0, rs120_nq = 1'h1;
	wire rs120_qn = ~((w132 & ~w119) | rs120_nq);
	always @(posedge MCLK)
	begin
		rs120_q <= rs120_qn;
		rs120_nq <= ~((w132 & w119) | rs120_qn);
	end
	assign w120_i = rs120_nq;
	
	assign w120 = ~w120_i;
	
	// z80_rs_trig_nor rs121(.MCLK(MCLK), .rst(w132 & ~w122), .set(w132 & w122), .q(), .nq(w121_i));
	reg rs121_q = 1'h0, rs121_nq = 1'h1;
	wire rs121_qn = ~((w132 & ~w122) | rs121_nq);
	always @(posedge MCLK)
	begin
		rs121_q <= rs121_qn;
		rs121_nq <= ~((w132 & w122) | rs121_qn);
	end
	assign w121_i = rs121_nq;
	
	assign w121 = ~w121_i;
	
	// z80_dlatch dl33(.MCLK(MCLK), .en(clk), .inp(w123), .outp(l33));
	reg dl33_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl33_outp <= w123;
	end
	assign l33 = dl33_outp;
	
	assign w122 = l33 & ~w130;
	
	// z80_rs_trig_nor rs123(.MCLK(MCLK), .rst(w132 & ~w124), .set(w132 & w124), .q(), .nq(w123_i));
	reg rs123_q = 1'h0, rs123_nq = 1'h1;
	wire rs123_qn = ~((w132 & ~w124) | rs123_nq);
	always @(posedge MCLK)
	begin
		rs123_q <= rs123_qn;
		rs123_nq <= ~((w132 & w124) | rs123_qn);
	end
	assign w123_i = rs123_nq;
	
	assign w123 = ~w123_i;
	
	// z80_dlatch dl34(.MCLK(MCLK), .en(clk), .inp(w127), .outp(l34));
	reg dl34_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl34_outp <= w127;
	end
	assign l34 = dl34_outp;
	
	assign w124 = ~w130 & (l34 | w134);
	
	assign w125 = ~((~w169 & ~w100) | (w169 & w161));
	
	assign w126 = (~w169 & ~w100) | w255;
	
	// z80_rs_trig_nor rs127(.MCLK(MCLK), .rst(w132 & ~w128), .set(w132 & w128), .q(), .nq(w127_i));
	reg rs127_q = 1'h0, rs127_nq = 1'h1;
	wire rs127_qn = ~((w132 & ~w128) | rs127_nq);
	always @(posedge MCLK)
	begin
		rs127_q <= rs127_qn;
		rs127_nq <= ~((w132 & w128) | rs127_qn);
	end
	assign w127_i = rs127_nq;
	
	assign w127 = ~w127_i;
	
	// z80_dlatch dl35(.MCLK(MCLK), .en(clk), .inp(w120), .outp(l35));
	reg dl35_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl35_outp <= w120;
	end
	assign l35 = dl35_outp;
	
	assign w128 = ~(w134 | w130 | ~l35);
	
	assign w129 = ~(w131 & (w109 | w41));
	
	// z80_rs_trig_nor rsrfsh(.MCLK(MCLK), .rst(clk & ~w129), .set(clk & w129), .q(rfsh_rs), .nq());
	reg rsrfsh_q = 1'h0, rsrfsh_nq = 1'h1;
	wire rsrfsh_qn = ~((clk & ~w129) | rsrfsh_nq);
	always @(posedge MCLK)
	begin
		rsrfsh_q <= rsrfsh_qn;
		rsrfsh_nq <= ~((clk & w129) | rsrfsh_qn);
	end
	assign rfsh_rs = rsrfsh_q;
	
	assign rfsh = ~rfsh_rs;
	
	assign RFSH = ~rfsh;
	
	// z80_dlatch dw130(.MCLK(MCLK), .en(clk), .inp(w118), .outp(w130));
	reg dw130_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw130_outp <= w118;
	end
	assign w130 = dw130_outp;
	
	// z80_rs_trig_nor rs131(.MCLK(MCLK), .rst(w132 & ~w130), .set(w132 & w130), .q(), .nq(w131_i));
	reg rs131_q = 1'h0, rs131_nq = 1'h1;
	wire rs131_qn = ~((w132 & ~w130) | rs131_nq);
	always @(posedge MCLK)
	begin
		rs131_q <= rs131_qn;
		rs131_nq <= ~((w132 & w130) | rs131_qn);
	end
	assign w131_i = rs131_nq;
	
	assign w131 = ~w131_i;
	
	// z80_dlatch dl36(.MCLK(MCLK), .en(clk), .inp(~w133), .outp(l36));
	reg dl36_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl36_outp <= ~w133;
	end
	assign l36 = dl36_outp;
	
	assign w132 = ~clk & l36;
	
	assign w133 = ~w137 & ~w55;
	
	// z80_dlatch dw134(.MCLK(MCLK), .en(clk), .inp(w125 & ((w159 & w131) | w120)), .outp(w134));
	reg dw134_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw134_outp <= w125 & ((w159 & w131) | w120);
	end
	assign w134 = dw134_outp;
	
	assign w135 = ~((w190 & w68) | (w131 & w109 & w149));
	
	assign w136 = ~(w61 | (w41 & w143) | (w109 & w141));
	
	assign w137 = ~w135 | ~w136;
	
	assign w138 = w161 & ~w126;
	
	assign w139 = w159 & w161 & w169 & w157;
	
	assign w140 = ~w155 & w151 & ~w255;
	
	assign w141 = w186 & ((w140 & w127) | w123);
	
	assign w142 = w186 & ~w255 & ~w234;
	
	assign w143 = w120 | (w142 & w123) | (w121 & ~pla[88])
		| (w127 & (~w151 | (w140 & w299)));
	
	// z80_dlatch dl37(.MCLK(MCLK), .en(clk), .inp(w133), .outp(l37));
	reg dl37_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl37_outp <= w133;
	end
	assign l37 = dl37_outp;
	
	// z80_dlatch dl38(.MCLK(MCLK), .en(clk), .inp(~w110 & ~w55), .outp(l38));
	reg dl38_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl38_outp <= ~w110 & ~w55;
	end
	assign l38 = dl38_outp;
	
	// z80_rs_trig_nand rs144(.MCLK(MCLK), .nset(clk | l37), .nrst(clk | l38), .q(w144), .nq());
	reg rs144_q = 1'h0, rs144_nq = 1'h1;
	wire rs144_qn = ~(rs144_nq & (clk | l37));
	always @(posedge MCLK)
	begin
		rs144_q <= rs144_qn;
		rs144_nq <= ~(rs144_qn & (clk | l38));
	end
	assign w144 = rs144_q;
	
	always @(posedge MCLK)
	begin
		if (w2)
			w145 <= ~DATA_i;
		else if (w42)
			w145 <= w146;
		else
			w145 <= w145;
	end
	
	always @(posedge MCLK)
	begin
		w147_prev <= w147;
	end
	
	assign w147 = w49 ? w147_prev : ~w146;
	
	// pla
	assign pla[0] = (w147 & 8'hf7) == 8'hd3 & w90; // out(n), a; in(n), a
	assign pla[1] = (w147 & 8'hf7) == 8'hf3 & w90; // di; ei
	assign pla[2] = (w147 & 8'hc7) == 8'h46 & w92; // im 0; im 1; im 2
	assign pla[3] = w147 == 8'h76 & w90; // halt
	assign pla[4] = (w147 & 8'he7) == 8'ha0 & w92; // ldi; ldd; ldir; lddr
	assign pla[5] = (w147 & 8'he7) == 8'ha1 & w92; // cpi; cpd; cpir; cpdr
	assign pla[6] = w147 == 8'h37 & w90; // scf
	assign pla[7] = (w147 & 8'he6) == 8'ha2 & w92; // ini; outi; ind; outd; inir; otir; indr; otdr
	assign pla[8] = w147 == 8'h10 & w90; // djnz d
	assign pla[9] = w147 == 8'h3f & w90; // ccf
	assign pla[10] = (w147 & 8'h38) == 8'h28 & ~w82; // xor
	assign pla[11] = (w147 & 8'hf7) == 8'h57 & w92; // ld a,i; ld a,r
	assign pla[12] = (w147 & 8'h38) == 8'h30 & ~w82; // or
	assign pla[13] = (w147 & 8'h38) == 8'h20 & ~w82; // and
	assign pla[14] = (w147 & 8'h38) == 8'h00 & ~w82; // add
	assign pla[15] = (w147 & 8'hf7) == 8'h57 & w92 & w74; // ???
	assign pla[16] = (w147 & 8'hc7) == 8'h44 & w92; // neg
	assign pla[17] = w147 == 8'h2f & w90; // cpl
	assign pla[18] = (w147 & 8'h38) == 8'h08 & ~w82; // adc
	assign pla[19] = (w147 & 8'h38) == 8'h18 & ~w82; // sbc
	assign pla[20] = (w147 & 8'h38) == 8'h10 & ~w82; // sub
	assign pla[21] = w147 == 8'h27 & w90; // daa
	assign pla[22] = (w147 & 8'h38) == 8'h38 & ~w82; // cp
	assign pla[23] = (w147 & 8'hc7) == 8'h05 & w90; // dec byte
	assign pla[24] = (w147 & 8'hc0) == 8'hc0 & ~w96; // set
	assign pla[25] = (w147 & 8'hc0) == 8'h80 & ~w96; // res
	assign pla[26] = (w147 & 8'hc0) == 8'h40 & ~w96; // bit
	assign pla[27] = (w147 & 8'he7) == 8'h07 & w90; // rlca; rrca; rla; rra
	assign pla[28] = (w147 & 8'hc0) == 8'h00 & ~w96; // rlc; rrc; rl; rr; sla; sra; sll; srl
	assign pla[29] = (w147 & 8'hcf) == 8'h09 & w90; // add hl, bc; de ; hl ;sp
	assign pla[30] = (w147 & 8'hc7) == 8'h42 & w92; // sbc hl, adc hl
	assign pla[31] = (w147 & 8'hc7) == 8'h40 & w92; // in (c)
	assign pla[32] = (w147 & 8'hc6) == 8'h04 & w90; // inc dec byte
	assign pla[33] = (w147 & 8'hc0) == 8'h80 & w90; // 8'h80-8'hbf alu opcode
	assign pla[34] = (w147 & 8'hc7) == 8'hc6 & w90; // n alu opcodes
	assign pla[35] = (w147 & 8'hc7) == 8'h06 & w90; // ld n opcodes
	assign pla[36] = ~w96;
	assign pla[37] = (w147 & 8'hc0) == 8'h40 & w90; // ld reg opcodes
	assign pla[38] = (w147 & 8'hf7) == 8'h67 & w92; // rrd, rld
	assign pla[39] = (w147 & 8'hf8) == 8'h70 & w90 & ~pla[3]; // ld to (hl) opcodes
	assign pla[40] = (w147 & 8'hc7) == 8'h46 & w90 & ~pla[3]; // ld from (hl) opcodes
	assign pla[41] = (w147 & 8'hf7) == 8'h47 & w92; // ld i,a ; ld r,a
	assign pla[42] = (w147 & 8'hc7) == 8'hc7 & w90; // rst n
	assign pla[43] = (w147 & 8'h07) == 8'h06 & ~w96; // bit opcode (hl)
	assign pla[44] = ~w96 & ~w100; // 
	assign pla[45] = (w147 & 8'hfe) == 8'h34 & w90; // inc dec (hl)
	assign pla[46] = (w147 & 8'hc7) == 8'h86 & w90; // alu (hl)
	assign pla[47] = w147 == 8'hed & w90; // misc opcode prefix
	assign pla[48] = w147 == 8'h36 & w90; // ld (hl), n
	assign pla[49] = w147 == 8'hcb & ~w100; // ix, iy bit instutruction ?
	assign pla[50] = (w147 & 8'he7) == 8'h20 & w90; // jr nz, z, nc, c
	assign pla[51] = w147 == 8'h18 & w90; // jr d
	assign pla[52] = (w147 & 8'hc7) == 8'h45 & w92; // retn, reti
	assign pla[53] = (w147 & 8'hc7) == 8'hc0 & w90; // ret condition
	assign pla[54] = w147 == 8'hcb & w90; // bit opcode prefix
	assign pla[55] = (w147 & 8'hc7) == 8'hc2 & w90; // jp n condition
	assign pla[56] = (w147 & 8'hc7) == 8'hc4 & w90; // call n condition
	assign pla[57] = (w147 & 8'hdf) == 8'hdd & w90; // ix, iy
	assign pla[58] = w147 == 8'h36 & w90 & ~w100; // ld (ix/y), n
	assign pla[59] = w147 == 8'h08 & w90; // ex af, af'
	assign pla[60] = (w147 & 8'hf7) == 8'h32 & w90; // ld (nn), a; ld a, (nn)
	assign pla[61] = (w147 & 8'hf7) == 8'hd3 & w90; // out (n), a; in a, (n)
	assign pla[62] = (w147 & 8'he7) == 8'h02 & w90; // ld (bc), a; ld (de), a; ld a, (bc); ld a(de)
	assign pla[63] = w147 == 8'hc9 & w90; // ret
	assign pla[64] = (w147 & 8'hc7) == 8'h41 & w92; // out (c), reg
	assign pla[65] = (w147 & 8'hcf) == 8'h43 & w92; // ld (nn), word reg
	assign pla[66] = (w147 & 8'he7) == 8'h47 & w92; // ld i, a; ld r, a; ld a, i; ld a, r
	assign pla[67] = (w147 & 8'hc7) == 8'h43 & w92; // ld (nn), word reg, ld word reg, (nn)
	assign pla[68] = (w147 & 8'hf7) == 8'h22 & w90; // ld (nn), hl; ld hl, (nn)
	assign pla[69] = w147 == 8'hc3 & w90; // jp nn
	assign pla[70] = w147 == 8'hd3 & w90; // out (n), a
	assign pla[71] = (w147 & 8'hc6) == 8'h40 & w92; // in/ out (c), byte
	assign pla[72] = w147 == 8'h10 & w90; // djnz d
	assign pla[73] = (w147 & 8'he7) == 8'h07 & w90; // rlca; rrca; rla; rra
	assign pla[74] = w147 == 8'hcd & w90; // call nn
	assign pla[75] = (w147 & 8'hcb) == 8'hc1 & w90; // pop, push
	assign pla[76] = w147 == 8'hcb & ~w100; // ix, iy bit instutruction ?
	assign pla[77] = (w147 & 8'he7) == 8'ha2 & w92; // ini; ind; inir; indr
	assign pla[78] = (w147 & 8'he7) == 8'ha3 & w92; // outi; outd; otir; otdr
	assign pla[79] = (w147 & 8'he7) == 8'ha1 & w92; // cpi; cpd; cpir; cpdr
	assign pla[80] = (w147 & 8'he7) == 8'ha0 & w92; // ldi; ldd; ldir; lddr
	assign pla[81] = (w147 & 8'hc7) == 8'h06 & w90; // ld byte n
	assign pla[82] = (w147 & 8'hcf) == 8'hc5 & w90; // push
	assign pla[83] = (w147 & 8'hf7) == 8'h67 & w92; // rrd, rld
	assign pla[84] = (w147 & 8'hcf) == 8'h0b & w90; // dec word
	assign pla[85] = (w147 & 8'hcf) == 8'h02 & w90; // load from address
	assign pla[86] = (w147 & 8'he7) == 8'ha0 & w92; // ldi; ldd; ldir; lddr
	assign pla[87] = (w147 & 8'he7) == 8'ha1 & w92; // cpi; cpd; cpir; cpdr
	assign pla[88] = w147 == 8'he3 & w90; // ex (sp), hl
	assign pla[89] = (w147 & 8'hc7) == 8'h03 & w90; // inc, dec word
	assign pla[90] = (w147 & 8'he7) == 8'h02 & w90; // ld address from register
	assign pla[91] = (w147 & 8'hcf) == 8'h01 & w90; // ld nn word
	assign pla[92] = w147 == 8'he9 & w90; // jp (hl)
	assign pla[93] = w147 == 8'hf9 & w90; // ld sp, hl
	assign pla[94] = (w147 & 8'he7) == 8'h47 & w92; // ld i,a; ld r,a; ld a,i; ld a,r
	assign pla[95] = (w147 & 8'hdf) == 8'hdd & w90; // ix, iy
	assign pla[96] = w147 == 8'heb & w90; // ex de, hl
	assign pla[97] = w147 == 8'hd9 & w90; // exx
	assign pla[98] = (w147 & 8'hf4) == 8'ha0 & w92; // 
	
	assign w148 = ~(pla[11] | pla[16] | pla[17] |
		pla[21] | pla[27] | pla[33] | pla[34]
		| pla[38]);
	assign w149 = ~(w86 | ~w88 | pla[53] | pla[72]
		| pla[77] | pla[78] | pla[82] | pla[89]
		| pla[93] | pla[94]);
	assign w150 = ~(pla[11] | pla[21] | pla[27]
		| pla[28] | pla[31] | pla[33] | pla[34]
		| pla[35] | pla[37]);
	assign w151 = ~(~w88 | pla[55] | pla[60]
		| pla[67] | pla[68] | pla[69] | pla[77]
		| pla[78] | pla[91]);
	assign w152 = ~(pla[4] | pla[5] | pla[6] | pla[7]
		| pla[9] | pla[26] | pla[28] | pla[29]
		| pla[30] | pla[31] | pla[32] | pla[33]
		| pla[34]);
	assign w153 = ~(w86 | ~w88 | pla[50] | pla[51]
		| pla[52] | pla[53] | pla[55] | pla[56]
		| pla[63] | pla[69] | pla[72] | pla[74]
		| pla[92]);
	assign w154 = ~(pla[11] | pla[16] | pla[17]
		| pla[27] | pla[28] | pla[31] | pla[35]
		| pla[37] | w86);
	assign w155 = ~(~w88 | pla[44] | pla[45]
		| pla[49] | pla[56] | pla[60] | pla[67]
		| pla[68] | pla[74] | pla[77] | pla[78]
		| pla[83] | pla[88]);
	assign w156 = ~(pla[10] | pla[12] | pla[14]
		| pla[16] | pla[18] | pla[19] | pla[20]
		| pla[22] | pla[29] | pla[30]);
	assign w157 = ~(~w88 | pla[50] | pla[51]
		| pla[55] | pla[56] | pla[60] | pla[67]
		| pla[68] | pla[69] | pla[72] | pla[74]
		| pla[77] | pla[78] | pla[79] | pla[80]
		| pla[83] | pla[88] | pla[91]);
	assign w158 = ~(pla[11] | pla[14] | pla[16]
		| pla[18] | pla[19] | pla[20] | pla[22]
		| pla[30] | pla[32]);
	assign w159 = ~(pla[34] | pla[35] | pla[50]
		| pla[51] | pla[61] | pla[72]);
	assign w160 = ~(pla[5] | pla[7] | pla[8]
		| pla[16] | pla[17] | pla[19] | pla[20]
		| pla[22] | pla[23] | pla[25]);
	assign w161 = ~(pla[29] | pla[30] | w86
		| pla[48] | pla[52] | pla[53] | pla[61]
		| pla[62] | pla[63] | pla[71] | pla[75]);
	assign w162 = ~(pla[5] | pla[7] | pla[8]
		| pla[11] | pla[16] | pla[21] | pla[26]
		| pla[28] | pla[30] | pla[31] | pla[32]
		| pla[33] | pla[34] | pla[38]);
	assign w163 = ~(pla[32] | pla[33] | pla[34]
		| pla[36] | pla[37]);
	assign w164 = ~(pla[26] | pla[39] | pla[40]
		| pla[46] | pla[48] | pla[60] | pla[61]
		| pla[62] | pla[71] | pla[77] | pla[78]
		| pla[79] | pla[80] | pla[83]);
	assign w165 = ~(pla[7] | pla[8] | pla[13]
		| pla[17] | pla[26] | pla[32]);
	assign w166 = ~(pla[9] | pla[18] | pla[19]
		| pla[30]);
	assign w167 = ~(w86 | pla[39] | pla[48]
		| pla[56] | pla[64] | pla[65] | pla[70]
		| pla[74] | pla[82] | pla[83] | pla[85]
		| pla[88] | pla[89] | pla[93]);
	assign w168 = ~(pla[10] | pla[12] | pla[24]);
	assign w169 = ~(pla[39] | pla[40] | pla[43]
		| pla[44] | pla[45] | pla[46] | pla[48]
		| pla[49]);
	assign w170 = ~(pla[49] | pla[55] | pla[56] | pla[44]
		| pla[58] | pla[60] | pla[67] | pla[68]
		| pla[69] | pla[74] | pla[91]);
	assign w171 = ~(pla[6] | pla[9] | pla[13]);
	assign w172 = ~(pla[24] | pla[25] | pla[28]
		| pla[31] | pla[32] | pla[35] | pla[37]);
	assign w173 = ~(w86 | pla[52] |  pla[53] | pla[56]
		| pla[63] | pla[74] | pla[75] | pla[88]);
	assign w174 = ~(pla[7] | pla[8] | pla[32]
		| pla[36] | pla[50] | pla[51]);
	assign w175 = ~(pla[50] | pla[51] | pla[72]);
	assign w176 = ~(pla[82] | pla[84]);
	assign w177 = ~(pla[4] | pla[5] | pla[6]
		| pla[7] | pla[9]);
	assign w178 = ~(pla[7] | pla[8]);
	assign w179 = ~(pla[5] | pla[7] | pla[8]);
	assign w180 = ~(pla[12] | pla[24]);
	assign w181 = ~(pla[13] | pla[25] | pla[26]);
	assign w182 = ~(pla[33] | pla[36]);
	assign w183 = ~(w182 & (w114 | ~pla[37]));
	assign w184 = ~(pla[55] | pla[56]);
	assign w185 = ~(pla[56] | pla[74]);
	assign w186 = ~(pla[77] | pla[78] | pla[79]
		| pla[80]);
	assign w187 = ~(pla[60] | pla[61] | pla[62]);
	assign w188 = ~(pla[71] | pla[72] | pla[77]
		| pla[78]);
	assign w189 = ~(pla[72] | pla[73] | pla[77]
		| pla[78]);
	assign w190 = ~(pla[89] | pla[93]);
	assign w191 = ~(pla[79] | pla[80]
		| ~w169 | pla[83] | pla[92] | pla[93]);
	
	assign w192 = (w201 & w110) | (w41 & w3 & w46);
	
	assign w193 = (w144 & w14) | w205;
	
	assign w194 = ~w202 & ~w203;
	
	assign w195 = ~(pla[88] | ~(w196 | (~w299 & ~w173)));
	
	assign w196 = pla[86] | pla[87];
	
	assign w197 = ~w234 & w186;
	
	assign w198 = ~w199 & w170;
	
	assign w199 = ~(pla[83] | pla[87] | w254);
	
	assign w200 = ~((w127 & (~w186 | ~w88))
		| (w120 & ~w88)
		| (w123 & ~w167)
		| (w121 & (~w167 | w255)));
	
	assign w201 = ~w200 & ~w202;
	
	assign w202 = ((w121 | w123) & ~w197)
		| (w127 & w198);
	
	assign w203 = ~(w110 | (w41 & w131));
	
	assign w204 = ~((w109 & pla[93])
		| (pla[88] & w121 & w41));
	
	// z80_dlatch dl39(.MCLK(MCLK), .en(clk), .inp(w204), .outp(l39));
	reg dl39_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl39_outp <= w204;
	end
	assign l39 = dl39_outp;
	
	// z80_rs_trig_nand rs205(.MCLK(MCLK), .nset(clk | l39), .nrst(clk | ~l39), .q(w205), .nq());
	reg rs205_q = 1'h0, rs205_nq = 1'h1;
	wire rs205_qn = ~(rs205_nq & (clk | l39));
	always @(posedge MCLK)
	begin
		rs205_q <= rs205_qn;
		rs205_nq <= ~(rs205_qn & (clk | ~l39));
	end
	assign w205 = rs205_q;
	
	assign w206 = ~((w131 & w109 & w207)
		| (~w186 & w123 & (w41 | w110))
		| (w195 & w127 & w41));
	
	assign w207 = ~(w176 & ~(w86 | ~w88));
	
	assign w208 = ~(w110 &
		((w120 & (w209 | ~w88))
			| (w123 & ~w173 & ~w167)
			| (w127 & w209)));
	
	assign w209 = ~w186 & w147[3];
	
	// z80_dlatch dl40(.MCLK(MCLK), .en(clk), .inp(~w206 | ~w208), .outp(l40));
	reg dl40_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl40_outp <= ~w206 | ~w208;
	end
	assign l40 = dl40_outp;
	
	// z80_rs_trig_nand rs210(.MCLK(MCLK), .nset(clk | ~l40), .nrst(clk | l40), .q(), .nq(w210_i));
	reg rs210_q = 1'h0, rs210_nq = 1'h1;
	wire rs210_qn = ~(rs210_nq & (clk | ~l40));
	always @(posedge MCLK)
	begin
		rs210_q <= rs210_qn;
		rs210_nq <= ~(rs210_qn & (clk | l40));
	end
	assign w210_i = rs210_nq;
	
	assign w210 = ~w210_i;
	
	assign w211 = ~((w114 & ((w123 & w212)
		| (w120 & w213)))
		| (w109 & (w121 | ((w123 | w127)
			& (~w186 | ~w173)))));
	
	assign w212 = ~(w186 & (~w169 | w255));
	
	assign w213 = ~(w186 & w218);
	
	assign w214 = ~((w41 & w131)
		| (w68 & w131 & (~w88 | ~w167))
		| (w114 & ((w127 & ~w186)
			| (w121 & w167 & ~w173))));
	
	// z80_dlatch dl41(.MCLK(MCLK), .en(clk), .inp(w55 | (~w57 & w110 & w131)), .outp(l41));
	reg dl41_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl41_outp <= w55 | (~w57 & w110 & w131);
	end
	assign l41 = dl41_outp;
	
	assign w215 = l41;
	
	assign w216 = ~w214 | ~w211;
	
	assign w217 = ~((w120 & w218) | w131 | w127);
	
	assign w218 = ~pla[88] & w88;
	
	assign w219 = ~((w41 & (w121 | (w127 & ~w186)))
		| (w109 & w131)
		| (w114 & (w131 | (w127 & ~w173))));
	
	assign w220 = ~(w127 & w196);
	
	assign w221 = ~((w110 & (w123 | w121)
		& (~w185 | w86))
		| (w109 & w123 & ~w186));
	
	assign w222 = ~((~w175 & ((w114 & w120)
		| (w41 & w127)))
		| (w110 & (w127 | w120) & ~w88));
	
	assign w223 = ~((w127 & ~w186)
		| (w120 & ~w170)
		| (w131 & w224));
	
	assign w224 = ~w170 | w225 | ~w159;
	
	assign w225 = ~w100 & ~w169;
	
	assign w226 = ~((w110 & (
		w131
		| (w120 & w224)
		| (w127 & ~w170)))
		| w55);
	
	assign w227 = ~(w131 & w114);
	
	assign w228 = ~(w131 & w41);
	
	assign w229 = ~((w41 & w120 & ~w88)
		| (w109 & w131 & pla[94]));
	
	assign w230 = ~((w68 & w131 & (pla[93] | ~w173))
		| (w114 & (((w127 | w123) & ~w173)
			| (w121 & ~w173 & w167))));
	
	assign w231 = ~(((w68 | w109) & (w131 | w127)
		& (~w173 | ~w88))
		| (w114 & w120 & ~w88));

	assign w232 = ~((w41 & (w120 | w127) & pla[91])
		| ((w109 | w68)
			& (w121 | (w131
				& (pla[89] | pla[90]))))
		);
	
	assign w233 = ~(
		(w110 & (w123 | w121)
			& (pla[88] | w234 | w235))
		| (w41 & (w123 | w121)
			& w237)
		);
	
	assign w234 = pla[29] | pla[30];
	
	assign w235 = ~(w236 | w147[3]);
	
	assign w236 = ~(pla[67] | pla[68]);
	
	assign w237 = ~(w236 | ~w167);
	
	assign w238 = ~(
		((w41 & w127) | (w114 & w120))
		& w225);
	
	assign w239 = ~((w114 & w120 & w240)
		| (w109 & ((w127 & pla[83]) | (w123 & w234)))
		| (w41 & (w123 | w121) & w234)
		);
	
	assign w240 = ~(pla[77] | w186);
	
	assign w241 = ~(
		(w131 & w68 & pla[78])
		| (w131 & w109 & (w234 | ~w191))
		| (w114 & w127 & pla[77])
		| (w41 & w120 & (pla[77] | pla[81]))
		);
	
	assign w242 = ~(
		((w41 & w120)
		| (w114 & w127)) & pla[80]
		);
	
	assign w243 = ~(
		(w109 & ((w127 & ~w186) | (w131 & ~w188)))
		| (w68 & w131 & pla[77])
		| (w110 & w120 & ~w188)
		| (w41 & ((w127 & ~w186) | (w120 & pla[78])))
		);
	
	assign w244 = ~(
		(w110 | w41) & (w123 | w121) & pla[75]
		);
	
	assign w245 = ~(~w187 | (~w236 & w147[3])
		| (~w153 & w175) | pla[75] | ~w173
		| pla[91]);
	
	assign w246 = ~((w110 & w123 & ~w187)
		| (w41 & w123 & w167 & ~w187)
		| (w109 & w131 & pla[73])
		| (w114 & w131 & w247)
		);
	
	assign w247 = ~(pla[22] | w148);
	
	assign w248 = ~(
		(w110 & w123 & (pla[71] | ~w163))
		| (w109 & w131 & (~w163 & w169))
		);
	
	assign w249 = ~(w109 & w131 & pla[66]);
	
	assign w250 = ~(w114 & w131 & ~w172);

	assign w251 = ~(
		(w41 & ((w123 & w252)
			| (w120 & w88 & w253)))
		| (w114 & w127 & (~w88 | w254))
		);
	
	assign w252 = w187 & (w86 | w234 | (w167 & ~w245));
	
	assign w253 = ~w245 | w235;
	
	assign w254 = ~(~w255 | ~w186);
	
	assign w255 = ~w174 | (w115 & w256);
	
	assign w256 = ~w169 & ~w100;
	
	assign w257 = ~(
		(w110 & w120 & (~w189 | ~w187))
		| (w41 & ((w127 & w253) | (w121 & w252)))
		);
	
	assign w258 = ~(
		(w41 & w123 & ~w187)
		| (w68 & w127 & w255)
		| (w114 & w131 & w247)
		);
	
	assign w259 = ~(w110 & w131 & pla[59]);
	
	assign w260 = ~(
		(w110 & w121 & ~w245)
		| (w109 & w131 & w261)
		);
	
	assign w261 = w235 | w234;
	
	assign w262 = ~(
		(w110 & ((w120 & ~w88) | (w123 & w261)))
		| (w114 & w120)
		);
	
	assign w263 = ~(
		(w109 & ((w131 & ~w189) | w123))
		| ((w110 | w41) & w120 & ~w88)
		);
	
	assign w264 = ~(
		(w110 & ((w123 & (~w245 | ~w187))
			| (w121 & w261)))
		| (w41 & w127 & w255)
		);
	
	assign w265 = (
		(w127 & ~w184)
		| (w131 & pla[53])
		| (w120 & pla[50])
		);
	
	assign w266 = ~(
		(w109 & w131 & pla[41])
		| (w110 & w127 & w88)
		);
	
	assign w267 = ~(
		(w110 & w123 & pla[38])
		| (w41 & ((w123 & w86)
			| (w127 & (pla[38] | ~w88))))
		);
	
	assign w268 = ~(~w150 &
		((w41 & w123)
			| (w109 & w131))
		);
	
	assign w269 = ~(
		(w110 & ((w123 & (w256 | w234)) | (w121 & w234)))
		| (w68 & w131 & w86)
		| (w41 & (w131 | w120))
		);
	
	assign w270 = ~(
		(w41 & w123 & (w256 | w271))
		| (w109 & w131)
		);
	
	assign w271 = pla[27] | pla[28];
	
	assign w272 = ~((w41 & w120 & w255));
	
	assign w273 = ~(w110 & w131 & (w247 | ~w152));
	
	assign w274 = ~(
		(w114 & w123 & (w256 | w271))
		| (w41 & w131)
		);
	
	assign w275 = ~(
		(w114 & w131 & (~w172 | w247))
		| (w110 & (w120 | w121) & w255)
		| (w41 & w121 & w234)
		| (w68 & w127)
		);
	
	assign w276 = ~(w41 & w120 & w255);

	assign w277 = ~(w114 & w131 & ~w156);
	
	assign w278 = ~(w114 & w131 & ~w171);
	
	assign w279 = ~(
		(w120 & pla[8])
		| (w127 & (pla[7] | pla[5]))
		);
	
	assign w280 = ~(
		(w114 & ((w127 & pla[5]) | (w131 & w179)))
		| (w110 & w120 & ~w178)
		| (w41 & w123 & w234)
		);
	
	assign w281 = ~(
		(w110 & w123) | (w114 & w120)
		| (w109 & w131)
		);
	
	assign w282 = ~(
		(w110 & ((w127 & (pla[5] | w255)) | (w131 & w177)))
		| (w68 & w131)
		| (w114 & w121 & w234)
		);
	
	assign w283 = ~(
		~w274 |
		(w68 & w131 & ~w88)
		| (w41 & (w127 | w123) & w255)
		| (w109 & ((w131 & (w255 | w234))
			| (w123 & w234)))
		| (w114 & w120 & (w255 | w256))
		);
	
	assign w284 = ~(w68 & w131 & w81);
	
	assign w285 = ~(
		(w110 & w120 & pla[0])
		| (w114 & w127 & ~w88)
		| (w41 & w121 & w86)
		);
	
	assign w286 = ~(
		(w41 & w131 & w287)
		| (w110 & w123 & (w287 & w256))
		);
	
	assign w287 = ~w95 | (w103 & w98);
	
	assign w288 = ~((w109 | w68) & (pla[21] | w77));
	
	assign w289 = ~((w288 & w68 & w131) | w192);
	
	assign w290 = ~(w216 | ~w219 | ~w226
		| (~w133 & (~w217 | w118)));
	
	assign w291 = ~(~w226 | w216);
	
	// z80_dlatch dw292(.MCLK(MCLK), .en(clk), .inp(w291), .outp(w292));
	reg dw292_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw292_outp <= w291;
	end
	assign w292 = dw292_outp;
	
	// z80_dlatch dw293(.MCLK(MCLK), .en(clk), .inp(w290), .outp(w293));
	reg dw293_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw293_outp <= w290;
	end
	assign w293 = dw293_outp;
	
	assign w294 = ~(w221 & w222);
	
	assign w295 = ~(w133 |
		(w223 & (~w118 | w296)));
	
	assign w296 = ~(w299 | w153);
	
	assign w297 = ~(~w226 | w295 | w294);
	
	// z80_dlatch dw298(.MCLK(MCLK), .en(clk), .inp(w297), .outp(w298));
	reg dw298_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw298_outp <= w297;
	end
	assign w298 = dw298_outp;
	
	assign w299 = (~w220 & w438) | w383 | (w265 & w448);
	
	assign w300 = ~(~w226 | w295);
	
	// z80_dlatch dw301(.MCLK(MCLK), .en(clk), .inp(~w300), .outp(w301));
	reg dw301_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw301_outp <= ~w300;
	end
	assign w301 = dw301_outp;
	
	//assign w302 = ~(w303 & pla[97]);
	
	always @(posedge MCLK)
	begin
		w302 <= ~(w303 & pla[97]);
	end
	
	// z80_dlatch dl42(.MCLK(MCLK), .en(clk), .inp(w227), .outp(l42));
	reg dl42_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl42_outp <= w227;
	end
	assign l42 = dl42_outp;
	
	assign w303 = ~l42;
	
	always @(posedge MCLK)
	begin
		w304_r <= w303 & pla[95];
	end
	
	assign w304 = ~clk & w304_r;
	
	// z80_dlatch dw305(.MCLK(MCLK), .en(clk), .inp(w228 & w227), .outp(w305));
	reg dw305_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw305_outp <= w228 & w227;
	end
	assign w305 = dw305_outp;
	
	assign w306 = ~(w228 & w227 & w229);
	
	// z80_dlatch dw307(.MCLK(MCLK), .en(clk), .inp(w306 | w55), .outp(w307));
	reg dw307_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw307_outp <= w306 | w55;
	end
	assign w307 = dw307_outp;
	
	assign w308 = ~(~w294 & w313 & w344);
	
	assign w309 = ~(w231 & w230);
	
	assign w310 = ~(w233 & w232);
	
	assign w311 = ~(w238 & (w343 | ~w312));
	
	assign w312 = ~(w100 | ~w169);
	
	assign w313 = ~(~w246 | ~w243 | ~w242 | ~w274 | ~w241 | ~w239 | ~w238 | w309);
	
	// z80_dlatch dl44(.MCLK(MCLK), .en(clk), .inp(w308), .outp(l44));
	reg dl44_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl44_outp <= w308;
	end
	assign l44 = dl44_outp;
	
	assign w314 = w307 | l44;
	
	assign w315 = (~w147[2] & w183) | (~w183 & ~w147[5]);
	
	assign w316 = ~(w315 | w317);
	
	assign w317 = (~w147[1] & w183) | (~w183 & ~w147[4]);
	
	assign w318 = (~w147[0] & w183) | (~w183 & ~w147[3]);
	
	// z80_dlatch dw319(.MCLK(MCLK), .en(clk), .inp(~((w316 & w310) | w309)), .outp(w319));
	reg dw319_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw319_outp <= ~((w316 & w310) | w309);
	end
	assign w319 = dw319_outp;
	
	// z80_dlatch dl45(.MCLK(MCLK), .en(clk), .inp(w315), .outp(l45));
	reg dl45_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl45_outp <= w315;
	end
	assign l45 = dl45_outp;
	
	always @(posedge MCLK)
	begin
		if (w304)
			w320 <= l45;
		else if (clk)
			w320 <= w320;
	end
	
	
	// z80_rs_trig_nand rs321(.MCLK(MCLK), .nset(clk | w305), .nrst(clk | ~w305 | w293), .q(w321), .nq());
	reg rs321_q = 1'h0, rs321_nq = 1'h1;
	wire rs321_qn = ~(rs321_nq & (clk | w305));
	always @(posedge MCLK)
	begin
		rs321_q <= rs321_qn;
		rs321_nq <= ~(rs321_qn & (clk | ~w305 | w293));
	end
	assign w321 = rs321_q;
	
	
	// z80_rs_trig_nor rs322(.MCLK(MCLK), .rst(clk & w113), .set(clk & ~w113), .q(w322), .nq());
	reg rs322_q = 1'h0, rs322_nq = 1'h1;
	wire rs322_qn = ~((clk & w113) | rs322_nq);
	always @(posedge MCLK)
	begin
		rs322_q <= rs322_qn;
		rs322_nq <= ~((clk & ~w113) | rs322_qn);
	end
	assign w322 = rs322_q;
	
	assign w323 = ~((clk & ~w113) | w322);
	
	assign w324 = ~clk & ~w325;
	
	assign w325 = ~(w302 & w326);
	
	assign w326 = ~(w303 & pla[96]);
	
	// z80_dlatch dl46(.MCLK(MCLK), .en(w324), .inp(w327_n), .outp(l46));
	reg dl46_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (w324)
			dl46_outp <= w327_n;
	end
	assign l46 = dl46_outp;
	
	// z80_dlatch dl46_i(.MCLK(MCLK), .en(w324), .inp(w327_i), .outp(l46_i));
	reg dl46_i_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (w324)
			dl46_i_outp <= w327_i;
	end
	assign l46_i = dl46_i_outp;
	
	
	// z80_rs_trig_nor rs327(.MCLK(MCLK), .rst(l46 & w328), .set(l46_i & w328), .q(w327_n), .nq(w327_i));
	reg rs327_q = 1'h0, rs327_nq = 1'h1;
	wire rs327_qn = ~((l46 & w328) | rs327_nq);
	always @(posedge MCLK)
	begin
		rs327_q <= rs327_qn;
		rs327_nq <= ~((l46_i & w328) | rs327_qn);
	end
	assign w327_n = rs327_q;
	assign w327_i = rs327_nq;
	
	assign w328 = ~clk & ~w302;
	
	always @(posedge MCLK)
	begin
		w329_r <= ~w326 & ~w327;
	end
	
	assign w329 = ~clk & w329_r;
	
	// z80_dlatch dl47(.MCLK(MCLK), .en(w324), .inp(w330_n), .outp(l47));
	reg dl47_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (w324)
			dl47_outp <= w330_n;
	end
	assign l47 = dl47_outp;
	
	// z80_dlatch dl47_i(.MCLK(MCLK), .en(w324), .inp(w330_i), .outp(l47_i));
	reg dl47_i_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (w324)
			dl47_i_outp <= w330_i;
	end
	assign l47_i = dl47_i_outp;
	
	
	// z80_rs_trig_nor rs330(.MCLK(MCLK), .rst(l47 & w329), .set(l47_i & w329), .q(w330_n), .nq(w330_i));
	reg rs330_q = 1'h0, rs330_nq = 1'h1;
	wire rs330_qn = ~((l47 & w329) | rs330_nq);
	always @(posedge MCLK)
	begin
		rs330_q <= rs330_qn;
		rs330_nq <= ~((l47_i & w329) | rs330_qn);
	end
	assign w330_n = rs330_q;
	assign w330_i = rs330_nq;
	
	always @(posedge MCLK)
	begin
		w331_r <= ~w326 & w327;
	end
	
	assign w331 = ~clk & w331_r;
	
	always @(posedge MCLK)
	begin
		if (w327_i)
			w327 <= 1'h0;
		else if (w327_n)
			w327 <= 1'h1;
	end
	
	// z80_dlatch dl48(.MCLK(MCLK), .en(w324), .inp(w332_n), .outp(l48));
	reg dl48_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (w324)
			dl48_outp <= w332_n;
	end
	assign l48 = dl48_outp;
	
	// z80_dlatch dl48_i(.MCLK(MCLK), .en(w324), .inp(w332_i), .outp(l48_i));
	reg dl48_i_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (w324)
			dl48_i_outp <= w332_i;
	end
	assign l48_i = dl48_i_outp;
	
	// z80_rs_trig_nor rs332(.MCLK(MCLK), .rst(l48 & w331), .set(l48_i & w331), .q(w332_n), .nq(w332_i));
	reg rs332_q = 1'h0, rs332_nq = 1'h1;
	wire rs332_qn = ~((l48 & w331) | rs332_nq);
	always @(posedge MCLK)
	begin
		rs332_q <= rs332_qn;
		rs332_nq <= ~((l48_i & w331) | rs332_qn);
	end
	assign w332_n = rs332_q;
	assign w332_i = rs332_nq;
	
	
	assign w333 = ~((w327 & w332_n) | (~w327 & w330_n));
	
	assign w334 = ~clk & ~w293;
	
	assign w335 = ~clk & ~w292;
	
	assign w336 = ~clk & ~w298;
	
	assign w337 = ~clk & w307;
	
	assign w338 = w305 & ~w301;
	
	assign w339 = clk;
	
	assign w340 = ~(~w341 & ~w320);
	
	// z80_dlatch dw341(.MCLK(MCLK), .en(clk), .inp(~w311), .outp(w341));
	reg dw341_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw341_outp <= ~w311;
	end
	assign w341 = dw341_outp;
	
	assign w342 = ~(~w341 & w320);
	
	assign w343 = ~(~w241 | ~w239 | (~w315 & w317 & (w310 | ~w344)));
	
	assign w344 = ~(w310 | ~w244 | ~w250 | ~w248);
	
	// z80_dlatch dw345(.MCLK(MCLK), .en(clk), .inp(w343 | w312), .outp(w345));
	reg dw345_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw345_outp <= w343 | w312;
	end
	assign w345 = dw345_outp;
	
	// z80_dlatch dw346(.MCLK(MCLK), .en(clk), .inp(w242 & (~w315 | w317 | w344)), .outp(w346));
	reg dw346_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw346_outp <= w242 & (~w315 | w317 | w344);
	end
	assign w346 = dw346_outp;
	
	// z80_dlatch dw347(.MCLK(MCLK), .en(clk), .inp((w344 | ~w315 | ~w317) & w243), .outp(w347));
	reg dw347_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw347_outp <= (w344 | ~w315 | ~w317) & w243;
	end
	assign w347 = dw347_outp;
	
	assign w348 = ~(~w327 & w349);
	
	assign w349 = ~(w333 ? w346 : w345);
	
	assign w350 = ~(w327 & w349);
	
	assign w351 = ~(w333 ? w345 : w346);
	
	assign w352 = ~(~w327 & w351);
	
	assign w353 = ~(w327 & w351);
	
	assign w354 = ~(~w327 & ~w347);
	
	assign w355 = ~(w327 & ~w347);
	
	assign w356 = ~(w315 | w317);
	
	assign w357 = ~((w248 & w250) | w318);
	
	// z80_dlatch dl81(.MCLK(MCLK), .en(clk), .inp(~(~w274 | ~w246 | (w356 & (w357 | ~w244)))), .outp(l81));
	reg dl81_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl81_outp <= ~(~w274 | ~w246 | (w356 & (w357 | ~w244)));
	end
	assign l81 = dl81_outp;
	
	
	assign w358 = ~l81;
	
	// z80_dlatch dw359(.MCLK(MCLK), .en(clk), .inp(~w259), .outp(w359));
	reg dw359_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw359_outp <= ~w259;
	end
	assign w359 = dw359_outp;
	
	assign w360 = ~clk & ~w359;
	
	// z80_dlatch dl49(.MCLK(MCLK), .en(w360), .inp(w361_n), .outp(l49));
	reg dl49_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (w360)
			dl49_outp <= w361_n;
	end
	assign l49 = dl49_outp;
	
	// z80_dlatch dl49_i(.MCLK(MCLK), .en(w360), .inp(w361_i), .outp(l49_i));
	reg dl49_i_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (w360)
			dl49_i_outp <= w361_i;
	end
	assign l49_i = dl49_i_outp;
	
	// z80_rs_trig_nor rs361(.MCLK(MCLK), .rst(l49 & w362), .set(l49_i & w362), .q(w361_n), .nq(w361_i));
	reg rs361_q = 1'h0, rs361_nq = 1'h1;
	wire rs361_qn = ~((l49 & w362) | rs361_nq);
	always @(posedge MCLK)
	begin
		rs361_q <= rs361_qn;
		rs361_nq <= ~((l49_i & w362) | rs361_qn);
	end
	assign w361_n = rs361_q;
	assign w361_i = rs361_nq;
	
	assign w362 = ~clk & w359;
	
	assign w363 = ~(w361_n & w358);
	
	assign w364 = ~(w361_i & w358);
	
	assign w365 = ~(w248 & (w249 | w317));
	
	assign w366 = ~(w250 & (w249 | ~w317));
	
	assign w367 = ~(w318 | w368);
	
	assign w368 = ~(w315 | w317);
	
	// z80_dlatch dw369(.MCLK(MCLK), .en(clk), .inp(~w289), .outp(w369));
	reg dw369_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw369_outp <= ~w289;
	end
	assign w369 = dw369_outp;
	
	// z80_dlatch dw370(.MCLK(MCLK), .en(clk), .inp(~w288), .outp(w370));
	reg dw370_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw370_outp <= ~w288;
	end
	assign w370 = dw370_outp;
	
	assign w371 = ~(~w286 | ~w284 | (w271 & ~w268));
	
	// z80_dlatch dw372(.MCLK(MCLK), .en(clk), .inp(~w286), .outp(w372));
	reg dw372_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw372_outp <= ~w286;
	end
	assign w372 = dw372_outp;
	
	// z80_dlatch dw373(.MCLK(MCLK), .en(clk), .inp(~w285 | ~w284), .outp(w373));
	reg dw373_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw373_outp <= ~w285 | ~w284;
	end
	assign w373 = dw373_outp;
	
	assign w374 = ~(~w285 | ~w284 | ~w266 | ~w267 | w375);
	
	assign w375 = ~(w376 & w275);
	
	assign w376 = ~(
		(w41 & w123 & w234)
		| (w114 & w127 & w255)
		);
	
	// z80_dlatch dw377(.MCLK(MCLK), .en(clk), .inp(w375), .outp(w377));
	reg dw377_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw377_outp <= w375;
	end
	assign w377 = dw377_outp;
	
	// z80_dlatch dw378_1(.MCLK(MCLK), .en(clk), .inp(~w267), .outp(w378_1));
	reg dw378_1_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw378_1_outp <= ~w267;
	end
	assign w378_1 = dw378_1_outp;
	
	// z80_dlatch dw378_2(.MCLK(MCLK), .en(clk), .inp(~w266), .outp(w378_2));
	reg dw378_2_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw378_2_outp <= ~w266;
	end
	assign w378_2 = dw378_2_outp;
	
	assign w378 = w378_1 | w378_2;
	
	// z80_dlatch dw379_1(.MCLK(MCLK), .en(clk), .inp(~w268), .outp(w379_1));
	reg dw379_1_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw379_1_outp <= ~w268;
	end
	assign w379_1 = dw379_1_outp;
	
	// z80_dlatch dw379_2(.MCLK(MCLK), .en(clk), .inp(~w269), .outp(w379_2));
	reg dw379_2_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw379_2_outp <= ~w269;
	end
	assign w379_2 = dw379_2_outp;
	
	assign w379 = ~(w379_1 | w379_2);
	
	// z80_dlatch dl50(.MCLK(MCLK), .en(clk), .inp(w273), .outp(l50));
	reg dl50_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl50_outp <= w273;
	end
	assign l50 = dl50_outp;
	
	// z80_dlatch dl51(.MCLK(MCLK), .en(clk), .inp(w274), .outp(l51));
	reg dl51_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl51_outp <= w274;
	end
	assign l51 = dl51_outp;
	
	// z80_rs_trig_nand rs380(.MCLK(MCLK), .nset(clk | l51), .nrst(clk | l50), .q(), .nq(w380_i));
	reg rs380_q = 1'h0, rs380_nq = 1'h1;
	wire rs380_qn = ~(rs380_nq & (clk | l51));
	always @(posedge MCLK)
	begin
		rs380_q <= rs380_qn;
		rs380_nq <= ~(rs380_qn & (clk | l50));
	end
	assign w380_i = rs380_nq;
	
	assign w380 = ~w380_i;
	
	// z80_dlatch dw381(.MCLK(MCLK), .en(clk), .inp(~w380 & ~w274), .outp(w381));
	reg dw381_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw381_outp <= ~w380 & ~w274;
	end
	assign w381 = dw381_outp;
	
	// z80_dlatch dl52(.MCLK(MCLK), .en(clk), .inp(~w274), .outp(l52));
	reg dl52_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl52_outp <= ~w274;
	end
	assign l52 = dl52_outp;
	
	assign w382 = ~clk & l52 & ~w381;
	
	assign w383 = ~(w279 | ~w486);
	
	assign w384 = ~((w114 & w123 & w234)
		| (w109 & (w123 | w127) & w255));
	
	assign w385 = ~(w114 | w109);
	
	assign w386 = ~((w109 & w123 & w234)
		| (w41 & w127));
	
	assign w387 = ~(w109 & w127 & w388);
	
	assign w388 = ~(pla[7] | w177);
	
	assign w389 = ~(w390 & ~w162);
	
	// z80_dlatch dw390(.MCLK(MCLK), .en(clk), .inp(~w270), .outp(w390));
	reg dw390_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw390_outp <= ~w270;
	end
	assign w390 = dw390_outp;
	
	// z80_dlatch dw391(.MCLK(MCLK), .en(clk), .inp(~w280), .outp(w391));
	reg dw391_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw391_outp <= ~w280;
	end
	assign w391 = dw391_outp;
	
	//assign w392 = ~(w391 & ~w162);
	
	always @(posedge MCLK)
	begin
		w392 <= ~(w391 & ~w162);
	end
	
	assign w393 = ~(~w277
		| (w114 & w127 & w255)
		| (w41 & w123 & w234)
		);
	
	assign w394 = ~((w390 & ~w166)
		| (w109 & w123 & w234)
		| (w41 & w127 & w255)
		);
	
	assign w395 = ~(~w165 & w390);
	
	// z80_dlatch dl53(.MCLK(MCLK), .en(clk), .inp(~w276), .outp(l53));
	reg dl53_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl53_outp <= ~w276;
	end
	assign l53 = dl53_outp;
	
	assign w396 = ~(w395 & w394 & (w390 | l53));
	
	assign w397 = ~((w41 | w109 | w68) & w127);
	
	assign w398 = ~(w114 & w123 & w83);
	
	assign w399 = ~((w390 & ~pla[36] & w255) | w400);
	
	assign w400_v = (
		(w41 & w127 & w255)
		| (w114 & w123 & pla[38])
		);
	
	// z80_dlatch dw400(.MCLK(MCLK), .en(clk), .inp(w400_v), .outp(w400));
	reg dw400_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw400_outp <= w400_v;
	end
	assign w400 = dw400_outp;
	
	assign w401 = ~(
		((~w147[3] & w109) | w114) &
		w127 & pla[38]
		);
	
	// z80_dlatch dl54(.MCLK(MCLK), .en(clk), .inp(w371), .outp(l54));
	reg dl54_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl54_outp <= w371;
	end
	assign l54 = dl54_outp;
	
	// z80_dlatch dl55(.MCLK(MCLK), .en(clk), .inp(w374), .outp(l55));
	reg dl55_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl55_outp <= w374;
	end
	assign l55 = dl55_outp;
	
	assign w402 = ~l54 | l55;
	
	assign w403 = ~(~w283 | ~w269 | ~w268);
	
	// z80_dlatch dw404(.MCLK(MCLK), .en(clk), .inp(w403 | ~w371), .outp(w404));
	reg dw404_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw404_outp <= w403 | ~w371;
	end
	assign w404 = dw404_outp;
	
	assign w405 = ~(~w147[4] | ~w406);
	
	assign w406 = pla[50] | ~w147[5];
	
	assign w407 = ~(~w147[4] | w406);
	
	assign w408 = ~(w147[4] | w406);
	
	assign w409 = ~(w147[4] | ~w406);
	
	assign w410 = ~(~w257 | ~w258 | (w366 & (w318 | w368)));
	
	assign w411 = ~(~w251 | (w366 & w367) | (~w274 & ~w380));
	
	assign w412 = ~(w260 & w262);
	
	assign w413 = ~(w318 | w368);
	
	assign w414 = ~(~w264 | ~w263 | ~w274
		| (w365 & (w318 | w368)));
	
	assign w415 = ~(w412 | (w413 & w365) | (~w274 & w380));
	
	// z80_dlatch dw416(.MCLK(MCLK), .en(clk), .inp(w410), .outp(w416));
	reg dw416_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw416_outp <= w410;
	end
	assign w416 = dw416_outp;
	
	// z80_dlatch dw417(.MCLK(MCLK), .en(clk), .inp(~w415), .outp(w417));
	reg dw417_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw417_outp <= ~w415;
	end
	assign w417 = dw417_outp;
	
	// z80_dlatch dw418(.MCLK(MCLK), .en(clk), .inp(~w414), .outp(w418));
	reg dw418_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw418_outp <= ~w414;
	end
	assign w418 = dw418_outp;
	
	// z80_dlatch dw419(.MCLK(MCLK), .en(clk), .inp(w274), .outp(w419));
	reg dw419_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw419_outp <= w274;
	end
	assign w419 = dw419_outp;
	
	always @(posedge MCLK)
	begin
		if (clk)
			w420 <= w420;
		else if (w421)
			w420 <= w494;
	end
	
	assign w421 = ~clk & ~w419;
	
	assign w422 = ~(w408 | (w405 & w423));
	
	// z80_dlatch dl73(.MCLK(MCLK), .en(clk), .inp(~w473), .outp(l73));
	reg dl73_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl73_outp <= ~w473;
	end
	assign l73 = dl73_outp;
	
	assign w423 = l73;
	
	assign w424 = ~clk & w472;
	
	always @(posedge MCLK)
	begin
		if (clk)
			w425 <= 1'h1;
		else if (w407)
			w425 <= 1'h1;
		else if (w424 & w405)
			w425 <= w423;
		else if (w424 & w408)
			w425 <= w484[7];
		else if (w424 & w409)
			w425 <= w484[0];
	end
	
	assign w426 = ~(w390 & ~w154);
	
	assign w427 = ~clk & ~w426;
	
	// z80_dlatch dl56(.MCLK(MCLK), .en(clk), .inp(~w283), .outp(l56));
	reg dl56_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl56_outp <= ~w283;
	end
	assign l56 = dl56_outp;
	
	assign w428 = l56 & w426 & ~clk;
	
	// z80_dlatch dl61(.MCLK(MCLK), .en(clk), .inp(~w442_i), .outp(l61));
	reg dl61_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl61_outp <= ~w442_i;
	end
	assign l61 = dl61_outp;
	
	assign w429 = ~(~l61 & (w430 | w431));
	
	// z80_dlatch dw430(.MCLK(MCLK), .en(clk), .inp(~w384), .outp(w430));
	reg dw430_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw430_outp <= ~w384;
	end
	assign w430 = dw430_outp;
	
	// z80_dlatch dw431(.MCLK(MCLK), .en(clk), .inp(~w282), .outp(w431));
	reg dw431_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw431_outp <= ~w282;
	end
	assign w431 = dw431_outp;
	
	// z80_dlatch dl57(.MCLK(MCLK), .en(clk), .inp(w385), .outp(l57));
	reg dl57_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl57_outp <= w385;
	end
	assign l57 = dl57_outp;
		
	assign w432 = ~clk & l57;
	
	assign w433 = ~w429 & ~clk;
	
	assign w434 = ~clk & ~w435;
	
	// z80_dlatch dl58(.MCLK(MCLK), .en(clk), .inp(w386), .outp(l58));
	reg dl58_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl58_outp <= w386;
	end
	assign l58 = dl58_outp;
	
	// z80_dlatch dl59(.MCLK(MCLK), .en(clk), .inp(w281), .outp(l59));
	reg dl59_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl59_outp <= w281;
	end
	assign l59 = dl59_outp;
	
	assign w435 = l58 & l59;
	
	assign w436 = ~clk & ~w389;
	
	// z80_dlatch dl60(.MCLK(MCLK), .en(clk), .inp(w387), .outp(l60));
	reg dl60_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl60_outp <= w387;
	end
	assign l60 = dl60_outp;
	
	assign w437 = ~clk & ~l60;
	
	assign w438 = ~w524;
	
	assign w439 = ~clk & ~w162 & ~w429;
	
	assign w440 = ~clk & ~w392;
	
	// z80_dlatch dl62(.MCLK(MCLK), .en(clk), .inp(w505), .outp(l62));
	reg dl62_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl62_outp <= w505;
	end
	assign l62 = dl62_outp;
	
	always @(posedge MCLK)
	begin
		if (clk)
			w441 <= w441;
		else if (w382)
			w441 <= ~w484[2];
		else if (w437)
			w441 <= ~w438;
		else if (w436)
			w441 <= ~1'h0;
		else if (w439)
			w441 <= ~w449;
		else if (w440)
		begin
			if (w452)
				w441 <= (w508 ^ w507) | w453;
			else
				w441 <= w506 ^ l62;
		end
	end
	
	// z80_rs_trig_nor rs442(.MCLK(MCLK), .rst(w434), .set(w433), .q(w442), .nq(w442_i));
	reg rs442_q = 1'h0, rs442_nq = 1'h1;
	wire rs442_qn = ~((w434) | rs442_nq);
	always @(posedge MCLK)
	begin
		rs442_q <= rs442_qn;
		rs442_nq <= ~((w433) | rs442_qn);
	end
	assign w442 = rs442_q;
	assign w442_i = rs442_nq;
	
	// z80_dlatch dl83(.MCLK(MCLK), .en(w432), .inp(w484[0]), .outp(l83));
	reg dl83_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (w432)
			dl83_outp <= w484[0];
	end
	assign l83 = dl83_outp;
	
	assign w443 = ~(pla[21] & l83 & w501);
	
	// z80_dlatch dl84(.MCLK(MCLK), .en(w432), .inp(w484[4]), .outp(l84));
	reg dl84_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (w432)
			dl84_outp <= w484[4];
	end
	assign l84 = dl84_outp;
	
	assign w444 = ~(pla[21] & l84 & w502);
	
	always @(posedge MCLK)
	begin
		if (clk)
			w445 <= w445;
		else if (w436)
			w445 <= 1'h0;
		else if (w382)
			w445 <= w484[6];
		else if (w440)
			w445 <= (w487 | w503[3:0] != 4'h0 | w504[3:0] != 4'h0);
	end
	
	assign w446 = ~w442 & ~w433;
	
	assign w448 = ~(w420 ^ w318);
	
	// z80_dlatch dw449(.MCLK(MCLK), .en(clk & w446), .inp(~w505), .outp(w449));
	reg dw449_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk & w446)
			dw449_outp <= ~w505;
	end
	assign w449 = dw449_outp;
	
	always @(posedge MCLK)
	begin
		if (clk)
			w450 <= w450;
		else if (w382)
			w450 <= ~w484[7];
		else if (w440)
			w450 <= w504[3];
	end
	
	// z80_dlatch dw452(.MCLK(MCLK), .en(clk), .inp(~w158), .outp(w452));
	reg dw452_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw452_outp <= ~w158;
	end
	assign w452 = dw452_outp;
	
	// z80_dlatch dw453(.MCLK(MCLK), .en(clk), .inp(pla[15]), .outp(w453));
	reg dw453_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw453_outp <= pla[15];
	end
	assign w453 = dw453_outp;
	
	// z80_dlatch dl63(.MCLK(MCLK), .en(clk), .inp(w180), .outp(l63));
	reg dl63_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl63_outp <= w180;
	end
	assign l63 = dl63_outp;
	
	assign w454 = ~l63 & ~w115;
	
	// z80_dlatch dl64(.MCLK(MCLK), .en(clk), .inp(w181), .outp(l64));
	reg dl64_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl64_outp <= w181;
	end
	assign l64 = dl64_outp;
	
	assign w455 = ~l64 & ~w115;
	
	// z80_dlatch dl65(.MCLK(MCLK), .en(clk), .inp(w168), .outp(l65));
	reg dl65_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl65_outp <= w168;
	end
	assign l65 = dl65_outp;
	
	assign w456 = ~l65 & ~w115;
	
	assign w457 = (pla[30] & ~w147[3]) | ~w160;
	
	// z80_dlatch dl66(.MCLK(MCLK), .en(clk), .inp(w393), .outp(l66));
	reg dl66_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl66_outp <= w393;
	end
	assign l66 = dl66_outp;
	
	assign w458 = ~clk & ~l66;
	
	assign w459 = ~clk & ~w395;
	
	// z80_dlatch dl67(.MCLK(MCLK), .en(clk), .inp(w396), .outp(l67));
	reg dl67_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl67_outp <= w396;
	end
	assign l67 = dl67_outp;
	
	assign w460 = ~clk & ~l67;
	
	// z80_dlatch dl68(.MCLK(MCLK), .en(clk), .inp(w394), .outp(l68));
	reg dl68_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl68_outp <= w394;
	end
	assign l68 = dl68_outp;
	
	assign w461 = ~clk & ~l68;
	
	assign w462 = ~clk & ~w429;
	
	// z80_dlatch dl70(.MCLK(MCLK), .en(clk), .inp(w278), .outp(l70));
	reg dl70_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl70_outp <= w278;
	end
	assign l70 = dl70_outp;
	
	assign w463 = ~clk & ~l70;
	
	always @(posedge MCLK)
	begin
		if (clk)
			w464 <= w464;
		else if (w382)
			w464 <= ~w484[1];
		else if (w465)
			w464 <= ~w484[7];
		else if (w466)
			w464 <= w457;
	end
	
	// z80_dlatch dl71(.MCLK(MCLK), .en(clk), .inp(w272), .outp(l71));
	reg dl71_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl71_outp <= w272;
	end
	assign l71 = dl71_outp;
	
	assign w465 = ~clk & ~l71;
	
	assign w466 = ~clk & w390 & ~pla[21];
	
	assign w467 = ~(w464 & ~w115);
	
	// z80_dlatch dl72(.MCLK(MCLK), .en(clk), .inp(w397), .outp(l72));
	reg dl72_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl72_outp <= w397;
	end
	assign l72 = dl72_outp;
	
	assign w468 = ~(w464 & ~(w115 & l72));
	
	assign w469 = ~clk & w470;
	
	// z80_dlatch dw470(.MCLK(MCLK), .en(clk), .inp(~w268 & w271), .outp(w470));
	reg dw470_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dw470_outp <= ~w268 & w271;
	end
	assign w470 = dw470_outp;
	
	assign w471 = w470 & ~w147[3];
	
	assign w472 = w470 & w147[3];
	
	always @(posedge MCLK)
	begin
		if (clk)
			w473 <= w473;
		else if (w469)
		begin
			if (w472)
				w473 <= ~w484[0];
			if (w471)
				w473 <= ~w484[7];
		end
		else if (w382)
			w473 <= ~w484[0];
		else if (w474)
			w473 <= ~1'h0;
		else if (w458)
			w473 <= w477;
		else if (w463)
			w473 <= ~w476;
	end
	
	assign w474 = ~clk & ~w475;
	
	assign w475 = ~(w443 & w370);
	
	// z80_dlatch dl75(.MCLK(MCLK), .en(clk & w446), .inp(w477), .outp(l75));
	reg dl75_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk & w446)
			dl75_outp <= w477;
	end
	assign l75 = dl75_outp;
	
	always @(posedge MCLK)
	begin
		if (clk)
			w476 <= w476;
		else if (w461)
			w476 <= ~w423;
		else if (w460)
			w476 <= ~1'h1;
		else if (w459)
			w476 <= ~1'h0;
		else if (w462)
			w476 <= l75;
	end
	
	assign w477 = ~(w467 ^ w507);
	
	// z80_dlatch dl76(.MCLK(MCLK), .en(clk), .inp(w398), .outp(l76));
	reg dl76_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl76_outp <= w398;
	end
	assign l76 = dl76_outp;
	
	assign w479 = l76 & w399;
	
	// z80_dlatch dl77(.MCLK(MCLK), .en(clk), .inp(w401), .outp(l77));
	reg dl77_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl77_outp <= w401;
	end
	assign l77 = dl77_outp;
	
	assign w480 = ~clk & ~l77;
	
	assign w481 = ~w468;
	
	assign w483 = ~w1 & w2;
	
	assign w485 = ~w441;
	
	assign w486 = ~w445;
	
	assign w487 = ~w486;
	
	assign w490 = ~clk & ~w399;
	
	assign w491 = ~clk & ~w479;
	
	assign w492 = ~clk & ~w379;
	
	assign w493 = ~w404;
	
	assign w494 = ~((w484[6] & w409)
		| (w484[2] & w408)
		| (w484[7] & w407)
		| (w484[0] & w405));
	
	assign w495 = w409 & ~w147[3] & w470;
	
	always @(posedge MCLK)
	begin
		if (w377)
			w496 <= { w504, w503 };
		else if (w493)
			w496 <= w513;
		else if (w471)
		begin
			w496[7:1] <= w513[6:0];
			if (~w495)
				w496[0] <= ~w422;
			else
				w496[0] <= w484[7];
		end
		else if (w472)
		begin
			w496[6:0] <= w513[7:1];
			w496[7] <= w425;
		end
		else if (w372)
			w496 <= w497;
		else if (w373)
			w496 <= w498;
		else if (w378)
			w496 <= w511;
	end
	
	assign w497 = ~(8'h1 << (~w146[5:3]));
	
	always @(posedge MCLK)
	begin
		if (clk)
			w498 <= w498;
		else if (w428)
			w498 <= ~w496;
		else if (w427)
			w498 <= 8'h0;
		else if (w480)
			w498[3:0] <= ~w499;
	end
	
	always @(posedge MCLK)
	begin
		if (w432)
			w499 <= ~w496[7:4];
	end
	
	assign w500 = w446 ? w498[3:0] : w498[7:4];
	
	assign w501 = ~(w498[7] & (w498[6] | w498[5] | (w498[4] & ~w502)));
	
	assign w502 = ~(w498[3] & (w498[2] | w498[1]));
	
	always @(posedge MCLK)
	begin
		if (w446)
			w503 <= w504;
		else
			w503 <= w503;
	end
	
	wire [3:0] c_in;
	wire [3:0] o1 = w512;
	wire [3:0] o2 = w500;
	wire [3:0] t = ~((c_in & (o1 | o2)) | (o1 & o2) | {4{w455}});
	assign w504 = ((o1 | o2 | c_in) & (t | {4{w454}})) | (o1 & o2 & c_in);
	wire [3:0] c_out = ~t & ~{4{w456}};
	
	assign c_in[0] = ~(w467 ^ w476);
	assign c_in[1] = c_out[0];
	assign c_in[2] = c_out[1];
	assign c_in[3] = c_out[2];
	
	assign w505 = ~(((w485 ^ w504[0]) ^ w504[1]) ^ w504[2]);
	
	assign w506 = w504[3] ^ w503[3];
	
	assign w508 = c_out[2];
	assign w507 = c_out[3];
	
	always @(posedge MCLK)
	begin
		if (w432)
			w510 <= ~{ w496[3:0], w500 };
	end
	
	always @(posedge MCLK)
	begin
		if (clk)
			w511 <= w511;
		else if (w480)
			w511 <= ~w510;
		else if (w492)
			w511 <= ~w496;
		else
		begin
			if (w491)
			begin
				w511[2:0] <= 3'h0;
				w511[6] <= 1'h0;
			end
			if (w491 & w490)
				w511[5:3] <= 3'h0;
			if (w491 | w490)
				w511[7] <= 1'h0;
		end
	end
	
	wire [7:0] w511_xor = w481 ? ~w511 : w511;
	
	assign w512 = w446 ? w511_xor[3:0] : w511_xor[7:4];
	
	assign rpull1[0] =
		( {16{~w364}} & regs[0][1] ) |
		( {16{~w363}} & regs[1][1] ) |
		( {16{~w355}} & regs[2][1] ) |
		( {16{~w354}} & regs[3][1] ) |
		( {16{~w353}} & regs[4][1] ) |
		( {16{~w352}} & regs[5][1] ) |
		( {16{~w350}} & regs[6][1] ) |
		( {16{~w348}} & regs[7][1] ) |
		( {16{~w342}} & regs[8][1] ) |
		( {16{~w340}} & regs[9][1] ) |
		( {16{~w319}} & regs[10][1] ) |
		( {16{~w314}} & regs[11][1] ) |
		{({8{w517}} & w513), ({8{w516}} & w484)};
	
	assign rpull1[1] =
		( {16{~w364}} & regs[0][0] ) |
		( {16{~w363}} & regs[1][0] ) |
		( {16{~w355}} & regs[2][0] ) |
		( {16{~w354}} & regs[3][0] ) |
		( {16{~w353}} & regs[4][0] ) |
		( {16{~w352}} & regs[5][0] ) |
		( {16{~w350}} & regs[6][0] ) |
		( {16{~w348}} & regs[7][0] ) |
		( {16{~w342}} & regs[8][0] ) |
		( {16{~w340}} & regs[9][0] ) |
		( {16{~w319}} & regs[10][0] ) |
		( {16{~w314}} & regs[11][0] ) |
		{({8{w517}} & ~w513), ({8{w516}} & ~w484)};
	
	assign rpull2[0] =
		( {16{w336}} & regs2[0][1] ) |
		( {16{w337}} & regs2[1][1] ) |
		( {16{w335}} & ~w528 );
	
	assign rpull2[1] =
		( {16{w336}} & regs2[0][0] ) |
		( {16{w337}} & regs2[1][0] ) |
		( {16{w335}} & w528 );
		
	assign rpull1_comb[0] = rpull1[0] | ({16{w338}} & rpull2[0]);
	assign rpull1_comb[1] = rpull1[1] | ({16{w338}} & rpull2[1]);
	assign rpull2_comb[0] = rpull2[0] | ({16{w338}} & rpull1[0]);
	assign rpull2_comb[1] = rpull2[1] | ({16{w338}} & rpull1[1]);
	
	assign rpullup1[0] = (clk & w339) ? 16'hffff :
		( {16{~w364}} & regs[0][0] ) |
		( {16{~w363}} & regs[1][0] ) |
		( {16{~w355}} & regs[2][0] ) |
		( {16{~w354}} & regs[3][0] ) |
		( {16{~w353}} & regs[4][0] ) |
		( {16{~w352}} & regs[5][0] ) |
		( {16{~w350}} & regs[6][0] ) |
		( {16{~w348}} & regs[7][0] ) |
		( {16{~w342}} & regs[8][0] ) |
		( {16{~w340}} & regs[9][0] ) |
		( {16{~w319}} & regs[10][0] ) |
		( {16{~w314}} & regs[11][0] ) |
		{({8{w517}} & ~w513), ({8{w516}} & ~w484)};
	
	assign rpullup1[1] = (clk & w339) ? 16'hffff :
		( {16{~w364}} & regs[0][1] ) |
		( {16{~w363}} & regs[1][1] ) |
		( {16{~w355}} & regs[2][1] ) |
		( {16{~w354}} & regs[3][1] ) |
		( {16{~w353}} & regs[4][1] ) |
		( {16{~w352}} & regs[5][1] ) |
		( {16{~w350}} & regs[6][1] ) |
		( {16{~w348}} & regs[7][1] ) |
		( {16{~w342}} & regs[8][1] ) |
		( {16{~w340}} & regs[9][1] ) |
		( {16{~w319}} & regs[10][1] ) |
		( {16{~w314}} & regs[11][1] ) |
		{({8{w517}} & w513), ({8{w516}} & w484)};
	
	assign rpullup2[0] =
		( {16{w336}} & regs2[0][0] ) |
		( {16{w337}} & regs2[1][0] ) |
		( {16{w335}} & w528 );
	
	assign rpullup2[1] =
		( {16{w336}} & regs2[0][1] ) |
		( {16{w337}} & regs2[1][1] ) |
		( {16{w335}} & ~w528 );
		
	assign rpullup1_comb[0] = rpullup1[0] | ({16{w338}} & rpullup2[0]);
	assign rpullup1_comb[1] = rpullup1[1] | ({16{w338}} & rpullup2[1]);
	assign rpullup2_comb[0] = rpullup2[0] | ({16{w338}} & rpullup1[0]);
	assign rpullup2_comb[1] = rpullup2[1] | ({16{w338}} & rpullup1[1]);
	
	always @(posedge MCLK)
	begin
		if (w338)
		begin
			w514 <= ((w514 & w520) | rpullup1_comb[0]) & ~rpull1_comb[0];
			w515 <= ((w515 & w521) | rpullup1_comb[1]) & ~rpull1_comb[1];
			w520 <= ((w514 & w520) | rpullup2_comb[0]) & ~rpull2_comb[0];
			w521 <= ((w515 & w521) | rpullup2_comb[1]) & ~rpull2_comb[1];
		end
		else
		begin
			w514 <= (w514 | rpullup1_comb[0]) & ~rpull1_comb[0];
			w515 <= (w515 | rpullup1_comb[1]) & ~rpull1_comb[1];
			w520 <= (w520 | rpullup2_comb[0]) & ~rpull2_comb[0];
			w521 <= (w521 | rpullup2_comb[1]) & ~rpull2_comb[1];
		end
	end
	
	// z80_dlatch dl79(.MCLK(MCLK), .en(clk), .inp(w411), .outp(l79));
	reg dl79_outp = 1'h0;
	always @(posedge MCLK)
	begin
		if (clk)
			dl79_outp <= w411;
	end
	assign l79 = dl79_outp;
	
	assign w516 = ~clk & ~l79;
	
	assign w517 = ~clk & ~w416;
	
	assign w518 = ~w417;
	assign w519 = ~w418;
	
	always @(posedge MCLK)
	begin
		if (clk)
			w522 <= w522;
		else if (w334)
			w522 <= w520;
	end
	
	assign w525 = w210 ? w522[14:0] : ~w522[14:0];
	
	wire [15:0] cla;
	
	assign cla[0] = ~w193;
	assign cla[1] = ~w193 & ~w525[0];
	assign cla[2] = ~w193 & ~w525[0] & ~w525[1];
	assign cla[3] = ~w525[2] & cla[2];
	assign cla[4] = ~w525[3] & ~w525[2] & cla[2];
	assign cla[5] = ~w525[4] & cla[4];
	assign cla[6] = ~w525[5] & ~w525[4] & cla[4];
	assign cla[7] = ~w525[6] & ~w525[5] & ~w525[4] & ~w525[3] & ~w525[2]
		& ~w525[1] & ~w525[0] & ~w193 & ~w321;
	assign cla[8] = ~w525[7] & cla[7];
	assign cla[9] = ~w525[8] & ~w525[7] & cla[7];
	assign cla[10] = ~w525[9] & cla[9];
	assign cla[11] = ~w525[10] & ~w525[9] & cla[9];
	assign cla[12] = ~w525[11] & ~w525[10] & ~w525[9] & ~w525[8] & ~w525[7] & cla[7];
	assign cla[13] = ~w525[12] & cla[12];
	assign cla[14] = ~w525[13] & ~w525[12] & cla[12];
	assign cla[15] = ~w525[14] & ~w525[13] & ~w525[12] & cla[12];
	
	assign w523 = ~(cla ^ w522);
	
	always @(posedge MCLK)
	begin
		if (clk & w210)
			w524 <= w522 != 16'h1;
	end
	
	always @(posedge MCLK)
	begin
		if (w194)
		begin
			if (clk)
				w526 <= ~w522;
		end
		else
			w526 <= w526;
	end
	
	assign ADDRESS = ~w526;
	assign ADDRESS_z = w323;
	
	always @(posedge MCLK)
	begin
		if (w339)
			w527 <= w523;
	end
	
	assign w528 = w215 ? 16'h0 : ~w527;

	always @(posedge MCLK)
	begin
		if (~w364)
		begin
			regs[0][0] <= ~(rpull1_comb[0] | regs[0][1]);
			regs[0][1] <= ~(rpull1_comb[1] | regs[0][0]);
		end
		if (~w363)
		begin
			regs[1][0] <= ~(rpull1_comb[0] | regs[1][1]);
			regs[1][1] <= ~(rpull1_comb[1] | regs[1][0]);
		end
		if (~w355)
		begin
			regs[2][0] <= ~(rpull1_comb[0] | regs[2][1]);
			regs[2][1] <= ~(rpull1_comb[1] | regs[2][0]);
		end
		if (~w354)
		begin
			regs[3][0] <= ~(rpull1_comb[0] | regs[3][1]);
			regs[3][1] <= ~(rpull1_comb[1] | regs[3][0]);
		end
		if (~w353)
		begin
			regs[4][0] <= ~(rpull1_comb[0] | regs[4][1]);
			regs[4][1] <= ~(rpull1_comb[1] | regs[4][0]);
		end
		if (~w352)
		begin
			regs[5][0] <= ~(rpull1_comb[0] | regs[5][1]);
			regs[5][1] <= ~(rpull1_comb[1] | regs[5][0]);
		end
		if (~w350)
		begin
			regs[6][0] <= ~(rpull1_comb[0] | regs[6][1]);
			regs[6][1] <= ~(rpull1_comb[1] | regs[6][0]);
		end
		if (~w348)
		begin
			regs[7][0] <= ~(rpull1_comb[0] | regs[7][1]);
			regs[7][1] <= ~(rpull1_comb[1] | regs[7][0]);
		end
		if (~w342)
		begin
			regs[8][0] <= ~(rpull1_comb[0] | regs[8][1]);
			regs[8][1] <= ~(rpull1_comb[1] | regs[8][0]);
		end
		if (~w340)
		begin
			regs[9][0] <= ~(rpull1_comb[0] | regs[9][1]);
			regs[9][1] <= ~(rpull1_comb[1] | regs[9][0]);
		end
		if (~w319)
		begin
			regs[10][0] <= ~(rpull1_comb[0] | regs[10][1]);
			regs[10][1] <= ~(rpull1_comb[1] | regs[10][0]);
		end
		if (~w314)
		begin
			regs[11][0] <= ~(rpull1_comb[0] | regs[11][1]);
			regs[11][1] <= ~(rpull1_comb[1] | regs[11][0]);
		end
	end

	always @(posedge MCLK)
	begin
		if (w336)
		begin
			regs2[0][0] <= ~(rpull2_comb[0] | regs2[0][1]);
			regs2[0][1] <= ~(rpull2_comb[1] | regs2[0][0]);
		end
		if (w337)
		begin
			regs2[1][0] <= ~(rpull2_comb[0] | regs2[1][1]);
			regs2[1][1] <= ~(rpull2_comb[1] | regs2[1][0]);
		end
	end
	
	assign DATA_o = ~w145;
	assign DATA_z = w44;
	
	// z80_rs_trig_nor haltrs(.MCLK(MCLK), .rst(w11 & w16), .set(w19 | w18 | w55 | ~w57), .q(halt_i), .nq());
	reg haltrs_q = 1'h0, haltrs_nq = 1'h1;
	wire haltrs_qn = ~((w11 & w16) | haltrs_nq);
	always @(posedge MCLK)
	begin
		haltrs_q <= haltrs_qn;
		haltrs_nq <= ~((w19 | w18 | w55 | ~w57) | haltrs_qn);
	end
	assign halt_i = haltrs_q;
	
	assign halt = ~halt_i;
	
	assign HALT = ~halt;
	
	// z80_rs_trig_nor m1rs(.MCLK(MCLK), .rst(clk & (w41 | w113)), .set(clk & w131 & w110), .q(m1), .nq());
	reg m1rs_q = 1'h0, m1rs_nq = 1'h1;
	wire m1rs_qn = ~((clk & (w41 | w113)) | m1rs_nq);
	always @(posedge MCLK)
	begin
		m1rs_q <= m1rs_qn;
		m1rs_nq <= ~((clk & w131 & w110) | m1rs_qn);
	end
	assign m1 = m1rs_q;
	
	assign M1 = ~m1;
	
	// bus logic
	
	wire [7:0] bus1_pulld = {8{w1}} & ~w145;
	wire [7:0] bus1_pullu = ({8{w1}} & w145) | {8{w483}};
	
	wire [7:0] bcd_val = { 1'b1, ~w443, ~w443, 2'b11, ~w444, ~w444, 1'b1 }; 
	wire [7:0] status_val = { ~w450, ~w486, 1'b0, ~w476, 1'b0, ~w441, ~w481, ~w473 };
	
	wire [7:0] status_mask = { w381, w381, 1'b0, w381, 1'b0, w381, w381, w381 };
	
	wire [7:0] bus2_pulld = ({8{w370}} & ~bcd_val) | (status_mask & ~status_val) | ({8{~w518}} & ~w515[7:0]);
	wire [7:0] bus2_pullu = ({8{w370}} & bcd_val) | (status_mask & status_val) | ({8{~w518}} & w515[7:0]);
	
	wire [7:0] bus3_pulld = ({8{~w519}} & ~w515[15:8]) | ({8{~w402}} & w496);
	wire [7:0] bus3_pullu = ({8{~w519}} & w515[15:8]) | ({8{~w402}} & ~w496);
	
	wire [7:0] bus_pulld_comb_123 = bus1_pulld | bus2_pulld | bus3_pulld;
	wire [7:0] bus_pullu_comb_123 = bus1_pullu | bus2_pullu | bus3_pullu;
	
	wire [7:0] bus_pulld_comb_12 = bus1_pulld | bus2_pulld;
	wire [7:0] bus_pullu_comb_12 = bus1_pullu | bus2_pullu;
	
	wire [7:0] bus_pulld_comb_23 = bus2_pulld | bus3_pulld;
	wire [7:0] bus_pullu_comb_23 = bus2_pullu | bus3_pullu;
	
	wire [7:0] bus_comb_123 = ((w146 & w484 & w513) | bus_pullu_comb_123) & ~bus_pulld_comb_123;
	wire [7:0] bus_comb_12 = ((w146 & w484) | bus_pullu_comb_12) & ~bus_pulld_comb_12;
	wire [7:0] bus_comb_23 = ((w484 & w513) | bus_pullu_comb_23) & ~bus_pulld_comb_23;
	
	wire [7:0] bus_comb_1 = (w146 | bus1_pullu) & ~bus1_pulld;
	wire [7:0] bus_comb_2 = (w484 | bus2_pullu) & ~bus2_pulld;
	wire [7:0] bus_comb_3 = (w513 | bus3_pullu) & ~bus3_pulld;

	
	always @(posedge MCLK)
	begin
		if (w369 & w419)
		begin
			w146 <= bus_comb_123;
			w484 <= bus_comb_123;
			w513 <= bus_comb_123;
		end
		else if (w369)
		begin
			w146 <= bus_comb_12;
			w484 <= bus_comb_12;
			w513 <= bus_comb_3;
		end
		else if (w419)
		begin
			w146 <= bus_comb_1;
			w484 <= bus_comb_23;
			w513 <= bus_comb_23;
		end
		else
		begin
			w146 <= bus_comb_1;
			w484 <= bus_comb_2;
			w513 <= bus_comb_3;
		end
	end
	
	integer i;
	initial begin
		for (i = 0; i < 12; i = i + 1)
		begin
			regs[i][0] = 16'h0000;
			regs[i][1] = 16'hffff;
		end
		for (i = 0; i < 2; i = i + 1)
		begin
			regs2[i][0] = 16'h0000;
			regs2[i][1] = 16'hffff;
		end
	end
	
endmodule
