//============================================================================
//  Sega Mega CD for MiSTer
//
//  Mega Drive side: NukedMD-FPGA (nukeykt, ogamespec, andkorzh) through the
//  MiSTer HAL by Alexey Melnikov (2023). The FC1004 expansion connector is
//  brought out of md_board and drives the Mega CD gate array directly.
//  Mega CD side: srg320's ASIC/CDC/PCM/CDDA implementation.
//
//  Copyright (c) 2017-2023 Sorgelig / Alexey Melnikov
//  Copyright (c) 2020-2023 srg320 (Mega CD)
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign BUTTONS   = {bk_reload, 1'b0};
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign LED_DISK  = {1'b1,MCD_LED_RED};
assign LED_POWER = {1'b1,MCD_LED_GREEN};
assign LED_USER  = rom_download | sav_pending;

assign VGA_SCALER= 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;
assign AUDIO_MIX = status[66:65];

// DDR3: bring-up telemetry only (mcd_debug)
assign DDRAM_CLK = clk_ram;

wire [1:0] ar = status[50:49];

wire       vcrop_en = status[32];
wire [3:0] vcopt    = status[54:51];
reg        en216p;
reg  [4:0] voff;
always @(posedge CLK_VIDEO) begin
	en216p <= ((HDMI_WIDTH == 1920) && (HDMI_HEIGHT == 1080) && !forced_scandoubler && !scale);
	voff <= (vcopt < 6) ? {vcopt,1'b0} : ({vcopt,1'b0} - 5'd24);
end

wire vga_de;
video_freak video_freak
(
	.*,
	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? arx : (ar - 1'd1)),
	.ARY((!ar) ? ary : 12'd0),
	.CROP_SIZE((en216p & vcrop_en) ? 10'd216 : 10'd0),
	.CROP_OFF(voff),
	.SCALE(status[56:55])
);

///////////////////////////////////////////////////
wire clk_sys, clk_ram, locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_ram),
	.outclk_1(clk_sys),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;
reg         cfg_write;
reg   [5:0] cfg_address;
reg  [31:0] cfg_data;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(cfg_write),
	.mgmt_address(cfg_address),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

always @(posedge CLK_50M) begin
	reg pald = 0, pald2 = 0;
	reg [2:0] state = 0;
	reg pal_r;

	pald <= PAL;
	pald2 <= pald;

	cfg_write <= 0;
	if(pald2 == pald && pald2 != pal_r) begin
		state <= 1;
		pal_r <= pald2;
	end

	if(!cfg_waitrequest) begin
		if(state) state<=state+1'd1;
		case(state)
			1: begin
					cfg_address <= 0;
					cfg_data <= 0;
					cfg_write <= 1;
				end
			5: begin
					cfg_address <= 7;
					cfg_data <= pal_r ? 2201376125 : 2537930535;
					cfg_write <= 1;
				end
			7: begin
					cfg_address <= 2;
					cfg_data <= 0;
					cfg_write <= 1;
				end
		endcase
	end
end

wire clk_md = clk_ram;   // NukedMD runs at 2x MCLK (107.38 MHz)
assign CLK_VIDEO = clk_ram;

///////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"MegaCD;;",
	"S0,CUECHD,Insert Disk;",
	"FS6,BINGENMD,Insert Cartridge;",
	"O[36],Disc Insert,Reset,Keep Running;",
	"d3O[9],TMSS,Disabled,Enabled;",
	"-;",
	"h6O[7:6],Region,Auto(JP),JP,US,EU;",
	"h7O[7:6],Region,Auto(US),JP,US,EU;",
	"h8O[7:6],Region,Auto(EU),JP,US,EU;",
	"-;",
	"C,Cheats;",
	"H5O[24],Cheats Enabled,Yes,No;",
	"-;",
	"O[3],Backup RAM,Internal,Internal+Cart;",
	"D0R[16],Reload Backup RAM;",
	"D0R[17],Save Backup RAM;",
	"D0O[13],Autosave,No,Yes;",
	"-;",

	"P1,Audio & Video;",
	"P1-;",
	"P1O[50:49],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[30],320x224 Aspect,Original,Corrected;",
	"P1O[35:33],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1-;",
	"d9P1O[32],Vertical Crop,Disabled,216p(5x);",
	"d9P1O[54:51],Crop Offset,0,2,4,8,10,12,-12,-10,-8,-6,-4,-2;",
	"P1O[56:55],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1- ;",
	"P1O[29],Border,No,Yes;",
	"P1O[47],Composite Blend,Off,On;",
	"P1O[10],CRAM Dots,Off,On;",
	"P1-;",
	"P1O[15:14],Audio Filter,Model 1,Model 2,Minimal,No Filter;",
	"P1O[27],CD Audio,Unfiltered,Filtered;",
	"P1O[58:57],Audio Boost,No,2x,4x;",
	"P1O[8],FM Chip,YM2612,YM3438;",
	"P1O[66:65],Stereo Mix,None,25%,50%,100%;",

	"P2,Input;",
	"P2-;",
	"P2O[4],Swap Joysticks,No,Yes;",
	"P2O[5],6 Buttons Mode,No,Yes;",
	"P2O[22:21],Multitap,Disabled,4-Way,TeamPlayer: Port1,TeamPlayer: Port2;",
	"P2O[31],J-Cart,Off,On;",
	"P2-;",
	"P2O[19:18],Mouse,None,Port1,Port2;",
	"P2O[20],Mouse Flip Y,No,Yes;",
	"P2-;",
	"P2O[62:61],Keyboard,None,Port1,Port2;",
	"P2-;",
	"P2O[41:40],Gun Control,Disabled,Joy1,Joy2,Mouse;",
	"D4P2O[42],Gun Fire,Joy,Mouse;",
	"D4P2O[44:43],Cross,Small,Medium,Big,None;",
	"D4P2O[45],Gun Type,Justifier,Menacer;",
	"P2-;",
	"P2O[64:63],SNAC,Off,Port 1,Port 2,Port 3;",

	"- ;",
	"O[60],Pause When OSD is Open,No,Yes;",
	"H2O[11],Enable FM,Yes,No;",
	"H2O[12],Enable PSG,Yes,No;",
	"H2O[25],Enable PCM,Yes,No;",
	"H2O[26],Enable CDDA,Yes,No;",
	"H2O[39],MCD RAM,Banks 2&3,Banks 0&1;",
	"H2-;",
	"R[0],Reset & Eject CD;",
	"J1,A,B,C,Start,Mode,X,Y,Z;",
	"jn,A,B,R,Start,Select,X,Y,L;", // name map to SNES layout.
	"jp,Y,B,A,Start,Select,L,X,R;", // positional map to SNES layout (3 button friendly)
	"V,v",`BUILD_DATE
};

reg tmss_enable = 0;  // TMSS option, latched at reset (logic further down)
reg tmss_loaded = 0;  // boot2.rom received: enables the OSD entry (menumask bit 3)
wire [15:0] status_menumask = {6'd0, en216p,region,!region,~gg_available,!gun_mode,tmss_loaded,~dbg_menu,1'b0,~bk_ena};
wire [127:0] status;
wire  [1:0] buttons;
wire [11:0] joystick_0,joystick_1,joystick_2,joystick_3,joystick_4;
wire  [7:0] joy0_x,joy0_y,joy1_x,joy1_y;
wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire [15:0] ioctl_data;
wire  [7:0] ioctl_index;
reg         ioctl_wait;

reg  [31:0] sd_lba[1];
reg         sd_rd = 0;
reg         sd_wr = 0;
wire        sd_ack;
wire  [7:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[1];
wire        sd_buff_wr;
wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;

wire        forced_scandoubler;
wire [10:0] ps2_key;
wire  [2:0] ps2_kbd_led_status;
wire  [2:0] ps2_kbd_led_use = 3'b111;
wire [24:0] ps2_mouse;

wire [21:0] gamma_bus;

wire [1:0] gun_mode = status[41:40];
wire       gun_btn_mode = status[42];
wire       gun_type = rom_cart_mode ? cart_gun_type : ~status[45];

assign sd_buff_din[0] = sd_lba[0][10:4] ? tmpram_sd_buff_data : bram_sd_buff_data;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),
	.joystick_4(joystick_4),
	.joystick_l_analog_0({joy0_y, joy0_x}),
	.joystick_l_analog_1({joy1_y, joy1_x}),
	.buttons(buttons),
	.forced_scandoubler(forced_scandoubler),
	.new_vmode(new_vmode),

	.status(status),
	.status_in({status[127:8],2'b00,status[5:0]}),
	.status_set(region_reset),
	.status_menumask(status_menumask),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_data),
	.ioctl_wait(ioctl_wait),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.gamma_bus(gamma_bus),

	.ps2_key(ps2_key),
	.ps2_kbd_led_status(ps2_kbd_led_status),
	.ps2_kbd_led_use(ps2_kbd_led_use),
	.ps2_mouse(ps2_mouse),

	.EXT_BUS(EXT_BUS)
);

wire [35:0] EXT_BUS;
hps_ext hps_ext
(
	.clk_sys(clk_sys),
	.EXT_BUS(EXT_BUS),

	.cd_data_ready(1),
	.cdda_ready(MCD_CDDA_WR_READY),

	.cd_in(cd_in),
	.cd_out(cd_out)
);

reg dbg_menu = 0;
always @(posedge clk_sys) begin
	reg old_stb;
	reg enter = 0;
	reg esc = 0;

	old_stb <= ps2_key[10];
	if(old_stb ^ ps2_key[10]) begin
		if(ps2_key[7:0] == 'h5A) enter <= ps2_key[9];
		if(ps2_key[7:0] == 'h76) esc   <= ps2_key[9];
	end

	if(enter & esc) begin
		dbg_menu <= ~dbg_menu;
		enter <= 0;
		esc <= 0;
	end
end

// Main sends boot.rom as index 00, cart.rom next to a CD as 40, boot2.rom (TMSS) as 80.
// "Disc Insert: Keep Running" (test aid): Main re-sends the BIOS and pulses status[0] on every image
// mount; with the option on, both are ignored once a BIOS is running, so a disc can be swapped
// without restarting the core (as on hardware, where the BIOS notices the new disc through the CDD).
// The OSD "Reset & Eject CD" is masked as well while it is on: use the main menu Reset instead.
wire cd_keep      = status[36];
reg  bios_loaded  = 0;
wire bios_dl_raw  = ioctl_download & (ioctl_index[7:6] == 2'b00) & (ioctl_index[5:0] <= 6'h01);
// Main's start-up sequence sends the BIOS, then resets the core (status[0] pulse) and sends the BIOS
// once more; the BIOS needs that restart to come up after Main's drive is initialised (with the
// pulse masked the JP BIOS stays on its intro clouds waiting for the drive). So the masking is armed
// only 3 s after the first BIOS load: it then covers disc mounts done while a BIOS is running.
reg [27:0] keep_arm_cnt = 0;
reg        keep_armed = 0;
wire keep_running = cd_keep & keep_armed;
wire bios_download = bios_dl_raw & ~keep_running;
wire host_reset    = status[0] & ~keep_running;
always @(posedge clk_sys) begin
	reg old_dl;
	old_dl <= bios_dl_raw;
	if(old_dl & ~bios_dl_raw) bios_loaded <= 1;
	if(bios_loaded & ~keep_armed) begin
		keep_arm_cnt <= keep_arm_cnt + 1'd1;
		if(keep_arm_cnt == 28'd161_000_000) keep_armed <= 1;   // 3 s at 53.7 MHz
	end
end
wire cart_download = ioctl_download & ((ioctl_index[5:0] == 6'h06) | ((ioctl_index[7:6] == 2'b01) & (ioctl_index[5:0] <= 6'h01))); // OSD "Insert Cartridge" or cart.rom next to the CD
wire tmss_download = ioctl_download & (ioctl_index == 8'h80);                                                                    // games/MegaCD/boot2.rom
wire rom_download  = bios_download | cart_download;
wire cdc_dat_download = ioctl_download & (ioctl_index[5:0] == 6'h02);
wire cdc_sub_download = ioctl_download & (ioctl_index[5:0] == 6'h03);
wire cdc_cdda_download = ioctl_download & (ioctl_index[5:0] == 6'h04);
wire save_download = ioctl_download & (ioctl_index[5:0] == 6'h05);
wire code_download = ioctl_download & &ioctl_index;

///////////////////////////////////////////////////
// Code loading for WIDE IO (16 bit)
reg [128:0] gg_code;
wire        gg_available = gg_available1 | gg_available2;

// Code layout:
// {clock bit, code flags,     32'b address, 32'b compare, 32'b replace}
//  128        127:96          95:64         63:32         31:0
// Integer values are in BIG endian byte order, so it up to the loader
// or generator of the code to re-arrange them correctly.

always_ff @(posedge clk_sys) begin
	gg_code[128] <= 0;

	if (code_download & ioctl_wr) begin
		case (ioctl_addr[3:0])
			0:  gg_code[111:96]  <= ioctl_data; // Flags Bottom Word
			2:  gg_code[127:112] <= ioctl_data; // Flags Top Word
			4:  gg_code[79:64]   <= ioctl_data; // Address Bottom Word
			6:  gg_code[95:80]   <= ioctl_data; // Address Top Word
			8:  gg_code[47:32]   <= ioctl_data; // Compare Bottom Word
			10: gg_code[63:48]   <= ioctl_data; // Compare top Word
			12: gg_code[15:0]    <= ioctl_data; // Replace Bottom Word
			14: begin
				 gg_code[31:16]   <= ioctl_data; // Replace Top Word
				 gg_code[128]     <= 1;      // Clock it in
			end
		endcase
	end
end

///////////////////////////////////////////////////
// Resets and clock enables (same scheme as the MegaDrive HAL)

wire reset   = host_reset | buttons[1] | region_set;
wire cart_clearing;
wire loading = rom_download | bk_loading | RESET | cart_clearing; // the cartridge SRAM clear (~15ms) outlasts the download; keep the 68000 in reset until it is done

reg        btn_reset;
reg        md_reset;
reg        s_reset;
reg [15:1] ram_rst_a;
always @(posedge clk_md) begin
	reg [4:0] cnt = 0;
	reg old_reset = 0;

	ram_rst_a <= ram_rst_a + 1'd1;
	if(&ram_rst_a & ~&cnt) cnt <= cnt + 1'd1;

	old_reset <= reset;
	if(loading | (~old_reset & reset)) cnt <= 0;

	s_reset <= (cnt < 3);

	if(loading)       md_reset <= 1;
	else if(cnt == 3) md_reset <= 0;

	if(~old_reset & reset) btn_reset <= 1;
	else if(&cnt)          btn_reset <= 0;
end

reg sys_reset;
always @(posedge clk_sys) begin
	reg [1:0] sreset;

	sreset <= {sreset[0], s_reset};
	if(!sreset) sys_reset <= 0;
	if(&sreset) sys_reset <= 1;
end

reg vclk_en, zclk_en, clk_en;
always @(posedge clk_md) begin
	reg old_vclk, old_zclk;

	clk_en <= ~rom_download;

	old_vclk <= VCLK;
	if(old_vclk & ~VCLK) vclk_en <= clk_en;

	old_zclk <= ZCLK;
	if(old_zclk & ~ZCLK) zclk_en <= clk_en;
end

always @(posedge clk_md) begin
	reg pause_req;

	pause_req <= OSD_STATUS & status[60];

	if(pause_req & ~md_reset & ~btn_reset & ~rom_download) begin
		dma_z80_req <= 1;
		if((dma_z80_ack | res_z80) & ~cart_dma) dma_68k_req <= 1;
	end
	else begin
		dma_68k_req <= 0;
		dma_z80_req <= 0;
	end
end

///////////////////////////////////////////////////
// Mega Drive (NukedMD)

wire        PAL = region[1];
wire        JAP = ~|region;

wire [23:1] cart_addr;
wire        cart_cs, cart_oe, cart_lwr, cart_uwr, cart_time, cart_dma, cart_cas2;
wire [15:0] cart_data_wr;
wire [15:0] cart_data;
wire        cart_data_en;

wire        exp_as, exp_uds, exp_lds, exp_rw, exp_asel, exp_rom, exp_ras2, exp_fdc, exp_fdwr, exp_vclk, exp_dtack;
wire        exp_m68k_reset, exp_m68k_halt;

// TMSS boot ROM (VA4+ Mega Drive): 2KB loaded from games/MegaCD/boot2.rom, same wiring as
// the MegaDrive core. Kept in MLABs: every M10K block is taken by the Mega CD and the VDP.
wire  [9:0] tmss_address;
reg  [15:0] tmss_data;
(* ramstyle = "MLAB" *) reg [15:0] tmss_rom[1024];
always @(posedge clk_sys) if(ioctl_wr & tmss_download & !ioctl_addr[24:11]) tmss_rom[ioctl_addr[10:1]] <= {ioctl_data[7:0],ioctl_data[15:8]};
always @(posedge clk_md) tmss_data <= tmss_rom[tmss_address];

always @(posedge clk_sys) begin
	if(ioctl_wr & tmss_download) tmss_loaded <= 1;
	if(sys_reset) tmss_enable <= status[9];
end

wire        vdp_hclk1;
wire        vdp_de_h;
wire        vdp_de_v;
wire        vdp_intfield;
wire        vdp_m2, vdp_m5, vdp_rs1;
wire  [7:0] r,g,b;
wire        hs, vs;

wire  [6:0] PA_d, PA_o, PB_d, PB_o, PC_d, PC_o;
wire  [6:0] PA_i, PB_i, PC_i;

wire  [8:0] MOL, MOR;
wire  [9:0] MOL_2612, MOR_2612;
wire [15:0] PSG;
wire        fm_clk1;
wire        fm_sel23;

wire [14:0] ram_68k_address;
wire  [1:0] ram_68k_byteena;
wire [15:0] ram_68k_data;
wire        ram_68k_wren;
wire [15:0] ram_68k_o;
wire [12:0] ram_z80_address;
wire  [7:0] ram_z80_data;
wire        ram_z80_wren;
wire  [7:0] ram_z80_o;

wire [23:1] m68k_addr;
wire [15:0] m68k_bus_do;

reg         dma_68k_req;
reg         dma_z80_req;
wire        dma_z80_ack;
wire        res_z80;

wire        VCLK, ZCLK;

wire EN_GEN_FM   = ~status[11] | ~dbg_menu;
wire EN_GEN_PSG  = ~status[12] | ~dbg_menu;
wire EN_MCD_PCM  = ~status[25] | ~dbg_menu;
wire EN_MCD_CDDA = ~status[26] | ~dbg_menu;
wire MCD_BANK23  = ~status[39] | ~dbg_menu;

md_board md_board
(
	.MCLK2(clk_md),

	.ext_reset(md_reset),
	.reset_button(btn_reset), // edge triggered, requires some activity time to get detected.
	.ext_vres(1'b0),
	.ext_zres(1'b0),

	// ram
	.ram_68k_address(ram_68k_address),
	.ram_68k_byteena(ram_68k_byteena),
	.ram_68k_data(ram_68k_data),
	.ram_68k_wren(ram_68k_wren),
	.ram_68k_o(ram_68k_o),
	.ram_z80_address(ram_z80_address),
	.ram_z80_data(ram_z80_data),
	.ram_z80_wren(ram_z80_wren),
	.ram_z80_o(ram_z80_o),

	// cheat engine
	.m68k_addr(m68k_addr),
	.m68k_bus_do(m68k_bus_do),
	.m68k_di(m68k_data),

	// no TMSS in the Mega CD core (no ROM slot for it)
	.tmss_enable(tmss_enable & tmss_loaded),
	.tmss_data(tmss_data),
	.tmss_address(tmss_address),

	.ext_VCLK_o(VCLK),
	.ext_ZCLK_o(ZCLK),
	.ext_VCLK_i(VCLK & vclk_en),
	.ext_ZCLK_i(ZCLK & zclk_en),

	// cartridge slot
	.M3(1'b1),
	.cart_address(cart_addr),
	.cart_data(cart_data),
	.cart_data_en(cart_data_en),
	.cart_data_wr(cart_data_wr),
	.cart_cs(cart_cs),
	.vdp_dma_oe_early(cart_oe),
	.cart_lwr(cart_lwr),
	.cart_uwr(cart_uwr),
	.cart_time(cart_time),
	.cart_cas2(cart_cas2),
	.cart_m3_pause(1'b0),
	.vdp_dma(cart_dma),
	.ext_dtack(ext_dtack),
	.pal(PAL),
	.jap(JAP),

	// expansion connector (Mega CD)
	.ext_cart(~rom_cart_mode),   // a ROM cartridge grounds /CART; the RAM cartridge (or nothing) leaves it high
	.ext_disk(1'b0),             // Mega CD attached
	.exp_as(exp_as),
	.exp_uds(exp_uds),
	.exp_lds(exp_lds),
	.exp_rw(exp_rw),
	.exp_asel(exp_asel),
	.exp_rom(exp_rom),
	.exp_ras2(exp_ras2),
	.exp_fdc(exp_fdc),
	.exp_fdwr(exp_fdwr),
	.exp_vclk(exp_vclk),
	.exp_dtack(exp_dtack),
	.exp_m68k_reset(exp_m68k_reset),
	.exp_m68k_halt(exp_m68k_halt),
	.exp_data(mcd_do_r),
	.exp_data_en(exp_data_en),

	// video
	.V_R(r),
	.V_G(g),
	.V_B(b),
	.V_HS(hs),
	.vdp_vsync2(vs),

	// audio
	.MOL(MOL),
	.MOR(MOR),
	.MOL_2612(MOL_2612),
	.MOR_2612(MOR_2612),
	.PSG(PSG),
	.fm_clk1(fm_clk1),
	.fm_sel23(fm_sel23),

	// pads
	.PA_i(PA_i),
	.PA_o(PA_o),
	.PA_d(PA_d), // 1 - input, 0 - output
	.PB_i(PB_i),
	.PB_o(PB_o),
	.PB_d(PB_d),
	.PC_i(PC_i),
	.PC_o(PC_o),
	.PC_d(PC_d),

	// helpers
	.vdp_hclk1(vdp_hclk1),
	.vdp_intfield(vdp_intfield),
	.vdp_de_h(vdp_de_h),
	.vdp_de_v(vdp_de_v),
	.vdp_m2(vdp_m2),
	.vdp_m5(vdp_m5),
	.vdp_rs1(vdp_rs1),
	.vdp_cramdot_dis(~status[10]),
	.ym2612_status_enable(rom_cart_mode & cart_ym2612_quirk),

	.dma_68k_req(dma_68k_req),
	.dma_z80_req(dma_z80_req),
	.dma_z80_ack(dma_z80_ack),
	.res_z80(res_z80)
);

// The board derives the work RAM write enable from R/W, the strobes and the VDP's bus arbitration
// deep inside the chipset; it was the worst 107 MHz path in every fit since build 24 (RW ->
// porta_we_reg, -1.9 to -6.2 ns) and a lost byte write to work RAM hangs the BIOS. The 68000 holds
// address and data for several MCLK cycles around the strobe, so the write side goes through a
// register stage and is performed one MCLK (9.3 ns) later on port B; reads keep the direct
// address on port A. During md_reset port B runs the RAM clear sweep as before.
reg [14:0] ram_68k_wa;
reg [15:0] ram_68k_wd;
reg  [1:0] ram_68k_wbe;
reg        ram_68k_wwe;
always @(posedge clk_md) begin
	ram_68k_wa  <= ram_68k_address;
	ram_68k_wd  <= ram_68k_data;
	ram_68k_wbe <= ram_68k_byteena;
	ram_68k_wwe <= ram_68k_wren;
end

dpram #(15,16) ram_68k
(
	.clock(clk_md),

	.address_a(ram_68k_address),
	.q_a(ram_68k_o),

	.address_b(md_reset ? ram_rst_a : ram_68k_wa),
	.data_b(md_reset ? 16'd0 : ram_68k_wd),
	.byteena_b(md_reset ? 2'b11 : ram_68k_wbe),
	.wren_b(md_reset | ram_68k_wwe)
);

dpram #(13,8) ram_z80k
(
	.clock(clk_md),

	.address_a(ram_z80_address),
	.data_a(ram_z80_data),
	.wren_a(ram_z80_wren),
	.q_a(ram_z80_o),

	.address_b(ram_rst_a[13:1]),
	.wren_b(md_reset),
	.data_b(8'hC7) // reset instruction to fix Titan 2 bug
);

///////////////////////////////////////////////////
// Expansion connector -> Mega CD gate array
//
// The gate array VHDL was written against fpgagen's simplified bus, where every
// select stayed asserted for the whole access. The FC1004 signals are the real
// ones: /ROM, /RAS2 and /FDC follow /AS, but /ASEL is asserted one VCLK after
// /AS. The arbiter acknowledges every A23=0 access itself after a fixed delay
// (there are no expansion wait states on real hardware), so the gate array has
// to start its SDRAM accesses at /AS time: /AS is used as the qualifier where
// the VHDL expected /ASEL. Everything else is the raw pin.

wire        ext_dtack;                               // the gate array asserts /DTACK on the bus
wire        exp_data_en;                             // and drives the data bus for reads (defined below)

// /RAS2 is a DRAM row strobe. Besides word RAM accesses the arbiter pulses it to refresh the
// expansion DRAM: CAS-before-RAS inside refresh-marked cycles and RAS-only (row address =
// whatever is on the bus) during ordinary RAM/VDP cycles. The gate array VHDL expects an
// address-decode style select, so the pulse is qualified with the word RAM window
// (200000-3FFFFF, or 600000-7FFFFF with a cartridge in the slot) and held to the end of
// the bus cycle. A refresh pulse that lands inside the window coincides with a real access.
wire wram_window = ~cart_addr[23] & (cart_addr[22] == rom_cart_mode) & cart_addr[21];
wire exp_ras2_acc = ~exp_ras2 & wram_window;   // level: /RAS2 stays low for a whole VDP DMA burst

// VDP DMA from the expansion: the arbiter drives /AS, /UDS, /LDS inactive and the VDP reads
// word by word with CAS0 (md_board exports its early version as cart_oe) while /ROM or
// /RAS2 stay asserted for the burst. fpgagen's bus model presented DMA reads to the gate
// array as ordinary word reads (strobes + select), so that is synthesised here: the select
// and both data strobes follow the CAS0 strobe while DMA is active.
wire dma_rd    = cart_dma & cart_oe;
wire ext_sel_n = exp_as & ~dma_rd;
wire ext_uds_n = exp_uds & ~dma_rd;
wire ext_lds_n = exp_lds & ~dma_rd;

// The gate array VHDL is a 53.69 MHz synchronous design; the board model's bus registers run
// at 107.38 MHz. One register stage in each direction (the bus buffers on the real Mega CD
// board) keeps every path inside one clock period: the gate array decode is launched from and
// captured by 53.69 MHz registers, and the board model sees registered DTACK/data. Cost:
// 18.6 ns each way out of the ~230 ns the fixed 68000 cycle leaves.
reg [17:1] mcd_va;
reg [15:0] mcd_vdi;
reg        mcd_as_n, mcd_rnw, mcd_lds_n, mcd_uds_n, mcd_sel_n, mcd_ras2_n, mcd_rom_n, mcd_fdc_n;
reg [15:0] mcd_do_r;
reg        mcd_dtack_n_r;
always @(posedge clk_sys) begin
	mcd_va      <= cart_addr[17:1];
	mcd_vdi     <= cart_data_wr;
	mcd_as_n    <= exp_as;
	mcd_rnw     <= exp_rw;
	mcd_lds_n   <= ext_lds_n;
	mcd_uds_n   <= ext_uds_n;
	mcd_sel_n   <= ext_sel_n;
	mcd_ras2_n  <= ~exp_ras2_acc;
	mcd_rom_n   <= exp_rom;
	mcd_fdc_n   <= exp_fdc;
	mcd_do_r    <= MCD_DO;
	mcd_dtack_n_r <= MCD_DTACK_N;
end
assign ext_dtack   = ~mcd_dtack_n_r;
assign exp_data_en = ~mcd_dtack_n_r & exp_rw;

///////////////////////////////////////////////////
// Mega CD

wire [15:0] MCD_DO;
wire        MCD_DTACK_N;
wire        dbg_s68k_as_n, dbg_s68k_dtack_n, dbg_s68k_rnw;   // telemetry: sub-CPU bus cycles
wire        dbg_pcm_smp_ce, dbg_pcm_late, dbg_pcm_we_n, dbg_pcm_cs_n, dbg_s68k_ce_f, dbg_pcm_out_ce; // telemetry: PCM chip
wire [23:0] dbg_s68k_a;                        // MCD exports the sub-CPU address (existing debug port)

wire [15:0] MCD_PCM_SL;
wire [15:0] MCD_PCM_SR;
wire [15:0] MCD_CDDA_SL;
wire [15:0] MCD_CDDA_SR;
wire        MCD_CDDA_WR_READY;

wire [17:0] MCD_PRG_ADDR;
wire [15:0] MCD_PRG_DO;
wire [15:0] MCD_PRG_DI;
wire        MCD_PRG_OE_N;
wire        MCD_PRG_WRL_N;
wire        MCD_PRG_WRH_N;
wire        MCD_PRG_BUSY;

wire [15:0] MCD_PCMRAM_A;
wire  [7:0] MCD_PCMRAM_DO;
wire [15:0] MCD_PCMRAM_DI;
wire        MCD_PCMRAM_RD;
wire        MCD_PCMRAM_WR;
wire        MCD_PCMRAM_BUSY;

wire [15:0] MCD_ROM_DO;
wire        MCD_ROM_CE_N;
wire        MCD_ROM_BUSY;

wire [13:1] MCD_BRAM_ADDR;
wire  [7:0] MCD_BRAM_DO;
wire  [7:0] MCD_BRAM_DI;
wire        MCD_BRAM_WE;

wire        MCD_LED_RED;
wire        MCD_LED_GREEN;

wire        MCD_RST_N;

wire        gg_available1;
wire        gg_available2;

// The Mega CD block steps on ENABLE. The original core tied it high, running the sub-CPU, PCM chip
// and CDC at 53.69/4 = 13.42 MHz instead of 12.5 MHz (7.4% fast) and compensated only the interrupt
// timer divider. A 50 MHz enable restores the real rate for all of them.
wire mcd_en;
CEGen mcd_cegen
(
	.CLK(clk_sys),
	.RST_N(~sys_reset),
	.IN_CLK(PAL ? 53203423 : 53693175), // the Mega CD has its own 50 MHz clock (CDCLK 12.5 MHz is supplied TO the console on the expansion
	                                     // connector); Genesis Plus GX (SCD_CLOCK 50000000) and jgenesis (SEGA_CD_MASTER_CLOCK_RATE 50_000_000)
	                                     // model it fixed while the console clock changes with the region, so derive it from the actual clock.
	.OUT_CLK(50000000),
	.CE(mcd_en)
);

MCD MCD
(
	.RST_N(~(md_reset | btn_reset)),
	.CLK(clk_sys),
	.MCLK(clk_ram),   // Nuked 68000 sub-CPU model sampling clock
	.ENABLE(1'b1),   // every clock: the block's single-clock strobes (CD data, sample enables) must not be skipped
	.EN50(mcd_en),    // 50 MHz enable for the sub-CPU clock phase counter only (50/4 = 12.5 MHz)
	.MCD_RST_N(MCD_RST_N),
	.PALSW(PAL),

	.EXT_VA(mcd_va),
	.EXT_VDI(mcd_vdi),
	.EXT_VDO(MCD_DO),
	.EXT_AS_N(mcd_as_n),
	.EXT_RNW(mcd_rnw),
	.EXT_LDS_N(mcd_lds_n),
	.EXT_UDS_N(mcd_uds_n),
	.EXT_DTACK_N(MCD_DTACK_N),
	.EXT_ASEL_N(mcd_sel_n),
	.EXT_VCLK_CE(1'b0),
	.EXT_RAS2_N(mcd_ras2_n),
	.EXT_ROM_N(mcd_rom_n),
	.EXT_FDC_N(mcd_fdc_n),

	.PRG_A(MCD_PRG_ADDR),
	.PRG_DI(MCD_PRG_DI),
	.PRG_DO(MCD_PRG_DO),
	.PRG_WRL_N(MCD_PRG_WRL_N),
	.PRG_WRH_N(MCD_PRG_WRH_N),
	.PRG_OE_N(MCD_PRG_OE_N),
	.PRG_RDY(~MCD_PRG_BUSY),

	.ROM_DI(MCD_ROM_DO),
	.ROM_CE_N(MCD_ROM_CE_N),
	.ROM_RDY(~MCD_ROM_BUSY),

	.BRAM_A(MCD_BRAM_ADDR),
	.BRAM_DI(MCD_BRAM_DI),
	.BRAM_DO(MCD_BRAM_DO),
	.BRAM_WE(MCD_BRAM_WE),

	.CDD_STAT(scd_cdd_stat),
	.CDD_COMM(scd_cdd_comm),
	.CDD_SEND(scd_cdd_send),
	.CDD_REC(scd_cdd_rec),
	.CDD_DM(scd_cdd_dm),

	.CDC_DATA(cdc_d),
	.CDC_DAT_WR(cdc_wr & (cdc_dat_download | cdc_cdda_download)),
	.CDC_SC_WR(cdc_wr & cdc_sub_download),
	.CDC_CDDA_WR(cdc_wr & cdc_cdda_download),
	.CDDA_WR_READY(MCD_CDDA_WR_READY),

	.PCMRAM_A(MCD_PCMRAM_A),
	.PCMRAM_DO(MCD_PCMRAM_DO),
	.PCMRAM_DI(MCD_PCMRAM_DI[7:0]),
	.PCMRAM_RD(MCD_PCMRAM_RD),
	.PCMRAM_WR(MCD_PCMRAM_WR),
	.PCMRAM_BUSY(MCD_PCMRAM_BUSY),

	.PCM_SL(MCD_PCM_SL),
	.PCM_SR(MCD_PCM_SR),
	.CDDA_SL(MCD_CDDA_SL),
	.CDDA_SR(MCD_CDDA_SR),

	.LED_RED(MCD_LED_RED),
	.LED_GREEN(MCD_LED_GREEN),

	.GG_RESET(code_download && ioctl_wr && !ioctl_addr),
	.GG_EN(status[24]),
	.GG_CODE({gg_code[95] & gg_code[128], gg_code[127:0]}),
	.GG_AVAILABLE(gg_available2),
	.DBG_S68K_AS_N(dbg_s68k_as_n),
	.DBG_S68K_DTACK_N(dbg_s68k_dtack_n),
	.DBG_S68K_RNW(dbg_s68k_rnw),
	.DBG_PCM_SMP_CE(dbg_pcm_smp_ce),
	.DBG_PCM_OUT_CE(dbg_pcm_out_ce),
	.DBG_PCM_LATE(dbg_pcm_late),
	.DBG_PCM_WE_N(dbg_pcm_we_n),
	.DBG_PCM_CS_N(dbg_pcm_cs_n),
	.DBG_S68K_CE_F(dbg_s68k_ce_f),
	.DBG_S68K_A(dbg_s68k_a)
);

///////////////////////////////////////////////////
// Cartridge slot

wire [24:1] cart_mem_addr;
wire        cart_mem_rd;
wire        cart_mem_wrl, cart_mem_wrh;
wire [15:0] cart_mem_din;
wire        cart_eep_sel, cart_eep_we;
wire [12:0] cart_eep_addr;
wire  [7:0] cart_eep_di;
wire        cart_gun_type, cart_ym2612_quirk, PIER_QUIRK;
wire  [7:0] cart_gun_delay;
wire [15:0] jcart_data;
wire        jcart_th;
wire [15:0] cart_mem_dout;
wire        cart_mem_busy;
wire        cart_ram_wr;

wire        CART_EN = status[3];

mcd_cart cart
(
	.clk(clk_ram),
	.clk_sys(clk_sys),
	.reset(md_reset),

	.cart_dl(cart_download),
	.cart_dl_addr(ioctl_addr),
	.cart_dl_data(ioctl_data),
	.cart_dl_wr(ioctl_wr),

	.cart_addr(cart_addr),
	.cart_data_wr(cart_data_wr),
	.cart_cs(cart_cs),
	.cart_oe(cart_oe),
	.cart_lwr(cart_lwr),
	.cart_uwr(cart_uwr),
	.cart_time(cart_time),
	.cart_data(cart_data),
	.cart_data_en(cart_data_en),

	.rom_mode(rom_cart_mode),
	.ram_cart_en(CART_EN),

	.mem_addr(cart_mem_addr),
	.mem_rd(cart_mem_rd),
	.mem_wrl(cart_mem_wrl),
	.mem_wrh(cart_mem_wrh),
	.mem_din(cart_mem_din),
	.mem_dout(cart_mem_dout),
	.mem_busy(cart_mem_busy),

	.eep_sel(cart_eep_sel),
	.eep_addr(cart_eep_addr),
	.eep_di(cart_eep_di),
	.eep_we(cart_eep_we),
	.eep_q(MCD_BRAM_DI),

	.ram_wr(cart_ram_wr),
	.clearing(cart_clearing),

	.jcart_en(status[31]),
	.jcart_data(jcart_data),
	.jcart_th(jcart_th),

	.gun_type(cart_gun_type),
	.gun_sensor_delay(cart_gun_delay),
	.ym2612_quirk(cart_ym2612_quirk),
	.pier_quirk_o(PIER_QUIRK)
);

///////////////////////////////////////////////////
// SDRAM: cart ROM 000000-7FFFFF, RAM cart E00000-EFFFFF, BIOS F00000-F1FFFF, PRG-RAM 1000000-107FFFF, PCM RAM 1080000-10FFFFF (byte per word)

always @(posedge clk_sys) begin
	reg old_busy;

	old_busy <= tmpram_busy;
	if(rom_download & ioctl_wr) ioctl_wait <= 1;
	if(old_busy & ~tmpram_busy) ioctl_wait <= 0;
end

sdram sdram
(
	.*,
	.init(~locked),
	.clk(clk_ram),

	// cartridge slot (main CPU / VDP DMA)
	.addr0(cart_mem_addr),
	.din0(cart_mem_din),
	.dout0(cart_mem_dout),
	.rd0(cart_mem_rd),
	.wrl0(cart_mem_wrl),
	.wrh0(cart_mem_wrh),
	.busy0(cart_mem_busy),

	// Mega CD BIOS ROM (main CPU / VDP DMA)
	.addr1({8'b01111000, cart_addr[16:1]}),
	.din1(16'h0000),
	.dout1(MCD_ROM_DO),
	.rd1(~MCD_ROM_CE_N),
	.wrl1(1'b0),
	.wrh1(1'b0),
	.busy1(MCD_ROM_BUSY),

	// Mega CD PRG-RAM: banks 2,3 (or 0,1 for debugging)
	.addr2({(MCD_BANK23 ? 6'b100000 : 6'b011111),MCD_PRG_ADDR}),
	.din2(MCD_PRG_DO),
	.dout2(MCD_PRG_DI),
	.rd2(~MCD_PRG_OE_N),
	.wrl2(~MCD_PRG_WRL_N),
	.wrh2(~MCD_PRG_WRH_N),
	.busy2(MCD_PRG_BUSY),

	// Mega CD PCM wave RAM (sub CPU, gate array DMA, sample fetch)
	.addr3({6'b100001, 2'b00, MCD_PCMRAM_A}),
	.din3({8'h00, MCD_PCMRAM_DO}),
	.dout3(MCD_PCMRAM_DI),
	.rd3(MCD_PCMRAM_RD),
	.wrl3(MCD_PCMRAM_WR),
	.wrh3(1'b0),
	.busy3(MCD_PCMRAM_BUSY),

	// Load/Save
	.addr4( rom_download ? (cart_download ? {2'b00,ioctl_addr[22:1]} : {6'b011110,ioctl_addr[18:1]}) : //ROM  000000-7FFFFF/F00000-F7FFFF
								{5'b01110,tmpram_lba[9:0],tmpram_addr}),    //CART RAM E00000-EFFFFF for sd_*
	.din4(rom_download ? {ioctl_data[7:0],ioctl_data[15:8]} : {tmpram_dout,tmpram_dout}),
	.dout4(tmpram_din),
	.rd4(~rom_download & tmpram_req & ~bk_loading),
	.wrl4(rom_download ? ioctl_wait : (tmpram_req & bk_loading)),
	.wrh4(rom_download ? ioctl_wait : (tmpram_req & bk_loading)),
	.busy4(tmpram_busy)
);

///////////////////////////////////////////////////
// Bring-up telemetry (test core)


/////////////////////////////////////////////////
// Audio

wire [15:0] GEN_AUDL;
wire [15:0] GEN_AUDR;
wire        GEN_CE;

audio_cond audio_cond
(
	.clk(clk_sys),
	.reset(sys_reset),
	.mute(~clk_en | dma_z80_req),

	.lpf_mode(status[15:14]),
	.fm_mode(status[8]),
	.fm_en(EN_GEN_FM),
	.psg_en(EN_GEN_PSG),

	.fm_clk1(fm_clk1),
	.fm_sel23(fm_sel23),
	.MOL(MOL),
	.MOR(MOR),
	.MOL_2612(MOL_2612),
	.MOR_2612(MOR_2612),
	.PSG(PSG),
	.sms_fm_audio(14'd0),

	.ext_l(mcd_l),
	.ext_r(mcd_r),
	.ext_en(status[27]),

	.AUDIO_L(GEN_AUDL),
	.AUDIO_R(GEN_AUDR),
	.ce_out(GEN_CE)
);

localparam [3:0] comp_f1 = 4;
localparam [3:0] comp_a1 = 2;
localparam       comp_x1 = ((32767 * (comp_f1 - 1)) / ((comp_f1 * comp_a1) - 1)) + 1; // +1 to make sure it won't overflow
localparam       comp_b1 = comp_x1 * comp_a1;

localparam [3:0] comp_f2 = 8;
localparam [3:0] comp_a2 = 4;
localparam       comp_x2 = ((32767 * (comp_f2 - 1)) / ((comp_f2 * comp_a2) - 1)) + 1; // +1 to make sure it won't overflow
localparam       comp_b2 = comp_x2 * comp_a2;

function [15:0] compr; input [15:0] inp;
	reg [15:0] v, v1, v2;
	begin
		v  = inp[15] ? (~inp) + 1'd1 : inp;
		v1 = (v < comp_x1[15:0]) ? (v * comp_a1) : (((v - comp_x1[15:0])/comp_f1) + comp_b1[15:0]);
		v2 = (v < comp_x2[15:0]) ? (v * comp_a2) : (((v - comp_x2[15:0])/comp_f2) + comp_b2[15:0]);
		v  = status[58] ? v2 : v1;
		compr = inp[15] ? ~(v-1'd1) : v;
	end
endfunction

reg [15:0] aud_l, aud_r;
reg [15:0] cmp_l, cmp_r;
reg [15:0] mcd_l, mcd_r;
always @(posedge clk_sys) begin
	mcd_l <= ({16{EN_MCD_PCM}} & {MCD_PCM_SL[15],MCD_PCM_SL[15:1]}) + ({16{EN_MCD_CDDA}} & {MCD_CDDA_SL[15],MCD_CDDA_SL[15:1]});
	mcd_r <= ({16{EN_MCD_PCM}} & {MCD_PCM_SR[15],MCD_PCM_SR[15:1]}) + ({16{EN_MCD_CDDA}} & {MCD_CDDA_SR[15],MCD_CDDA_SR[15:1]});

	if(~status[27]) begin
		aud_l <= {GEN_AUDL[15],GEN_AUDL[15:1]} + {mcd_l[15],mcd_l[15:1]};
		aud_r <= {GEN_AUDR[15],GEN_AUDR[15:1]} + {mcd_r[15],mcd_r[15:1]};
	end
	else begin
		aud_l <= GEN_AUDL;
		aud_r <= GEN_AUDR;
	end

	cmp_l <= compr(aud_l);
	cmp_r <= compr(aud_r);
end

audio_fix #(250) audio_fix // MCLK/504 in lpf, so choose half to get in the middle of sample period
(
	.*,
	.reset(sys_reset),
	.clk(clk_sys),
	.ce(GEN_CE),
	.l(status[58:57] ? cmp_l : aud_l),
	.r(status[58:57] ? cmp_r : aud_r)
);

// telemetry sits after the audio section so it can tap the mixed audio registers
`ifdef MCD_TELEMETRY
mcd_debug mcd_debug
(
	.clk(clk_ram),
	.exp_as(exp_as), .exp_rw(exp_rw), .exp_rom(exp_rom), .exp_ras2(exp_ras2), .exp_fdc(exp_fdc),
	.mcd_dtack_n(MCD_DTACK_N), .bus_dtack(exp_dtack),
	.va(cart_addr), .vd(cart_data_wr), .cart_cs(cart_cs), .cart_oe(cart_oe), .vclk(VCLK), .vs(vs), .hs(hs),
	.prg_rd(~MCD_PRG_OE_N), .prg_wr(~MCD_PRG_WRL_N | ~MCD_PRG_WRH_N),
	.md_reset(md_reset), .btn_reset(btn_reset), .sys_reset(sys_reset), .mcd_rst_n(MCD_RST_N),
	.rom_cart_mode(rom_cart_mode), .region(region), .led_r(MCD_LED_RED), .led_g(MCD_LED_GREEN), .locked(locked),
	.rom_download(rom_download), .ioctl_wr(ioctl_wr), .m68k_reset(exp_m68k_reset), .m68k_halt(exp_m68k_halt),
	.mcd_do(MCD_DO), .sdram_dout(MCD_ROM_DO), .rom_busy(MCD_ROM_BUSY), .ras2_window(wram_window), .cart_dma(cart_dma), .exp_asel(exp_asel), .dma_rd(dma_rd),
	.s68k_as_n(dbg_s68k_as_n), .s68k_dtack_n(dbg_s68k_dtack_n), .s68k_a(dbg_s68k_a[23:1]), .s68k_rnw(dbg_s68k_rnw),
	.pcm_out_ce(dbg_pcm_out_ce), .pcm_l(MCD_PCM_SL), .pcm_r(MCD_PCM_SR), .aud_l(aud_l), .aud_r(aud_r),
	.cdd_send(scd_cdd_send), .cdd_rec(scd_cdd_rec),
	.pcm_smp_ce(dbg_pcm_smp_ce), .pcm_late(dbg_pcm_late), .pcm_we_n(dbg_pcm_we_n), .pcm_cs_n(dbg_pcm_cs_n), .s68k_ce_f(dbg_s68k_ce_f),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD), .DDRAM_BUSY(DDRAM_BUSY)
);
`else
assign DDRAM_BURSTCNT = 0;
assign DDRAM_ADDR = 0;
assign DDRAM_DIN = 0;
assign DDRAM_BE = 0;
assign DDRAM_WE = 0;
assign DDRAM_RD = 0;
`endif

///////////////////////////////////////////////////
// Backup RAM (internal), temp buffer for the RAM cartridge save file

wire [15:0] bram_sd_buff_data;
dpram_dif #(13,8,12,16) bram
(
	.clock(clk_sys),
	.address_a(cart_eep_sel ? cart_eep_addr : MCD_BRAM_ADDR),
	.data_a(cart_eep_sel ? cart_eep_di : MCD_BRAM_DO),
	.wren_a(cart_eep_sel ? cart_eep_we : MCD_BRAM_WE),
	.q_a(MCD_BRAM_DI),

	.address_b({sd_lba[0][3:0],sd_buff_addr}),
	.data_b(sd_buff_dout),
	.wren_b(sd_buff_wr & sd_ack & !sd_lba[0][10:4]),
	.q_b(bram_sd_buff_data)
);

wire [7:0] tmpram_dout;
wire [7:0] tmpram_din;
wire       tmpram_busy;

wire [15:0] tmpram_sd_buff_data;
dpram_dif #(9,8,8,16) tmpram
(
	.clock(clk_sys),

	.address_a(tmpram_addr),
	.wren_a(~bk_loading & tmpram_busy_d & ~tmpram_busy),
	.data_a(tmpram_din),
	.q_a(tmpram_dout),

	.address_b(sd_buff_addr),
	.wren_b(sd_buff_wr & sd_ack & |sd_lba[0][10:4]),
	.data_b(sd_buff_dout),
	.q_b(tmpram_sd_buff_data)
);

reg [10:0] tmpram_lba;
reg  [8:0] tmpram_addr;
reg tmpram_tx_start;
reg tmpram_tx_finish;
reg tmpram_req;
reg tmpram_busy_d;
always @(posedge clk_sys) begin
	reg state;

	tmpram_lba <= sd_lba[0][10:0]-11'h10;

	tmpram_busy_d <= tmpram_busy;
	if(~tmpram_busy_d & tmpram_busy) tmpram_req <= 0;

	if(~tmpram_tx_start) {tmpram_addr, state, tmpram_tx_finish} <= 0;
	else if(~tmpram_tx_finish) begin
		if(!state) begin
			tmpram_req <= 1;
			state <= 1;
		end
		else if(tmpram_busy_d & ~tmpram_busy) begin
			state <= 0;
			if(~&tmpram_addr) tmpram_addr <= tmpram_addr + 1'd1;
			else tmpram_tx_finish <= 1;
		end
	end
end


///////////////////////////////////////////////////
// CD communication

reg [48:0] cd_in;
wire [48:0] cd_out;

reg [39:0] scd_cdd_stat;
reg scd_cdd_dm;
wire [39:0] scd_cdd_comm;
wire scd_cdd_send;
reg scd_cdd_rec;

always @(posedge clk_sys) begin
	reg cd_out48_last = 1;
	reg scd_cdd_send_old = 0;
	reg [2:0] cnt = 0;
	reg rst_old = 0;

	if (cd_out[48] != cd_out48_last)  begin
		cd_out48_last <= cd_out[48];
		scd_cdd_stat <= cd_out[39:0];
		scd_cdd_dm <= cd_out[40];
		scd_cdd_rec <= 1;
		cnt <= 7;
	end
	else if (cnt) begin
		cnt <= cnt - 1'd1;
	end
	else begin
		scd_cdd_rec <= 0;
	end

	scd_cdd_send_old <= scd_cdd_send;
	if (scd_cdd_send && !scd_cdd_send_old) begin
		cd_in[47:0] <= {8'h00,scd_cdd_comm};
		cd_in[48] <= ~cd_in[48];
	end
	else begin
		rst_old <= MCD_RST_N;
		if (rst_old & ~MCD_RST_N) begin
			cd_in[47:0] <= 8'hFF;
			cd_in[48] <= ~cd_in[48];
		end
	end
end


//extend cdc_wr for 8 cycles
reg  cdc_wr;
reg [15:0] cdc_d;
always @(posedge clk_sys) begin
	reg [2:0] cnt = 0;

	if (ioctl_wr) begin
		cnt <= 7;
		cdc_wr <= 1;
		cdc_d <= ioctl_data;
	end
	else if (cnt) begin
		cnt <= cnt - 1'd1;
	end
	else begin
		cdc_wr <= 0;
	end
end


/////////////////////////////////////////////////////////////
// Video

reg new_vmode;
always @(posedge clk_sys) begin
	reg old_pal;
	int to;

	if(~(sys_reset | rom_download)) begin
		old_pal <= PAL;
		if(old_pal != PAL) to <= 5000000;
	end
	else to <= 5000000;

	if(to) begin
		to <= to - 1;
		if(to == 1) new_vmode <= ~new_vmode;
	end
end

wire       ce_pix;
wire       f1;
wire       interlace;
wire       vblank_c, hblank_c, hs_c, vs_c;
wire [7:0] r_c, g_c, b_c;
wire[11:0] arx,ary;

video_cond video_cond
(
	.clk(CLK_VIDEO),

	.vdp_hclk1(vdp_hclk1),
	.vdp_de_h(vdp_de_h),
	.vdp_de_v(vdp_de_v),
	.vdp_intfield(vdp_intfield),
	.vdp_m2(vdp_m2),
	.vdp_m5(vdp_m5),
	.vdp_rs1(vdp_rs1),

	.r_in(r),
	.g_in(g),
	.b_in(b),
	.hs_in(hs),
	.vs_in(vs),

	.pal(PAL),
	.border_en(status[29]),
	.h40corr(status[30]),
	.blender(status[47]),

	.arx(arx),
	.ary(ary),

	.ce_pix(ce_pix),
	.interlace(interlace),
	.f1(f1),

	.r_out(r_c),
	.g_out(g_c),
	.b_out(b_c),
	.hs_out(hs_c),
	.vs_out(vs_c),
	.hbl_out(hblank_c),
	.vbl_out(vblank_c)
);

wire [2:0] scale = status[35:33];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;

assign VGA_SL = {~interlace,~interlace}&sl[1:0];
assign VGA_F1 = f1;

video_mixer #(.LINE_LENGTH(400), .GAMMA(1)) video_mixer
(
	.*,

	.scandoubler(~interlace && (scale || forced_scandoubler)),
	.hq2x(scale==1),
	.freeze_sync(),

	.VGA_DE(vga_de),
	.R((lg_target && gun_mode && (~&status[44:43])) ? {8{lg_target[0]}} : r_c),
	.G((lg_target && gun_mode && (~&status[44:43])) ? {8{lg_target[1]}} : g_c),
	.B((lg_target && gun_mode && (~&status[44:43])) ? {8{lg_target[2]}} : b_c),

	// Positive pulses.
	.HSync(hs_c),
	.VSync(vs_c),
	.HBlank(hblank_c),
	.VBlank(vblank_c)
);

///////////////////////////////////////////////////
// Input

wire [11:0] joy0 = status[4] ? joystick_1[11:0] : joystick_0[11:0];
wire [11:0] joy1 = status[4] ? joystick_0[11:0] : joystick_1[11:0];

wire [6:0] md_io_port1, md_io_port2;

md_io md_io
(
	.clk(clk_sys),
	.reset(sys_reset),

	.MODE(status[5]),
	.SMS(1'b0),
	.MULTITAP(status[22:21]),

	.P1_UP(joy0[3]),
	.P1_DOWN(joy0[2]),
	.P1_LEFT(joy0[1]),
	.P1_RIGHT(joy0[0]),
	.P1_A(joy0[4]),
	.P1_B(joy0[5]),
	.P1_C(joy0[6]),
	.P1_START(joy0[7]),
	.P1_MODE(joy0[8]),
	.P1_X(joy0[9]),
	.P1_Y(joy0[10]),
	.P1_Z(joy0[11]),

	.P2_UP(joy1[3]),
	.P2_DOWN(joy1[2]),
	.P2_LEFT(joy1[1]),
	.P2_RIGHT(joy1[0]),
	.P2_A(joy1[4]),
	.P2_B(joy1[5]),
	.P2_C(joy1[6]),
	.P2_START(joy1[7]),
	.P2_MODE(joy1[8]),
	.P2_X(joy1[9]),
	.P2_Y(joy1[10]),
	.P2_Z(joy1[11]),

	.P3_UP(joystick_2[3]),
	.P3_DOWN(joystick_2[2]),
	.P3_LEFT(joystick_2[1]),
	.P3_RIGHT(joystick_2[0]),
	.P3_A(joystick_2[4]),
	.P3_B(joystick_2[5]),
	.P3_C(joystick_2[6]),
	.P3_START(joystick_2[7]),
	.P3_MODE(joystick_2[8]),
	.P3_X(joystick_2[9]),
	.P3_Y(joystick_2[10]),
	.P3_Z(joystick_2[11]),

	.P4_UP(joystick_3[3]),
	.P4_DOWN(joystick_3[2]),
	.P4_LEFT(joystick_3[1]),
	.P4_RIGHT(joystick_3[0]),
	.P4_A(joystick_3[4]),
	.P4_B(joystick_3[5]),
	.P4_C(joystick_3[6]),
	.P4_START(joystick_3[7]),
	.P4_MODE(joystick_3[8]),
	.P4_X(joystick_3[9]),
	.P4_Y(joystick_3[10]),
	.P4_Z(joystick_3[11]),

	.P5_UP(joystick_4[3]),
	.P5_DOWN(joystick_4[2]),
	.P5_LEFT(joystick_4[1]),
	.P5_RIGHT(joystick_4[0]),
	.P5_A(joystick_4[4]),
	.P5_B(joystick_4[5]),
	.P5_C(joystick_4[6]),
	.P5_START(joystick_4[7]),
	.P5_MODE(joystick_4[8]),
	.P5_X(joystick_4[9]),
	.P5_Y(joystick_4[10]),
	.P5_Z(joystick_4[11]),

	.GUN_OPT(|gun_mode),
	.GUN_TYPE(gun_type),
	.GUN_SENSOR(lg_sensor),
	.GUN_A(lg_a),
	.GUN_B(lg_b),
	.GUN_C(lg_c),
	.GUN_START(lg_start),

	.MOUSE(ps2_mouse),
	.MOUSE_OPT(status[20:18]),

	.jcart_data(jcart_data),
	.jcart_th(jcart_th),

	.port1_out(md_io_port1),
	.port1_in(PA_o  | {7{snac_port1}}),
	.port1_dir(PA_d | {7{snac_port1}}),

	.port2_out(md_io_port2),
	.port2_in(PB_o  | {7{snac_port2}}),
	.port2_dir(PB_d | {7{snac_port2}}),

	.PS2_KEY(ps2_key),
	.PS2_LED(ps2_kbd_led_status),
	.KEYBOARD_OPT(status[62:61])
);

wire [2:0] lg_target;
wire       lg_sensor;
wire       lg_a;
wire       lg_b;
wire       lg_c;
wire       lg_start;

lightgun lightgun
(
	.CLK(clk_sys),
	.RESET(sys_reset),

	.MOUSE(ps2_mouse),
	.MOUSE_XY(&gun_mode),

	.JOY_X(gun_mode[0] ? joy0_x : joy1_x),
	.JOY_Y(gun_mode[0] ? joy0_y : joy1_y),
	.JOY(gun_mode[0] ? joystick_0 : joystick_1),

	.RELOAD(gun_type),

	.HDE(~hblank_c),
	.VDE(~vblank_c),
	.CE_PIX(ce_pix),
	.H40(vdp_rs1),

	.BTN_MODE(gun_btn_mode),
	.SIZE(status[44:43]),
	.SENSOR_DELAY(rom_cart_mode ? cart_gun_delay : (gun_type ? 8'd32 : 8'd64)),

	.TARGET(lg_target),
	.SENSOR(lg_sensor),
	.BTN_A(lg_a),
	.BTN_B(lg_b),
	.BTN_C(lg_c),
	.BTN_START(lg_start)
);

wire [6:0] SNAC_IN;
wire [6:0] SNAC_OUT;
always_comb begin
	SNAC_IN[0]  = USER_IN[1]; //up
	SNAC_IN[1]  = USER_IN[0]; //down
	SNAC_IN[2]  = USER_IN[5]; //left
	SNAC_IN[3]  = USER_IN[3]; //right
	SNAC_IN[4]  = USER_IN[2]; //b TL
	SNAC_IN[5]  = USER_IN[6]; //c TR GPIO7
	SNAC_IN[6]  = USER_IN[4]; //  TH
	USER_OUT[1] = SNAC_OUT[0];
	USER_OUT[0] = SNAC_OUT[1];
	USER_OUT[5] = SNAC_OUT[2];
	USER_OUT[3] = SNAC_OUT[3];
	USER_OUT[2] = SNAC_OUT[4];
	USER_OUT[6] = SNAC_OUT[5];
	USER_OUT[4] = SNAC_OUT[6];
end

wire snac_port1 = (status[64:63] == 1);
assign PA_i = snac_port1 ? SNAC_IN : md_io_port1;

wire snac_port2 = (status[64:63] == 2);
assign PB_i = snac_port2 ? SNAC_IN : md_io_port2;

wire snac_port3 = (status[64:63] == 3);
assign PC_i = snac_port3 ? SNAC_IN : (PC_d | PC_o);

assign SNAC_OUT = snac_port1 ? (PA_d | PA_o) : snac_port2 ? (PB_d | PB_o) : snac_port3 ? (PC_d | PC_o) : 7'h7F;

///////////////////////////////////////////////////
// Region

reg  [1:0] region_req;
reg        region_reset;
wire       pressed = ps2_key[9];
wire [8:0] code    = ps2_key[8:0];
always @(posedge clk_sys) begin
	reg old_state = 0;

	if(reset) region_reset <= 0;

	old_state <= ps2_key[10];
	if(old_state != ps2_key[10]) begin
		casex(code)
			'h005: begin region_req <= 0; region_reset <= pressed; end // F1
			'h006: begin region_req <= 1; region_reset <= pressed; end // F2
			'h004: begin region_req <= 2; region_reset <= pressed; end // F3
		endcase
	end

	if(ioctl_wr & rom_download) begin
		if(ioctl_addr == 'h1F0) begin
			if(ioctl_data[7:0] == "J") region_req <= 0;
			else if(ioctl_data[7:0] == "U") region_req <= 1;
			else region_req <= 2;
		end
	end
end

wire [1:0] region_new = status[7:6] ? (status[7:6] - 1'd1) : region_req;

reg  [1:0] region;
reg        region_set = 0;
always @(posedge clk_sys) begin
	reg [15:0] to = 0;

	region <= region_new;
	if(region != region_new) to <= 0;

	region_set <= 0;
	if(~&to) begin
		to <= to + 1'd1;
		region_set <= 1;
	end
end


/////////////////////////  BRAM SAVE/LOAD  /////////////////////////////

wire downloading = save_download | cart_download;
wire bk_change  = MCD_BRAM_WE | ((CART_EN | rom_cart_mode) & cart_ram_wr);
wire autosave   = status[13];
wire bk_load    = status[16];
wire bk_save    = status[17];

reg bk_ena = 0;
reg sav_pending = 0;
always @(posedge clk_sys) begin
	reg old_downloading = 0;
	reg old_change = 0;

	old_downloading <= downloading;
	if(~old_downloading & downloading) bk_ena <= 0;

	//Save file mounted by the HPS (CD game save, or the cartridge save for "Insert Cartridge")
	if(img_mounted && !img_readonly) bk_ena <= 1;

	old_change <= bk_change;
	if (~old_change & bk_change) sav_pending <= 1;
	else if (bk_state) sav_pending <= 0;
end

wire bk_save_a  = autosave & OSD_STATUS;
reg  bk_loading = 0;
reg  bk_state   = 0;
reg  bk_reload  = 0;

always @(posedge clk_sys) begin
	reg old_downloading = 0;
	reg old_load = 0, old_save = 0, old_save_a = 0, old_ack;
	reg [1:0] state;

	old_downloading <= downloading;

	old_load   <= bk_load;
	old_save   <= bk_save;
	old_save_a <= bk_save_a;
	old_ack    <= sd_ack;

	if(~old_ack & sd_ack) {sd_rd, sd_wr} <= 0;

	if(!bk_state) begin
		tmpram_tx_start <= 0;
		state <= 0;
		sd_lba[0] <= 0;
		bk_reload <= 0;
		bk_loading <= 0;
		if(bk_ena & ((~old_load & bk_load) | (~old_save & bk_save) | (~old_save_a & bk_save_a & sav_pending))) begin
			bk_state <= 1;
			bk_loading <= bk_load;
			bk_reload <= bk_load;
			sd_rd <=  bk_load;
			sd_wr <= ~bk_load;
		end
		if(old_downloading & ~rom_download & bk_ena) begin
			bk_state <= 1;
			bk_loading <= 1;
			sd_rd <= 1;
			sd_wr <= 0;
		end
	end
	else if(!sd_lba[0][10:4]) begin
		if(old_ack & ~sd_ack) begin
			sd_lba[0] <= sd_lba[0] + 1'd1;
			if(&sd_lba[0][3:0]) begin
				if(~CART_EN) bk_state <= 0;
			end else begin
				sd_rd <=  bk_loading;
				sd_wr <= ~bk_loading;
			end
		end
	end
	else if(bk_loading) begin
		case(state)
			0: begin
					sd_rd <= 1;
					state <= 1;
				end
			1: if(old_ack & ~sd_ack) begin
					tmpram_tx_start <= 1;
					state <= 2;
				end
			2: if(tmpram_tx_finish) begin
					tmpram_tx_start <= 0;
					state <= 0;
					sd_lba[0] <= sd_lba[0] + 1'd1;
					if(sd_lba[0][10:0] == 11'h40F) bk_state <= 0;
				end
		endcase
	end
	else begin
		case(state)
			0: begin
					tmpram_tx_start <= 1;
					state <= 1;
				end
			1: if(tmpram_tx_finish) begin
					tmpram_tx_start <= 0;
					sd_wr <= 1;
					state <= 2;
				end
			2: if(old_ack & ~sd_ack) begin
					state <= 0;
					sd_lba[0] <= sd_lba[0] + 1'd1;
					if(sd_lba[0][10:0] == 11'h40F) bk_state <= 0;
				end
		endcase
	end
end


///////////////////////////////////////////////
// Cartridge in the slot: set by a cartridge download (OSD "Insert Cartridge" or cart.rom
// next to the CD), cleared by a BIOS (re)load or "Reset & Eject". While set, /CART is low:
// the cartridge boots at 000000 and the Mega CD sits at 400000.

reg rom_cart_mode = 0;
always @(posedge clk_sys) begin
	reg old_cart_dl, old_bios_dl;
	old_cart_dl <= cart_download;
	old_bios_dl <= bios_download;
	if(~old_cart_dl & cart_download) rom_cart_mode <= 1;
	if((~old_bios_dl & bios_download) | host_reset) rom_cart_mode <= 0;
end

///////////////////////////////////////////////
// Cheats: main 68000 (bit 95 of a code clear) sits on the NukedMD data bus

reg [15:0] m68k_data;
always @(posedge clk_md) m68k_data <= m68k_genie_data;

wire [15:0] m68k_genie_data;
CODES #(.ADDR_WIDTH(24), .DATA_WIDTH(16), .BIG_ENDIAN(1)) codes_68k
(
	.clk(clk_sys),
	.reset(rom_download | (code_download && ioctl_wr && !ioctl_addr)),
	.enable(~status[24]),
	.code({~gg_code[95] & gg_code[128], gg_code[127:0]}),
	.available(gg_available1),
	.addr_in({m68k_addr, 1'b0}),
	.data_in(m68k_bus_do),
	.data_out(m68k_genie_data)
);

endmodule
