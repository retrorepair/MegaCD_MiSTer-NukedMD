//============================================================================
//  Mega CD cartridge slot on the NukedMD cartridge connector
//
//  Two devices can sit in the slot of a Mega CD system:
//   * a ROM cartridge (cart.rom) - pulls /CART low, so the FC1004 maps it at
//     000000-3FFFFF (/CE0) and the Mega CD BIOS moves to 400000. Supports the
//     SSF2-style bank registers at A130Fx for >4MB images and the Pier Solar
//     cartridge (bank registers, STM95 EEPROM, anti-piracy check).
//   * the backup RAM cartridge - leaves /CART open, so /CE0 covers 400000-7FFFFF:
//       400000-5FFFFF  RAM cart ID (size code, 255 = no RAM)
//       600000-6FFFFF  RAM (odd bytes), stored in SDRAM
//       700000-7FFFFF  write protect register
//
//  The FC1004 arbiter acknowledges every /CE0 access itself after a fixed
//  delay (as the real chip does), so the cartridge has to return data inside
//  the 68000 bus cycle: the SDRAM read is started on the read strobe and the
//  data is placed on the bus as soon as it arrives (same scheme as the
//  MegaDrive core's cartridge.sv).
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
	input             clk,          // SDRAM controller clock (107 MHz)
	input             reset,

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
	input             rom_mode,     // cart.rom loaded: ROM cartridge at /CE0
	input             ram_cart_en,  // backup RAM cartridge present (rom_mode = 0 only)
	input     [23:13] rom_mask,
	input             pier_quirk,

	// dedicated SDRAM port (busy-style, request is a level)
	output     [24:1] mem_addr,
	output            mem_rd,
	output            mem_wrl,
	output     [15:0] mem_din,
	input      [15:0] mem_dout,
	input             mem_busy,

	output            ram_wr,       // backup RAM cartridge written

	// Pier Solar STM95 EEPROM
	output reg        ep_cs,
	output reg        ep_hold,
	output reg        ep_sck,
	output reg        ep_si,
	input             m95_so
);

//---------------------- address decode --------------------------------

// backup RAM cartridge regions inside /CE0 (400000-7FFFFF when /CART = 1)
wire ram_id_sel = ~rom_mode & cart_cs & ~cart_addr[21];                    // 400000-5FFFFF
wire ram_mem_sel = ~rom_mode & cart_cs & (cart_addr[21:20] == 2'b10);       // 600000-6FFFFF
wire ram_wp_sel  = ~rom_mode & cart_cs & (cart_addr[21:20] == 2'b11);       // 700000-7FFFFF

wire rom_sel = rom_mode & cart_cs;                                          // 000000-3FFFFF

wire pier_eeprom_cs = pier_quirk & cart_time & (cart_addr[3:1] == 3'd5);
wire pier_prot_cs   = pier_quirk & cart_cs & (cart_addr == 23'hAF3 || cart_addr == 23'hAF4); // byte 15E6/15E8

//---------------------- ROM cartridge mapper --------------------------

reg [4:0] bank_reg[8];
wire [23:1] rom_va = {bank_reg[cart_addr[21:19]], cart_addr[18:1]} & {rom_mask, 12'hFFF};

reg old_time_wr;
always @(posedge clk) begin
	old_time_wr <= cart_lwr & cart_time;

	if(reset) begin
		bank_reg <= '{0,1,2,3,4,5,6,7};
		{ep_cs, ep_hold, ep_sck, ep_si} <= 4'b1111;
	end
	else if(cart_lwr & cart_time & ~old_time_wr) begin
		if(pier_quirk) begin
			if(cart_addr[3:1] == 3'd4)                       {ep_cs, ep_hold, ep_sck, ep_si} <= cart_data_wr[3:0]; // Pier EEPROM
			else if(cart_addr[3:1] != 0 && ~cart_addr[3])    bank_reg[{1'b1, cart_addr[2:1]}] <= {1'b0, cart_data_wr[3:0]}; // Pier banks
		end
		else if(rom_mask[23:22]) begin // >4MB
			if(cart_addr[3:1] != 0) bank_reg[cart_addr[3:1]] <= cart_data_wr[4:0];
		end
	end
end

// Pier Solar anti-piracy check (same responses as the MegaDrive core)
reg [15:0] pier_prot_data;
reg        old_oe;
always @(posedge clk) begin
	reg [3:0] pier_count;

	old_oe <= cart_oe;

	if(reset) pier_count <= 0;
	else if(pier_prot_cs & ~old_oe & cart_oe) begin
		if (pier_count < 6) begin
			pier_count <= pier_count + 1'h1;
			pier_prot_data <= cart_addr[1] ? 16'h0000 : 16'h0010;
		end else begin
			pier_prot_data <= cart_addr[1] ? 16'h0001 : 16'h8010;
		end
	end
end

//---------------------- backup RAM cartridge --------------------------

reg [7:0] ram_wp;
always @(posedge clk) begin
	if(reset) ram_wp <= 8'hFF;
	else if(ram_wp_sel & cart_lwr) ram_wp <= cart_data_wr[7:0];
end

wire [7:0] ram_id = ram_cart_en ? 8'd6 : 8'd255; // size = (1<<n)*8192 bytes, 255 = not present

//---------------------- SDRAM access ----------------------------------

// read request: a level for the duration of the read strobe, captured once by the controller
wire rd_req = cart_oe & (rom_sel | ram_mem_sel);
// write request: RAM cartridge, odd bytes only, when not write protected
wire wr_req = cart_lwr & ram_mem_sel & ram_wp[0];

assign mem_addr = rom_sel ? {2'b00, rom_va[22:1]} : {5'b01110, cart_addr[19:1]}; // ROM at 000000, RAM cart at E00000
assign mem_rd   = rd_req;
assign mem_wrl  = wr_req;
assign mem_din  = cart_data_wr;

assign ram_wr = wr_req; // level: edge-detected by the save logic in the slower clock domain

reg rd_pending;
always @(posedge clk) begin
	reg old_rd, old_busy;

	old_rd   <= rd_req;
	old_busy <= mem_busy;

	if(~old_rd & rd_req) rd_pending <= 1;

	if(old_busy & ~mem_busy & rd_pending) begin
		rd_pending <= 0;
		cart_data <= rom_mode ? mem_dout : {8'hFF, mem_dout[7:0]};
	end

	// immediate responders override the SDRAM data
	if(ram_id_sel)     cart_data <= {8'hFF, ram_id};
	if(ram_wp_sel)     cart_data <= {8'hFF, ram_wp};
	if(pier_prot_cs)   cart_data <= pier_prot_data;
	if(pier_eeprom_cs) cart_data <= {15'h7FFF, m95_so};
end

assign cart_data_en = cart_oe & (cart_cs | pier_eeprom_cs);

endmodule
