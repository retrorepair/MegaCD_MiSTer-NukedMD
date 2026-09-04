//============================================================================
//  Mega CD cartridge slot on the NukedMD cartridge connector
//
//  Two kinds of device can sit in the slot of a Mega CD system:
//   * a Mega Drive cartridge (OSD "Insert Cartridge" or cart.rom next to a CD) - pulls
//     /CART low, so the FC1004 maps it at 000000-3FFFFF (/CE0) and the Mega CD moves to
//     400000. Mappers as in the MegaDrive core's cartridge.sv: SSF2 banks, SRAM, 24Cxx
//     EEPROM, Pier Solar (banks, STM95 EEPROM, anti-piracy check), Realtec, SF-001/2/4,
//     J-Cart, Sega Channel RAM, per-game lightgun / YM2612 quirks. No SVP (no block RAM
//     left next to the Mega CD).
//   * the backup RAM cartridge - leaves /CART open, so /CE0 covers 400000-7FFFFF:
//       400000-5FFFFF  RAM cart ID (size code, 255 = no RAM)
//       600000-6FFFFF  RAM (odd bytes)
//       700000-7FFFFF  write protect register
//
//  Storage: ROM at SDRAM 000000-DFFFFF; cartridge SRAM / SF SRAM / backup RAM cart as one
//  byte per word at SDRAM E00000 (the region the save file covers); EEPROM contents in the
//  Mega CD backup RAM block (eep_* port), which the save file covers as well.
//
//  The FC1004 arbiter acknowledges every /CE0 access itself after a fixed delay (as the
//  real chip does), so the cartridge has to return data inside the 68000 bus cycle: the
//  SDRAM read is started on the read strobe and the data is placed on the bus as soon as
//  it arrives (same scheme as cartridge.sv).
//
//  Derived from CART.vhd/MegaCD.sv (fpgagen era) and cartridge.sv
//  Copyright (c) 2023 Alexey Melnikov
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module mcd_cart
(
	input             clk,          // SDRAM controller clock (107 MHz): bus response
	input             clk_sys,      // 53.69 MHz: mappers, download parsing, EEPROM models
	input             reset,

	// cartridge download (parsed for size / quirks; the data itself goes to SDRAM via the top)
	input             cart_dl,
	input      [24:0] cart_dl_addr,
	input      [15:0] cart_dl_data,
	input             cart_dl_wr,

	// NukedMD cartridge connector
	input      [23:1] cart_addr,
	input      [15:0] cart_data_wr,
	input             cart_cs,      // /CE0 (active high)
	input             cart_oe,      // read strobe (vdp_dma_oe_early: early enough for VDP DMA)
	input             cart_lwr,
	input             cart_uwr,
	input             cart_time,    // /TIME (A130xx)
	output reg [15:0] cart_data,
	output            cart_data_en,

	// configuration
	input             rom_mode,     // a ROM cartridge is inserted
	input             ram_cart_en,  // backup RAM cartridge present (rom_mode = 0 only)

	// dedicated SDRAM port (busy-style, request is a level)
	output reg [24:1] mem_addr,
	output            mem_rd,
	output            mem_wrl,
	output            mem_wrh,
	output reg [15:0] mem_din,
	input      [15:0] mem_dout,
	input             mem_busy,

	// EEPROM storage: the Mega CD backup RAM block, lent to the cartridge while eep_sel
	output            eep_sel,
	output     [12:0] eep_addr,
	output      [7:0] eep_di,
	output            eep_we,
	input       [7:0] eep_q,

	output            ram_wr,       // battery backed content changed (save pending)
	output            clearing,     // SRAM clear sweep after a download still running (hold the 68000 in reset)

	// J-Cart
	input             jcart_en,
	input      [15:0] jcart_data,
	output reg        jcart_th,

	// per-game quirks
	output reg        gun_type,
	output reg  [7:0] gun_sensor_delay,
	output            ym2612_quirk,
	output            pier_quirk_o
);

//---------------------- cart detect (download stream, clk_sys) ---------------------------

reg [24:1] rom_mask;
reg [25:1] rom_sz;
reg        sram00_quirk, fmbusy_quirk, noram_quirk, pier_quirk, schan_quirk;
reg  [3:0] eeprom_quirk;
reg        realtec_quirk;
reg  [2:0] sf_quirk;
reg  [3:0] chk_quirk;
reg        mapper_reset;

