// ============================================================================
// tb_cdc_sync.sv - REVIEW-ONLY bench (added by an adversarial review, not by the
// core author).  Instantiates rtl/MCD/CDC.vhd alone and probes the sync-insertion
// guard added in f6afa27 / 58d12d5 (SECTOR_ACTIVE).
//
// Question under test: can SECTOR_ACTIVE stick at 1, suppressing the 75 Hz
// sync-insertion DECI for ever?
// ============================================================================
`timescale 1ns/1ps

module tb_cdc_sync;

   // 53.693175 MHz -> 18.6244 ns period
   logic CLK = 0;
   always #9.3122 CLK = ~CLK;

   logic RESET_N = 0;
   logic ENABLE  = 1;

   // sub-CPU CE rise/fall enables (real core: CEGen 12.5 MHz -> S68K_CE_R/F)
   logic CE_R = 0, CE_F = 0;
   int   ph = 0;
   always @(posedge CLK) begin
      CE_R <= 0; CE_F <= 0;
      ph <= (ph == 3) ? 0 : ph + 1;
      if (ph == 0) CE_R <= 1;
      if (ph == 2) CE_F <= 1;
   end
   wire en_tick = CE_R | CE_F;

   // CDC register port (as ASIC drives it)
   logic [7:0] DI   = '0;
   logic       CS_N = 1, RS = 0, RD_N = 1, WR_N = 1;
   logic       HRD_N = 1;
   wire  [7:0] DO;
   wire        INT_N;

   logic [15:0] CD_DI = '0;
   logic        CD_WR = 0;

   wire [7:0]  HDO;
   wire        DTEN_N, WAIT_N;
   wire [15:1] RAM_A_WR;
   wire [15:0] RAM_A_RD, RAM_DO;
   wire        RAM_WE;
   logic [7:0] RAM_DI = '0;

   CDC dut (
      .CLK(CLK), .RESET_N(RESET_N), .ENABLE(ENABLE), .PALSW(1'b0),
      .CLKEN_P(CE_R), .CLKEN_N(CE_F),
      .DI(DI), .DO(DO), .CS_N(CS_N), .RS(RS), .RD_N(RD_N), .WR_N(WR_N),
      .INT_N(INT_N),
      .HDO(HDO), .HRD_N(HRD_N), .DTEN_N(DTEN_N), .WAIT_N(WAIT_N),
      .CD_DI(CD_DI), .CD_WR(CD_WR),
      .RAM_A_WR(RAM_A_WR), .RAM_A_RD(RAM_A_RD), .RAM_DI(RAM_DI),
      .RAM_DO(RAM_DO), .RAM_WE(RAM_WE)
   );

   // ---------------- probes ----------------
   logic [7:0] ifstat_s;
   logic       sect_act;
   always_comb begin
      ifstat_s = dut.IFSTAT;
      sect_act = dut.SECTOR_ACTIVE;
   end

   int deci_falls = 0;
   logic old_deci = 1;
   always @(posedge CLK) begin
      if (old_deci == 1'b1 && ifstat_s[5] == 1'b0) deci_falls++;
      old_deci <= ifstat_s[5];
   end

   // ---------------- helpers ----------------
   task automatic wait_en(input int n);
      int k = 0; while (k < n) begin @(posedge CLK); if (en_tick) k++; end
   endtask

   // one CDC register-port write (RS=0 address port, RS=1 data port)
   task automatic cwr(input bit rs_v, input [7:0] v);
      DI = v; RS = rs_v; CS_N = 0; WR_N = 0;
      wait_en(2);
      WR_N = 1; CS_N = 1;
      wait_en(2);
   endtask
   task automatic sel(input [7:0] r); cwr(1'b0, r); endtask
   task automatic wdat(input [7:0] v); cwr(1'b1, v); endtask

   task automatic crd(input bit rs_v, output [7:0] v);
      RS = rs_v; CS_N = 0; RD_N = 0;
      wait_en(2);
      v = DO;
      RD_N = 1; CS_N = 1;
      wait_en(2);
   endtask
   task automatic rdat(output [7:0] v); crd(1'b1, v); endtask

   task automatic feed_word(input [15:0] w);
      CD_DI = w; CD_WR = 1; wait_en(2); CD_WR = 0; wait_en(2);
   endtask

   task automatic decoder_on();
      sel(8'h0F); wdat(8'h00);          // R15 = soft reset
      sel(8'h0A); wdat(8'h84); wdat(8'hC0);  // CTRL0 = DECEN|WRRQ, CTRL1 = SYIEN|SYDEN
      sel(8'h01); wdat(8'h62);          // IFCTRL = DOUTEN|DECIEN|DTEIEN
   endtask

   // wall-clock windows in CLK cycles: one 75 Hz frame = 715909 clocks
   localparam int FRAME = 715909;

   int base, i;
   logic [7:0] rv0, rv1;
   initial begin
      RESET_N = 0; repeat(50) @(posedge CLK); RESET_N = 1; repeat(50) @(posedge CLK);
      $display("======== CDC sync-insertion review bench ========");

      decoder_on();
      $display("  decoder on: CTRL0=%02h CTRL1=%02h IFSTAT=%02h SECTOR_ACTIVE=%b",
               dut.CTRL0, dut.CTRL1, ifstat_s, sect_act);

      // ---- A: no drive data at all -> free-running sync insertion must fire ----
      base = deci_falls;
      repeat (3*FRAME) @(posedge CLK);
      $display("  [A] idle drive, 3 frames: DECI falling edges = %0d  SECTOR_ACTIVE=%b  %s",
               deci_falls-base, sect_act, ((deci_falls-base) >= 2) ? "PASS" : "FAIL");

      // ---- B: a sector that stops half way, decoder left on ----
      for (i = 0; i < 600; i++) feed_word(16'h1000 + i[15:0]);
      $display("  [B] fed 600/1176 words: WORD_CNT=%0d SECTOR_ACTIVE=%b",
               dut.WORD_CNT, sect_act);
      base = deci_falls;
      repeat (4*FRAME) @(posedge CLK);
      $display("  [B] 4 frames after the truncated sector: DECI falling edges = %0d  SECTOR_ACTIVE=%b  %s",
               deci_falls-base, sect_act,
               ((deci_falls-base) == 0) ? "SYNC INSERTION IS DEAD" : "still alive");

      // ---- C: does anything short of DECEN=0 recover it? finish the sector ----
      for (i = 600; i < 1176; i++) feed_word(16'h2000 + i[15:0]);
      $display("  [C] sector completed: WORD_CNT=%0d SECTOR_ACTIVE=%b IFSTAT=%02h",
               dut.WORD_CNT, sect_act, ifstat_s);
      base = deci_falls;
      repeat (3*FRAME) @(posedge CLK);
      $display("  [C] 3 frames after completion: DECI falling edges = %0d  %s",
               deci_falls-base, ((deci_falls-base) >= 2) ? "recovered" : "still dead");

      // ---- D: DECEN cleared and set again while stuck ----
      for (i = 0; i < 300; i++) feed_word(16'h3000 + i[15:0]);
      $display("  [D] fed 300 words, SECTOR_ACTIVE=%b", sect_act);
      sel(8'h0A); wdat(8'h04); wdat(8'hC0);       // DECEN=0
      wait_en(4);
      $display("  [D] DECEN=0: WORD_CNT=%0d SECTOR_ACTIVE=%b IFSTAT=%02h", dut.WORD_CNT, sect_act, ifstat_s);
      sel(8'h0A); wdat(8'h84); wdat(8'hC0);       // DECEN=1
      base = deci_falls;
      repeat (3*FRAME) @(posedge CLK);
      $display("  [D] 3 frames after DECEN off/on: DECI falling edges = %0d SECTOR_ACTIVE=%b  %s",
               deci_falls-base, sect_act, ((deci_falls-base) >= 2) ? "recovered" : "STILL DEAD");

      // ================= register-readback checks (9846674 / 69e6c15) =================
      $display("---- register readback ----");
      sel(8'h0F); wdat(8'h00);                       // CDC soft reset
      sel(8'h02); wdat(8'h95); wdat(8'hFA);          // DBCL=95, DBCH=FA
      sel(8'h02); rdat(rv0); rdat(rv1);
      $display("  [E] DBCL/DBCH readback = %02h %02h (verificator wants 95 0A)  DBC=%04h", rv0, rv1, dut.DBC);

      sel(8'h12); rdat(rv0); rdat(rv1);
      $display("  [F] AR=0x12 two data-port reads = %02h %02h (want FF FF)", rv0, rv1);

      sel(8'h0F); rdat(rv0); rdat(rv1);
      $display("  [G] AR=0x0F then 0x10: STAT3=%02h then unimplemented=%02h (bit5 must be set: %b)",
               rv0, rv1, rv1[5]);

      sel(8'h1F); rdat(rv0); rdat(rv1);
      $display("  [H] AR=0x1F read=%02h then AR wraps to 0 -> R0 read=%02h (R0 has no decode: stale DO)",
               rv0, rv1);

      // ---- DBCH after a completed host transfer: the "1111" flag is now invisible ----
      sel(8'h0F); wdat(8'h00);                       // reset
      sel(8'h01); wdat(8'h42);                       // IFCTRL = DOUTEN|DTEIEN
      sel(8'h02); wdat(8'h03); wdat(8'h00);          // DBC = 3 -> 4 bytes
      wdat(8'h00); wdat(8'h00);                      // DAC = 0   (AR now 6 = DTTRG)
      wdat(8'h00);                                   // DTTRG
      for (i = 0; i < 8; i++) begin                  // drain the host port
         wait_en(4); HRD_N = 0; wait_en(4); HRD_N = 1; wait_en(4);
      end
      sel(8'h02); rdat(rv0); rdat(rv1);
      $display("  [I] after a completed DMA: DBC=%04h  DBCL=%02h DBCH=%02h  (old RTL returned DBCH=%02h)",
               dut.DBC, rv0, rv1, dut.DBC[15:8]);

      $display("======== done ========");
      $finish;
   end

   initial begin #200000000; $display("WATCHDOG"); $finish; end
endmodule
