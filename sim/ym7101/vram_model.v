// vram_model -- behavioural VRAM for the ym7101 A/B bench (sim support, NOT part of the DUT).
// Reimplements rtl/nuked-md/vram.v's DRAM protocol (row on RAS, column on CAS, page-mode
// parallel read on OE, serial page read clocked by SC) with a plain 64 KB memory instead of the
// Altera vram_ip megafunction, so it compiles in ModelSim ASE.  Behaviour is deterministic and
// identical for both DUTs (it is driven from the die model's DRAM outputs and its output feeds
// both), which is all the equivalence bench needs.  Memory is seeded with a fixed address-derived
// pattern so reads are always defined and vary across the address space.
module vram_model
	(
	input MCLK,
	input RAS,
	input CAS,
	input WE,
	input OE,
	input SC,
	input SE,
	input [7:0] AD,
	input [7:0] RD_i,
	output reg [7:0] RD_o,
	output RD_d,
	output [7:0] SD_o,
	output SD_d
	);

	reg [15:0] addr;
	reg dt;
	reg [7:0] addr_ser;

	reg o_OE;
	reg o_RAS;
	reg o_cas;
	reg o_SC;
	reg o_valid = 1'h0;

	wire cas = ~RAS & ~CAS;
	wire wr  = ~RAS & ~CAS & ~WE;
	wire rd  = ~RAS & ~CAS & ~OE & ~dt;

	reg [7:0] mem   [0:65535];   // {row,col}
	reg [7:0] serrow[0:255];     // snapshot of the current row for the serial port

	integer k;
	initial begin
		for (k = 0; k < 65536; k = k + 1) mem[k] = (k[7:0] ^ k[15:8] ^ 8'h5a);
		addr = 16'h0; dt = 1'h0; addr_ser = 8'h0;
		o_OE = 1'h1; o_RAS = 1'h1; o_cas = 1'h0; o_SC = 1'h0;
		RD_o = 8'h0;
		for (k = 0; k < 256; k = k + 1) serrow[k] = 8'h0;
	end

	assign RD_d = ~o_valid;
	assign SD_d = SE;

	reg [7:0] vram_ser;
	assign SD_o = vram_ser;

	wire [15:0] mem_addr = { addr[15:8], addr[7:0] };

	always @(posedge MCLK)
	begin
		if (dt & !o_OE & OE)
		begin
			addr_ser <= addr[7:0];
			for (k = 0; k < 256; k = k + 1) serrow[k] <= mem[{addr[15:8], k[7:0]}];
		end
		else if (~o_SC & SC)
		begin
			addr_ser <= addr_ser + 8'h1;
			vram_ser <= serrow[addr_ser];
		end
		if (o_RAS & ~RAS)
		begin
			dt <= ~OE;
			addr[15:8] <= AD;
		end
		if (~o_cas & cas)
		begin
			addr[7:0] <= AD;
		end

		if (wr)
			mem[mem_addr] <= RD_i;   // latched row/col (as vram.v addresses vram_ip)

		if (rd)
		begin
			RD_o <= mem[mem_addr];
			o_valid <= 1'h1;
		end
		else if (CAS | OE)
		begin
			o_valid <= 1'h0;
		end

		o_OE  <= OE;
		o_RAS <= RAS;
		o_cas <= cas;
		o_SC  <= SC;
	end

endmodule
