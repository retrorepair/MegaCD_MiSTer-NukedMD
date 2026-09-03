
// VDP VRAM bank (8KB as 256 rows of 256 bits) for the NukedMD HLE VRAM model.
//
// MegaCD: the byte lanes are merged in logic and the whole row is written, instead of
// using the RAM's byte enables. With 8-bit byte enables Quartus has to use the narrow
// M10K mode (13 blocks per bank); writing full rows lets it use the x40 mode (7 blocks
// per bank), which is what makes the Mega CD fit next to the NukedMD chipset.
// Behaviour is identical: q is the row addressed at the previous clock edge, the row
// address is latched at /RAS and the write follows /CAS, so the merged row is current
// (read-during-write returns the new data for back-to-back writes).
module vram_ip
(
	input	  [7:0] address,
	input	 [31:0] byteena,
	input	        clock,
	input	[255:0] data,
	input	        wren,
	output[255:0] q
);

reg [255:0] wdata;
integer i;
always @* begin
	for(i = 0; i < 32; i = i + 1) wdata[i*8 +: 8] = byteena[i] ? data[i*8 +: 8] : q[i*8 +: 8];
end

spram #(8,256) ram
(
	.clock(clock),
	.address(address),
	.data(wdata),
	.wren(wren),
	.q(q)
);

endmodule