assign ym2612_quirk = fmbusy_quirk;
assign pier_quirk_o = pier_quirk;

always @(posedge clk_sys) begin
	reg [87:0] cart_id;
	reg [15:0] crc = 0;
	reg [15:0] crc_real = 0;
	reg [31:0] realtec_id = 0;
	reg [31:0] sp = 0;
	reg old_dl;
	old_dl <= cart_dl;

	mapper_reset <= 0;
	if(~old_dl && cart_dl) begin
		rom_mask <= 0;
		rom_sz <= 0;
		{sram00_quirk,fmbusy_quirk,noram_quirk,pier_quirk,schan_quirk,eeprom_quirk,realtec_quirk,sf_quirk,chk_quirk} <= '0;
		gun_type <= 0;
		gun_sensor_delay <= 8'd44;
		crc_real <= 0;
		crc <= 0;
		mapper_reset <= 1;
	end

	if(cart_dl & cart_dl_wr) begin
		rom_mask <= rom_mask | cart_dl_addr[24:1];
		rom_sz <= cart_dl_addr[24:1] + 1'd1;

		if(cart_dl_addr == 'h000) sp[31:16] <= {cart_dl_data[7:0],cart_dl_data[15:8]};
		if(cart_dl_addr == 'h002) sp[15:00] <= {cart_dl_data[7:0],cart_dl_data[15:8]};
		if(cart_dl_addr == 'h180) cart_id[87:72] <= {cart_dl_data[7:0],cart_dl_data[15:8]};
		if(cart_dl_addr == 'h182) cart_id[71:56] <= {cart_dl_data[7:0],cart_dl_data[15:8]};
		if(cart_dl_addr == 'h184) cart_id[55:40] <= {cart_dl_data[7:0],cart_dl_data[15:8]};
		if(cart_dl_addr == 'h186) cart_id[39:24] <= {cart_dl_data[7:0],cart_dl_data[15:8]};
		if(cart_dl_addr == 'h188) cart_id[23:08] <= {cart_dl_data[7:0],cart_dl_data[15:8]};
		if(cart_dl_addr == 'h18A) cart_id[07:00] <= cart_dl_data[7:0];
		if(cart_dl_addr == 'h18E) crc <= {cart_dl_data[7:0],cart_dl_data[15:8]};
		if(cart_dl_addr == 'h190) begin
			     if(cart_id[63:0] == "T-50446 ") eeprom_quirk <= 4'b0001;  // X24C01 John Madden Football 93
			else if(cart_id[63:0] == "T-50516 ") eeprom_quirk <= 4'b0001;  // X24C01 John Madden Football 93 Championship Edition
			else if(cart_id[63:0] == "T-50396 ") eeprom_quirk <= 4'b0001;  // X24C01 NHLPA Hockey 93
			else if(cart_id[63:0] == "T-50176 ") eeprom_quirk <= 4'b0001;  // X24C01 Rings of Power
			else if(cart_id[63:0] == "T-50606 ") eeprom_quirk <= 4'b0001;  // X24C01 Bill Walsh College Football
			else if(cart_id[63:0] == "MK-1215 ") eeprom_quirk <= 4'b0010;  // X24C01 Evander Real Deal Holyfield's Boxing
			else if(cart_id[63:0] == "G-4060  ") eeprom_quirk <= 4'b0010;  // X24C01 Wonder Boy
			else if(cart_id[63:0] == "00001211") eeprom_quirk <= 4'b0010;  // X24C01 Sports Talk Baseball
			else if(cart_id[63:0] == "MK-1228 ") eeprom_quirk <= 4'b0010;  // X24C01 Greatest Heavyweights
			else if(cart_id[63:0] == "G-5538  ") eeprom_quirk <= 4'b0010;  // X24C01 Greatest Heavyweights JP
			else if(cart_id[63:0] == "PR-1993 ") eeprom_quirk <= 4'b0010;  // X24C01 Greatest Heavyweights (prototype)
			else if(cart_id[63:0] == "00004076") eeprom_quirk <= 4'b0010;  // X24C01 Honoo no Toukyuuji Dodge Danpei
			else if(cart_id[63:0] == "T-12046 ") eeprom_quirk <= 4'b0010;  // X24C01 Mega Man - The Wily Wars
			else if(cart_id[63:0] == "T-12053 ") eeprom_quirk <= 4'b0010;  // X24C01 Rockman Mega World
			else if(cart_id[63:0] == "G-4524  ") eeprom_quirk <= 4'b0010;  // X24C01 Ninja Burai Densetsu
			else if(cart_id[63:0] == "00054503") eeprom_quirk <= 4'b0010;  // X24C01 Game Toshokan
			else if(cart_id[63:0] == "T-81033 ") eeprom_quirk <= 4'b0011;  // 24C02 NBA Jam (J)
			else if(cart_id[63:0] == "T-081326") eeprom_quirk <= 4'b0011;  // 24C02 NBA Jam (U)(E)
			else if(cart_id[63:0] == "T-081276") eeprom_quirk <= 4'b1011;  // 24C02 NFL Quarterback Club
			else if(cart_id[63:0] == "T-81406 ") eeprom_quirk <= 4'b1111;  // 24C04 NBA Jam TE
			else if(cart_id[63:0] == "T-081586") eeprom_quirk <= 4'b1100;  // 24C16 NFL Quarterback Club '96
			else if(cart_id[63:0] == "T-81576 ") eeprom_quirk <= 4'b1101;  // 24C65 College Slam
			else if(cart_id[63:0] == "T-81476 ") eeprom_quirk <= 4'b1101;  // 24C65 Frank Thomas Big Hurt Baseball
			else if(cart_id[63:0] == "T-120106") eeprom_quirk <= 4'b0110;  // 24C08 Brian Lara Cricket
			else if(sp=="DNLD" && crc == 'h168B) eeprom_quirk <= 4'b0110;  // 24C08 JCART Micro Machines Military
			else if(sp=="DNLD" && crc == 'h165E) eeprom_quirk <= 4'b0100;  // 24C16 JCART Micro Machines Turbo Tournament 96
			else if(cart_id[63:0] == "T-120096") eeprom_quirk <= 4'b0100;  // 24C16 JCART Micro Machines 2 - Turbo Tournament
			else if(cart_id[63:0] == "T-120146") eeprom_quirk <= 4'b0101;  // 24C65 Brian Lara Cricket 96 / Shane Warne Cricket

			else if(cart_id[63:0] == "T-113016") noram_quirk  <= 1;        // Puggsy fake ram check
			else if(cart_id[63:0] == "T-574023") pier_quirk   <= 1;        // Pier Solar Reprint
			else if(cart_id[63:0] == "T-574013") pier_quirk   <= 1;        // Pier Solar 1st Edition
			else if(cart_id[63:0] == "T-35036 ") fmbusy_quirk <= 1;        // Hellfire US
			else if(cart_id[63:0] == "T-25073 ") fmbusy_quirk <= 1;        // Hellfire JP
			else if(cart_id[63:0] == "MK-1137-") fmbusy_quirk <= 1;        // Hellfire EU
			else if(cart_id[63:0] == "G-4034  ") fmbusy_quirk <= 1;        // DAISENPU/TWIN HAWK JP/EU
			else if(cart_id[63:0] == "T-44016 ") fmbusy_quirk <= 1;        // Tecmo World Cup
			else if(cart_id[63:0] == "T-44023 ") fmbusy_quirk <= 1;        // Tecmo World Cup JP
			else if(cart_id[63:0] == "T-68???-") schan_quirk  <= 1;        // Game no Kanzume Otokuyou
			else if(cart_id[63:0] == " GM 0000") sram00_quirk <= 1;        // Sonic 1 Remastered
			else if(cart_id[87:40] == "SF-001")  sf_quirk     <= {crc == 16'h3E08,2'b01}; // Beggar Prince (Unl), Beggar Prince rev 1 (Unl)
			else if(cart_id[87:40] == "SF-002")  sf_quirk     <= {1'b1,2'b10}; // Legend of Wukong (Unl)
			else if(cart_id[87:40] == "SF-004")  sf_quirk     <= {1'b1,2'b11}; // Star Odyssey (Unl)

			// Lightgun device and timing offsets
			if(cart_id[63:0] == "MK-1533 ") begin						  // Body Count
				gun_type  <= 0;
				gun_sensor_delay <= 8'd100;
			end
			else if(cart_id[63:0] == "T-95096-") begin				  // Lethal Enforcers
				gun_type  <= 1;
				gun_sensor_delay <= 8'd52;
			end
			else if(cart_id[63:0] == "T-95136-") begin				  // Lethal Enforcers II
				gun_type  <= 1;
				gun_sensor_delay <= 8'd30;
			end
			else if(cart_id[63:0] == "MK-1658 ") begin				  // Menacer 6-in-1
				gun_type  <= 0;
				gun_sensor_delay <= 8'd120;
			end
			else if(cart_id[63:0] == "T-081156") begin				  // T2: The Arcade Game
				gun_type  <= 0;
				gun_sensor_delay <= 8'd126;
			end
		end

		if(cart_dl_addr == 'h7E100) realtec_id[31:16] <= {cart_dl_data[7:0],cart_dl_data[15:8]};
		if(cart_dl_addr == 'h7E102) realtec_id[15: 0] <= {cart_dl_data[7:0],cart_dl_data[15:8]};
		if(cart_dl_addr == 'h7E104 && realtec_id == "SEGA") realtec_quirk <= 1; // Earth Defend, Funny World & Balloon Boy, Whac-a-Critter

		if(cart_dl_addr[24:9]) crc_real <= crc_real + {cart_dl_data[7:0],cart_dl_data[15:8]};

		if(sf_quirk || eeprom_quirk || pier_quirk) noram_quirk <= 1;
	end

	if(~cart_dl) begin
		if(crc == 'h0000 && crc_real == 'h7037) chk_quirk <= 1; // Ma Jiang Qing Ren - Ji Ma Jiang Zhi
		if(crc == 'h0000 && crc_real == 'h3b95) chk_quirk <= 1; // Super Majon Club
		if(crc == 'hffff && crc_real == 'h0474) chk_quirk <= 2; // Super Mario 2 1998
		if(crc == 'h2020 && crc_real == 'hb4eb) chk_quirk <= 3; // Super Mario World
	end
end

//---------------------- MD cart mappers (clk_sys) ------------------------------------

wire [23:0] md_addr = {cart_addr,1'b0};

reg [5:0] md_bank[8];
reg       md_bank_sram;
reg       md_bank_use;
reg       ep_si, ep_sck, ep_hold, ep_cs;

reg old_time_wr;
always @(posedge clk_sys) begin
	old_time_wr <= cart_lwr & cart_time;

	if(reset | mapper_reset) begin
		md_bank <= '{0,1,2,3,4,5,6,7};
		md_bank_sram <= 0;
		md_bank_use <= 0;
		{ep_cs, ep_hold, ep_sck, ep_si} <= 4'b1111;
	end
	else if(cart_lwr & cart_time & ~old_time_wr) begin
		if(rom_mask[24:22]) begin
			if(cart_addr[3:1]) begin
				md_bank_use <= 1;
				if(~pier_quirk) md_bank[cart_addr[3:1]] <= cart_data_wr[5:0]; //SSF2 banks
				else if(cart_addr[3:1] == 4) {ep_cs, ep_hold , ep_sck, ep_si} <= cart_data_wr[3:0]; // Pier EEPROM
				else if(~cart_addr[3]) md_bank[{1'b1,cart_addr[2:1]}] <= {2'b00, cart_data_wr[3:0]}; // Pier Banks
			end
			else if(~pier_quirk) md_bank_sram <= cart_data_wr[0];
		end
		else if(~schan_quirk) md_bank_sram <= cart_data_wr[0];
	end
end

wire [24:1] md_cart_addr = realtec_quirk ? {1'b0, realtec_addr} :
                           sf_quirk      ? {1'b0, sf_rom_addr}  :
                           md_bank_use   ? {md_bank[cart_addr[21:19]], cart_addr[18:1]} :
                                           {1'b0, cart_addr};

// SRAM / EEPROM address decodes, registered: the address settles at least one VCLK (130 ns)
// before any strobe, so a 9.3 ns pipeline stage costs nothing and keeps the 24-bit compare
// out of the SDRAM request path.
reg md_sram_cs, md_eeprom_cs;
always @(posedge clk) begin
	md_sram_cs   <= rom_mode && (cart_addr[23:21] == 1) && (md_bank_sram || (cart_addr >= rom_sz && ~&cart_addr[20:19])) && ~noram_quirk;
	md_eeprom_cs <= rom_mode && ((eeprom_quirk[3:2] == 2'b01) ? (cart_addr[23:19] == 5'b00111) : (eeprom_quirk[2:0] && ((eeprom_bank & ~cart_addr[20]) || !eeprom_quirk[3]) && cart_addr[23:21] == 3'b001));
end
wire [15:0] md_eeprom_data;

always_comb begin
	md_eeprom_data = 0;
	casex(eeprom_quirk)
		4'b0001: md_eeprom_data[7] = eeprom_sda;
		4'b0010: md_eeprom_data[0] = eeprom_sda;
		4'b0011: md_eeprom_data[1] = eeprom_sda;
		4'b01xx: md_eeprom_data[7] = eeprom_sda;
		4'b1xxx: md_eeprom_data[0] = eeprom_sda;
		default:;
	endcase
end

reg         eeprom_sdai;
wire        eeprom_sdao;
reg         eeprom_scl;
wire [12:0] eeprom_ram_a;
wire  [7:0] eeprom_ram_d;
wire        eeprom_ram_we;
reg         eeprom_bank;
always @(posedge clk_sys) begin
	if(reset || !eeprom_quirk) begin
		eeprom_bank <= 0;
		eeprom_sdai <= 1;
		eeprom_scl  <= 1;
	end
	else if(cart_addr[23:21] == 3'b001 && cart_cs && (cart_lwr | cart_uwr)) begin
		casex (eeprom_quirk)
			4'b0001: if(cart_lwr) {eeprom_sdai,eeprom_scl} <= cart_data_wr[7:6];
			4'b0010: if(cart_lwr) {eeprom_scl,eeprom_sdai} <= cart_data_wr[1:0];
			4'b0011: if(cart_lwr) {eeprom_scl,eeprom_sdai} <= cart_data_wr[1:0];
			4'b01xx: if(cart_addr[20:19] == 2'b10) {eeprom_scl,eeprom_sdai} <= cart_data_wr[1:0];
			4'b1xxx:      if (~cart_addr[20] &  cart_lwr & ~cart_uwr) eeprom_sdai <= cart_data_wr[0];
						else if (~cart_addr[20] & ~cart_lwr &  cart_uwr) eeprom_scl  <= cart_data_wr[8];
						else if (~cart_addr[20] &  cart_lwr &  cart_uwr) eeprom_bank <= ~cart_data_wr[0];
		endcase
	end
end

wire eeprom_sda = {eeprom_sdao & eeprom_sdai};

//                                        C01     C01     C02     C16      C65       C08      C04
wire [12:0] eeprom_mask[8] = '{13'h00, 13'h7f, 13'h7f, 13'hff, 13'h7ff, 13'h1fff, 13'h3ff, 13'h1ff};

EPPROM_24CXX e24cxx
(
	.clk(clk_sys),
	.rst(reset),
	.en(1),

	.mode((eeprom_quirk[2:0] <= 3'b010) ? 2'd0 : (eeprom_quirk[2:0] == 3'b101) ? 2'd2 : 2'd1),
	.mask(eeprom_mask[eeprom_quirk[2:0]]),

	.sda_i(eeprom_sdai),
	.sda_o(eeprom_sdao),
	.scl(eeprom_scl),

	.ram_addr(eeprom_ram_a),
	.ram_d(eeprom_ram_d),
	.ram_wr(eeprom_ram_we),
	.ram_q(eep_q)
);

// PIER EEPROM
wire        m95_so;
wire  [7:0] m95_di;
wire [11:0] m95_addr;
wire        m95_rnw;

STM95XXX pier_eeprom
(
	.clk(clk_sys),
	.enable(pier_quirk),
	.so(m95_so),
	.si(ep_si),
	.sck(ep_sck),
	.hold_n(ep_hold),
	.cs_n(ep_cs),
	.wp_n(1'b1),
	.ram_addr(m95_addr),
	.ram_q(eep_q),
	.ram_di(m95_di),
	.ram_RnW(m95_rnw)
);

// EEPROM buffer (Mega CD backup RAM block) ownership; cleared to FF when a cart is loaded
reg [13:0] eep_clr;
always @(posedge clk_sys) begin
	if(mapper_reset) eep_clr <= 0;
	else if(~eep_clr[13]) eep_clr <= eep_clr + 1'd1;
end
wire eep_clearing = ~eep_clr[13];

assign eep_sel  = rom_mode & (pier_quirk | |eeprom_quirk | eep_clearing);
assign eep_addr = eep_clearing ? eep_clr[12:0] : pier_quirk ? {1'b0, m95_addr} : eeprom_ram_a;
assign eep_di   = eep_clearing ? 8'hFF : pier_quirk ? m95_di : eeprom_ram_d;
assign eep_we   = eep_clearing ? 1'b1 : pier_quirk ? m95_rnw : eeprom_ram_we;

wire pier_prot_cs = pier_quirk && (cart_addr == 'hAF3 || cart_addr == 'hAF4);
reg [15:0] pier_prot_data;

always @(posedge clk_sys) begin
	reg [3:0] pier_count;
	reg old_oe;

	old_oe <= cart_oe;

	if(reset | mapper_reset) pier_count <= 0;
	else if(pier_prot_cs & ~old_oe & cart_oe) begin
		if (pier_count < 6) begin
			pier_count <= pier_count + 1'h1;
			pier_prot_data <= cart_addr[1] ? 16'h0000 : 16'h0010;
		end else begin
			pier_prot_data <= cart_addr[1] ? 16'h0001 : 16'h8010;
		end
	end
end

wire pier_eeprom_cs = pier_quirk && cart_time && cart_addr[3:1] == 'h5;
wire [15:0] pier_eeprom_data = {15'h7FFF, m95_so};

// Sega Channel, 4MB RAM used as ROM
wire rom_we = rom_mode && schan_quirk && (cart_lwr || cart_uwr) && !cart_addr[23:22] && ~rom_prot;

reg rom_prot;
always @(posedge clk_sys) begin
	if(reset | mapper_reset) rom_prot <= 1;
	else if(schan_quirk && cart_lwr && cart_time && cart_addr[7:1] == 7'b1111000) rom_prot <= cart_data_wr[0];
end

//JCART multitap
wire   jcart_cs = rom_mode && jcart_en && (cart_addr == 'h1C7FFF || cart_addr == 'h1FFFFF) && cart_addr >= rom_sz;

always @(posedge clk_sys) begin
	if(reset) jcart_th <= 1;
	else if(cart_lwr & jcart_cs) jcart_th <= cart_data_wr[0];
end

// Realtec
reg [21:17] realtec_bank;
reg   [4:0] realtec_mask;
reg         realtec_boot;
always @(posedge clk_sys) begin
	if (reset | mapper_reset | ~realtec_quirk) begin
		realtec_bank <= 0;
		realtec_mask <= 0;
		realtec_boot <= 1;
	end
	else begin
		if (cart_addr[23:16] == 8'h40 && !cart_addr[11:1] && cart_uwr) begin
			case(cart_addr[15:12])
				4'h0: begin realtec_bank[21:20] <= cart_data_wr[2:1]; realtec_boot <= ~cart_data_wr[0]; end
				4'h2: begin
					case (cart_data_wr[5:0])
						6'd0,6'd1:                                      realtec_mask <= 5'b00000;
						6'd2:                                           realtec_mask <= 5'b00001;
						6'd3,6'd4:                                      realtec_mask <= 5'b00011;
						6'd5,6'd6,6'd7,6'd8:                            realtec_mask <= 5'b00111;
						6'd9,6'd10,6'd11,6'd12,6'd13,6'd14,6'd15,6'd16: realtec_mask <= 5'b01111;
						default:                                        realtec_mask <= 5'b11111;
					endcase
				end
				4'h4: begin realtec_bank[19:17] <= cart_data_wr[2:0]; end
			endcase
		end
	end
end

wire [23:1] realtec_addr = realtec_boot ? {11'b00000111111,cart_addr[12:1]} : {2'b00,(cart_addr[21:17] & realtec_mask) + realtec_bank,cart_addr[16:1]};

//SF-001,SF-002,SF-004 mappers
wire        sf_cs     = rom_mode && sf_quirk && (sf_sram_en | cart_time);

reg   [7:0] sf001_bank_reg;
reg   [7:0] sf002_bank_reg;
reg         sf004_sram_reg;
reg   [7:0] sf004_bank_reg;
reg   [2:0] sf004_first_page;

always @(posedge clk_sys) begin
	if(reset | mapper_reset || !sf_quirk) begin
		sf001_bank_reg <= 8'h00;
		sf002_bank_reg <= 8'h00;
		sf004_sram_reg <= 0;
		sf004_bank_reg <= 8'h80;
		sf004_first_page <= '0;
	end
	else if(cart_lwr && !cart_addr[23:16]) begin
		case(sf_quirk[1:0])
			//sf-001 new rev
			1: if(sf_quirk[2] && !sf001_bank_reg[5] && cart_addr[11:8] == 4'he) sf001_bank_reg <= cart_data_wr[7:0];
			//sf-002
			2: sf002_bank_reg <= cart_data_wr[7:0];
			//sf-004
			3: if (sf004_bank_reg[7]) begin
					case (cart_addr[11:8])
						4'hd: sf004_sram_reg <= cart_data_wr[7];
						4'he: sf004_bank_reg <= cart_data_wr[7:0];
						4'hf: sf004_first_page <= cart_data_wr[6:4];
					endcase
				end
		endcase
	end
end

wire [23:1] sf001_rom_a   = (sf001_bank_reg[7] && !cart_addr[21:18]) ? {6'b001110,cart_addr[17:1]} : {2'b00,cart_addr[21:1]};
wire        sf001_sram_en = (cart_addr[23:20] == 4 && !sf_quirk[2]) || (cart_addr[23:18] == 6'b001111 && sf001_bank_reg[7]);

wire [23:1] sf002_rom_a   = {2'b00,cart_addr[21] & ~sf002_bank_reg[7],cart_addr[20:1]};
wire        sf002_sram_en = (cart_addr[23:18] == 6'b001111);

wire [23:1] sf004_rom_a   = (cart_addr[23:16] < 8'h14 && sf004_bank_reg[6]) ? {3'b000,sf004_first_page + cart_addr[20:18],cart_addr[17:1]} : {3'b000,sf004_first_page,cart_addr[17:1]};
wire        sf004_sram_en = (cart_addr[23:20] == 2 && sf004_sram_reg);
wire [15:0] sf004_do      = {8'hff,1'b0,sf004_first_page,4'b0000};

wire        sf_sram_en    = sf_quirk[1:0] == 1 ? sf001_sram_en :
                            sf_quirk[1:0] == 2 ? sf002_sram_en :
                                                 sf004_sram_en;

wire [23:1] sf_rom_addr   = sf_quirk[1:0] == 1 ? sf001_rom_a :
                            sf_quirk[1:0] == 2 ? sf002_rom_a :
                                                 sf004_rom_a;

//Simple check
reg         chk_cs;
reg  [15:0] chk_data;

always @(posedge clk_sys) begin
	chk_cs <= 0;
	case(chk_quirk)
		1: if(md_addr == 'h400000) begin
				chk_data <= 'h9000;
				chk_cs <= 1;
			end
			else if(md_addr == 'h401000) begin
				chk_data <= 'hd300;
				chk_cs <= 1;
			end

		2: if(md_addr == 'hA13000) begin
				chk_data <= 'h0a;
				chk_cs <= 1;
			end

		3: if(md_addr == 'hA13000) begin
				chk_data <= 'h1c;
				chk_cs <= 1;
			end
	endcase
end

//---------------------- backup RAM cartridge --------------------------------------------

wire ram_id_sel  = ~rom_mode & cart_cs & ~cart_addr[21];                    // 400000-5FFFFF
wire ram_mem_sel = ~rom_mode & cart_cs & (cart_addr[21:20] == 2'b10);       // 600000-6FFFFF
wire ram_wp_sel  = ~rom_mode & cart_cs & (cart_addr[21:20] == 2'b11);       // 700000-7FFFFF

reg [7:0] ram_wp;
always @(posedge clk) begin
	if(reset) ram_wp <= 8'hFF;
	else if(ram_wp_sel & cart_lwr) ram_wp <= cart_data_wr[7:0];
end

wire [7:0] ram_id = ram_cart_en ? 8'd6 : 8'd255; // size = (1<<n)*8192 bytes, 255 = not present

//---------------------- SDRAM access (clk) ----------------------------------------------

// what is being accessed
wire rom_rd_sel  = rom_mode & cart_cs & ~md_sram_cs & ~md_eeprom_cs & ~(sf_quirk & sf_sram_en);
wire sram_rd_sel = md_sram_cs | (sf_quirk & sf_sram_en & rom_mode);

wire rd_req = cart_oe & (rom_rd_sel | sram_rd_sel | ram_mem_sel);

// SRAM byte address (one byte per SDRAM word at E00000)
wire [16:0] sram_a = sf_quirk ? {2'b00, cart_addr[15:1]} : {1'b0, cart_addr[16:1]};

wire sram_wr_req = cart_lwr & (md_sram_cs | (sf_quirk & sf_sram_en & rom_mode));
wire ramc_wr_req = cart_lwr & ram_mem_sel & ram_wp[0];

// SRAM clear (FF, or 00 for the Sonic 1 remaster) when a cartridge is loaded.
// The SDRAM controller accepts a request on its rising edge only, so every word is a
// separate pulse: raise the request, wait for the port to finish, drop it for a cycle.
reg [16:0] clr_addr;
reg        clr_run;
reg        clr_req;

always @(posedge clk) begin
	reg old_dl, old_busy;
	old_dl <= cart_dl;
	old_busy <= mem_busy;
	if(~old_dl & cart_dl) begin clr_run <= 1; clr_addr <= 0; clr_req <= 0; end
	else if(clr_run & ~cart_dl) begin
		if(~clr_req & ~mem_busy & ~old_busy) clr_req <= 1;       // issue the next word
		else if(clr_req & old_busy & ~mem_busy) begin             // accepted and completed
			clr_req <= 0;
			clr_addr <= clr_addr + 1'd1;
			if(&clr_addr) clr_run <= 0;
		end
	end
end

wire clr_wr = clr_run & ~cart_dl;
assign clearing = clr_run;

assign mem_rd  = rd_req & ~clr_wr;
assign mem_wrl = (clr_wr & clr_req) | sram_wr_req | ramc_wr_req | (rom_we & cart_lwr);
assign mem_wrh = rom_we & cart_uwr;

always_comb begin
	if(clr_wr) begin
		mem_addr = {5'b01110, 2'b00, clr_addr};
		mem_din  = sram00_quirk ? 16'h0000 : 16'h00FF;
	end
	else if(rom_we) begin
		mem_addr = {1'b0, cart_addr};
		mem_din  = cart_data_wr;
	end
	else if(sram_rd_sel | sram_wr_req) begin
		mem_addr = {5'b01110, 2'b00, sram_a};
		mem_din  = {8'h00, cart_data_wr[7:0]};
	end
	else if(ram_mem_sel) begin
		mem_addr = {5'b01110, cart_addr[19:1]};
		mem_din  = {8'h00, cart_data_wr[7:0]};
	end
	else begin
		mem_addr = md_cart_addr & rom_mask;
		mem_din  = cart_data_wr;
	end
end

assign ram_wr = (sram_wr_req | ramc_wr_req | eeprom_ram_we | (pier_quirk & m95_rnw)) & ~clr_wr;

reg       rd_pending;
reg [1:0] rd_kind; // 0 rom, 1 sram (byte in both halves), 2 sf sram / ram cart (FF:byte)
always @(posedge clk) begin
	reg old_rd, old_busy;

	old_rd   <= rd_req;
	old_busy <= mem_busy;

	if(~old_rd & rd_req) begin
		rd_pending <= 1;
		rd_kind <= md_sram_cs ? 2'd1 : (ram_mem_sel | (sf_quirk & sf_sram_en)) ? 2'd2 : 2'd0;
	end

	if(old_busy & ~mem_busy & rd_pending) begin
		rd_pending <= 0;
		case(rd_kind)
			2'd1:    cart_data <= {mem_dout[7:0], mem_dout[7:0]};
			2'd2:    cart_data <= {8'hFF, mem_dout[7:0]};
			default: cart_data <= mem_dout;
		endcase
	end

	// immediate responders override the SDRAM data
	if(ram_id_sel)     cart_data <= {8'hFF, ram_id};
	if(ram_wp_sel)     cart_data <= {8'hFF, ram_wp};
	if(md_eeprom_cs)   cart_data <= md_eeprom_data;
	if(pier_prot_cs)   cart_data <= pier_prot_data;
	if(pier_eeprom_cs) cart_data <= pier_eeprom_data;
	if(jcart_cs)       cart_data <= jcart_data;
	if(sf_cs & cart_time) cart_data <= (sf_quirk[1:0] == 2'd3) ? sf004_do : 16'h0000;
	if(chk_cs)         cart_data <= chk_data;
end

reg data_en;
always @(posedge clk) data_en <= pier_eeprom_cs | sf_cs | chk_cs | jcart_cs;

assign cart_data_en = cart_oe & (cart_cs | data_en);

endmodule
