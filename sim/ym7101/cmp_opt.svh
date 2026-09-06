// Outputs-only storage stub for the Stage-2 (+OPT) bench: the collapsed opt storage does NOT
// map 1:1 to the die's, so no storage compare is done -- only the module outputs are compared
// (see all_a/all_b in tb_ym7101.sv).  STO_W=1 with sto_a==sto_b keeps the comparator wiring but
// contributes nothing.
localparam int STO_W = 1;
wire [STO_W-1:0] sto_a = 1'b0;
wire [STO_W-1:0] sto_b = 1'b0;
task automatic report_storage(input string phase);
endtask
