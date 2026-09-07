// Transparent stub for the game-genie CODES module (irrelevant to CDC; cheats disabled).
module CODES #(parameter ADDR_WIDTH=16, parameter DATA_WIDTH=8, parameter BIG_ENDIAN=0) (
   input  logic        clk, reset, enable,
   output logic        available,
   input  logic [128:0] code,
   input  logic [23:0] addr_in,
   input  logic [15:0] data_in,
   output logic [15:0] data_out
);
   assign available = 1'b0;
   assign data_out  = data_in;
endmodule
