// ============================================================================
// tb_m68k_timing.sv - main-CPU (Mega Drive 68000) bus-cycle timing bench.
//
// Instantiates the SAME gate-level Nuked 68000 (rtl/nuked-md/68k.v, module
// m68kcpu) that md_board.v uses for the Mega Drive main CPU, wrapped in a
// minimal md_board-shaped bus:
//
//   * MCLK2 = 107.386350 MHz (the pin the model samples CLK on, as md_board does)
//   * CLK   = VCLK = MCLK2/14 = 7.670454 MHz (MCLK/7, the real main-CPU clock),
//     driven as a level out of an MCLK2-clocked phase counter, exactly like the
//     VDP-generated VCLK in md_board (md_board.v:854).
//   * bus outputs (VA/VD/AS/UDS/LDS/RW) and DTACK registered at MCLK2, as in
//     md_board.v:782-830 -- so the bus round trip has md_board's own latency.
//   * memory acknowledges immediately => 0 wait states everywhere.
//
// Purpose: measure, rather than look up, how many main-CPU clocks separate the
// write bus cycle of `move.b #$01,(a1)` (a1=$00A12000, the mcd-verificator IRQ
// TEST 0A arming write) from the read bus cycle of `move.w $0026(a0),d1`
// (a0=$00A12000, the COMSTAT3 sample), i.e. mcd-verificator ROM 0x018458..0x01846E.
//
//   +prog=0  the real subtest-0A loop body (ROM 0x01844E..0x018482); also prints
//            the deadline measured through the gate-array model below
//   +prog=1  isolated instruction blocks, for cross-checking the bench against
//            the MC68000UM instruction-timing tables
//   +prog=2  the tail of mcdRD8 (ROM $D58E..$D5A0) + the return to $018452: the
//            main-CPU path from the sub clearing STA_BSY to the arming write
//   +prog=3  the sub CPU's own dispatcher instructions (sub $021C and the idle
//            spin at $0222..$022A) run on the same 68000, to time them exactly
//   +iters=N stop after N loop iterations (prog 0)
//   +fine=1 +flo=A +fhi=B   per-MCLK2-edge dump between CPU clocks A and B
//
//   ./compile.sh && ./run.sh <prog> [iters]
// ============================================================================
`timescale 1ns/1ps

module tb_m68k_timing;

   // ---------------------------------------------------------------- clocks
   // MCLK  = 53.693175 MHz, MCLK2 = 107.386350 MHz -> 9.31219... ns period
   localparam real MCLK2_HALF = 4.656095;      // ns
   localparam real VCLK_PERIOD = 14.0*2.0*MCLK2_HALF;   // 130.3706 ns = 7.670454 MHz

   logic MCLK2 = 0;
   always #(MCLK2_HALF) MCLK2 = ~MCLK2;

   // VCLK: MCLK2/14 phase counter, level fed to the model's CLK pin.
   reg [3:0] phase = 0;
   reg       vclk  = 1;
   integer   clk_idx = 0;                  // CPU clock number (differences only)

   always @(posedge MCLK2) begin
      if (phase == 13) begin
         phase   <= 0;
         vclk    <= 1'b1;
         clk_idx <= clk_idx + 1;
      end else begin
         phase <= phase + 1'b1;
         if (phase == 6) vclk <= 1'b0;     // high for phases 0..6, low for 7..13
      end
   end

   wire CLK = vclk;

   // ------------------------------------------------------------- CPU pins
   logic RESET_i = 0, HALT_i = 0;
   wire  RESET_pull, HALT_pull;
   logic [15:0] DATA_i;
   wire  [15:0] DATA_o;
   wire  DATA_z, E_CLK, BG, FC_z, RW, RW_z, ADDRESS_z, AS, LDS, UDS, strobe_z;
   wire  [2:0]  FC;
   wire  [22:0] ADDRESS;
   logic DTACK = 1'b1;                     // active low, registered at MCLK2

   m68kcpu cpu (
      .MCLK       (MCLK2),
      .CLK        (CLK),
      .VPA        (1'b1),
      .BR         (1'b1),
      .BGACK      (1'b1),
      .DTACK      (DTACK),
      .IPL        (3'b111),
      .BERR       (1'b1),
      .RESET_i    (RESET_i),
      .RESET_pull (RESET_pull),
      .HALT_i     (HALT_i),
      .HALT_pull  (HALT_pull),
      .DATA_i     (DATA_i),
      .DATA_o     (DATA_o),
      .DATA_z     (DATA_z),
      .E_CLK      (E_CLK),
      .BG         (BG),
      .FC         (FC),
      .FC_z       (FC_z),
      .RW         (RW),
      .RW_z       (RW_z),
      .ADDRESS    (ADDRESS),
      .ADDRESS_z  (ADDRESS_z),
      .AS         (AS),
      .LDS        (LDS),
      .UDS        (UDS),
      .strobe_z   (strobe_z)
   );

   // Pin levels as the board sees them (released pins read as pulled up).
   wire AS_pin  = strobe_z | AS;
   wire UDS_pin = strobe_z | UDS;
   wire LDS_pin = strobe_z | LDS;
   wire RW_pin  = RW_z | RW;

   // ------------------------------------------- md_board-shaped bus registers
   reg [22:0] VA  = 0;
   reg [15:0] VD  = 0;
   reg        r_AS = 1'b1, r_UDS = 1'b1, r_LDS = 1'b1, r_RW = 1'b1;

   // memory
   logic [15:0] rom [0:65535];             // $000000-$01FFFF
   logic [15:0] ram [0:32767];             // $FF0000-$FFFFFF
   logic [15:0] io  [0:31];                // $A12000-$A1203F

   wire [23:0] ba = {VA, 1'b0};            // byte address on the registered bus
   wire        is_rom = (ba < 24'h020000);
   wire        is_ram = (ba >= 24'hFF0000);
   wire        is_io  = (ba >= 24'hA12000) && (ba < 24'hA12040);

   // gate-array model state (declared here: the bus block reads asic_reg_dtack_n)
   reg asic_ph = 1'b0;                      // ASIC CLK = MCLK2/2 = 53.693 MHz
   reg asic_reg_dtack_n = 1'b1;
   reg [15:0] asic_reg_do = 16'h0;
   reg asic_int_pend2 = 1'b0;
   int  k_int_pend = -1, k_snap = -1;
   real t_int_pend = 0.0, t_snap = 0.0;

   logic [15:0] mem_q;
   always @* begin
      if      (is_rom) mem_q = rom[ba[16:1]];
      else if (is_ram) mem_q = ram[ba[15:1]];
      else if (is_io ) mem_q = io[ba[5:1]];
      else             mem_q = 16'h0000;
   end

   always @(posedge MCLK2) begin
      VA    <= ADDRESS;
      r_AS  <= AS_pin;
      r_UDS <= UDS_pin;
      r_LDS <= LDS_pin;
      r_RW  <= RW_pin;
      // resolved data bus: CPU drives during writes, memory otherwise
      VD    <= DATA_z ? mem_q : DATA_o;
      // /DTACK: the ASIC model drives it for $A120xx, a fast device elsewhere
      DTACK <= is_io ? asic_reg_dtack_n : AS_pin;
      // write capture (data valid once a data strobe is asserted)
      if (!r_AS && !r_RW && (!r_UDS || !r_LDS)) begin
         if (is_ram) begin
            if (!r_UDS) ram[ba[15:1]][15:8] <= VD[15:8];
            if (!r_LDS) ram[ba[15:1]][ 7:0] <= VD[ 7:0];
         end else if (is_io) begin
            if (!r_UDS) io[ba[5:1]][15:8] <= VD[15:8];
            if (!r_LDS) io[ba[5:1]][ 7:0] <= VD[ 7:0];
         end
      end
   end

   always @* DATA_i = VD;

   // ---------------------------------------------------------------------------
   // Miniature, faithful model of the Mega CD gate array's main-side register port
   // (rtl/MCD/ASIC.vhd:561 for M68K_GA_SEL and :563-773 for the register process).
   // It exists only to time the two events that bracket the sub-CPU's deadline:
   //   * INT_PEND(2) <= '1'   on the arming write to $A12000 (ASIC.vhd:615-616)
   //   * M68K_REG_DO <= CS(3) on the read of  $A12026        (ASIC.vhd:757)
   // Both happen on the FIRST 53.69 MHz CLK edge of their bus cycle at which
   // M68K_GA_SEL is high and M68K_REG_DTACK_N is still '1' - i.e. at S4 of a write
   // (data strobes assert in S4) and at S2 of a read (they assert with /AS).
   // ---------------------------------------------------------------------------
   wire asic_ga_sel = (!r_AS) && (!r_UDS || !r_LDS) && is_io;

   always @(posedge MCLK2) begin
      asic_ph <= ~asic_ph;
      if (asic_ph) begin                    // every other MCLK2 edge = the ASIC's CLK
         if (asic_ga_sel && asic_reg_dtack_n) begin
            if (!r_RW) begin
               if (ba == 24'hA12000 && !r_UDS && VD[8]) begin
                  asic_int_pend2 <= 1'b1;
                  k_int_pend = clk_idx;  t_int_pend = $realtime;
               end
            end else begin
               asic_reg_do <= mem_q;        // stands in for CS(3) etc.
               if (ba == 24'hA12026 && k_int_pend >= 0) begin
                  k_snap = clk_idx;  t_snap = $realtime;
                  $display("");
                  $display("  ASIC: INT_PEND(2)<='1' at CPU clock %0d (t=%.1f ns)", k_int_pend, t_int_pend);
                  $display("  ASIC: M68K_REG_DO<=CS(3) at CPU clock %0d (t=%.1f ns)", k_snap, t_snap);
                  $display("  ==> DEADLINE for the sub CPU = %0d main clocks = %.1f ns  (measured %.1f ns)",
                           k_snap-k_int_pend, (k_snap-k_int_pend)*VCLK_PERIOD, t_snap-t_int_pend);
                  k_int_pend = -1;
               end
            end
            asic_reg_dtack_n <= 1'b0;
         end else if (!asic_reg_dtack_n && r_AS) begin
            asic_reg_dtack_n <= 1'b1;
         end
      end
   end

   // ------------------------------------------------------------- program
   int PROG = 0, ITERS = 4;
   bit TRACE = 1;

   task automatic w(input int a, input [15:0] v); rom[a>>1] = v; endtask

   initial begin
      int i;
      for (i=0;i<65536;i++) rom[i] = 16'h0000;
      for (i=0;i<32768;i++) ram[i] = 16'h0000;
      for (i=0;i<32;i++)    io[i]  = 16'h0000;

      void'($value$plusargs("prog=%d",  PROG));
      void'($value$plusargs("iters=%d", ITERS));
      void'($value$plusargs("trace=%d", TRACE));

      // reset vectors
      w(24'h000000, 16'h00FF); w(24'h000002, 16'h8000);   // SSP = $00FF8000
      w(24'h000004, 16'h0001); w(24'h000006, 16'h8420);   // PC  = $00018420

      // pointer the verificator keeps at $000196A4 : $00A12000
      w(24'h0196A4, 16'h00A1); w(24'h0196A6, 16'h2000);

      // COMSTAT3 ($A12026) already holds the value the sub would have written
      io[5'h13] = 16'h0002;                                // $A12026

      if (PROG == 0) begin
         // ---- init -------------------------------------------------------
         w(24'h018420, 16'h49F9); w(24'h018422, 16'h0001); w(24'h018424, 16'h8600); // lea $18600,a4
         w(24'h018426, 16'h95CA);                                                   // suba.l a2,a2
         w(24'h018428, 16'h6000); w(24'h01842A, 16'h0024);                          // bra $01844E
         // ---- verificator IRQ TEST 0A loop body, verbatim from ROM --------
         w(24'h01844E, 16'h42A7);                                                   // clr.l -(a7)
         w(24'h018450, 16'h4E94);                                                   // jsr (a4)
         w(24'h018452, 16'h2279); w(24'h018454, 16'h0001); w(24'h018456, 16'h96A4); // movea.l ($196A4).l,a1
         w(24'h018458, 16'h12BC); w(24'h01845A, 16'h0001);                          // move.b #$01,(a1)
         w(24'h01845C, 16'h4E71); w(24'h01845E, 16'h4E71); w(24'h018460, 16'h4E71);
         w(24'h018462, 16'h4E71); w(24'h018464, 16'h4E71); w(24'h018466, 16'h4E71); // 6 x nop
         w(24'h018468, 16'h2079); w(24'h01846A, 16'h0001); w(24'h01846C, 16'h96A4); // movea.l ($196A4).l,a0
         w(24'h01846E, 16'h3228); w(24'h018470, 16'h0026);                          // move.w $0026(a0),d1
         w(24'h018472, 16'h588F);                                                   // addq.l #4,a7
         w(24'h018474, 16'h0C41); w(24'h018476, 16'h0002);                          // cmpi.w #$0002,d1
         w(24'h018478, 16'h6600); w(24'h01847A, 16'h016C);                          // bne $0185E6
         w(24'h01847C, 16'h528A);                                                   // addq.l #1,a2
         w(24'h01847E, 16'hB4FC); w(24'h018480, 16'h00FF);                          // cmpa.w #$00FF,a2
         w(24'h018482, 16'h63CA);                                                   // bls $01844E
         w(24'h0185E6, 16'h60FE);                                                   // bra * (error)
         w(24'h018600, 16'h4E75);                                                   // rts (mcdRD8 stub)
      end else if (PROG == 2) begin
         // ---- the real main-side exit path of mcdRD8 -----------------------
         // ROM $D58E..$D5A0 is the tail of mcdRD8 ($D564): the last poll of
         // STA_BSY, then the return to the subtest-0A loop body at $018452.
         // Measured from the poll read that sees STA_BSY=0 (i.e. from the sub
         // clearing it) to the IFL2 arming write.
         ram[16'h8034>>1] = 16'h00A1;  ram[16'h8036>>1] = 16'h2020;   // ($FF8034)=$00A12020
         ram[16'h8058>>1] = 16'h00A1;  ram[16'h805A>>1] = 16'h2022;   // ($FF8058)=$00A12022
         w(24'h018420, 16'h2279); w(24'h018422, 16'h00FF); w(24'h018424, 16'h8034); // movea.l ($FF8034).l,a1
         w(24'h018426, 16'h4879); w(24'h018428, 16'h0001); w(24'h01842A, 16'h8452); // pea $00018452
         w(24'h01842C, 16'h4EF9); w(24'h01842E, 16'h0000); w(24'h018430, 16'hD58E); // jmp $0000D58E
         w(24'h00D58E, 16'h3211);                                                   // move.w (a1),d1
         w(24'h00D590, 16'h66FC);                                                   // bne.s $D58E
         w(24'h00D592, 16'h2279); w(24'h00D594, 16'h00FF); w(24'h00D596, 16'h8058); // movea.l ($FF8058).l,a1
         w(24'h00D598, 16'h1011);                                                   // move.b (a1),d0
         w(24'h00D59A, 16'h0280); w(24'h00D59C, 16'h0000); w(24'h00D59E, 16'h00FF); // andi.l #$FF,d0
         w(24'h00D5A0, 16'h4E75);                                                   // rts
         w(24'h018452, 16'h2279); w(24'h018454, 16'h0001); w(24'h018456, 16'h96A4); // movea.l ($196A4).l,a1
         w(24'h018458, 16'h12BC); w(24'h01845A, 16'h0001);                          // move.b #$01,(a1)
         w(24'h01845C, 16'h60FE);                                                   // bra *
      end else if (PROG == 3) begin
         // ---- sub-CPU dispatcher instructions, run on the same 68000 -------
         // G: 8 x move.w #$0000,$8020   (sub $021C: clears STA_BSY)
         for (i=0;i<8;i++) begin w(24'h018420+6*i, 16'h31FC); w(24'h018422+6*i, 16'h0000); w(24'h018424+6*i, 16'h8020); end
         // H: 8 x cmpi.w #$0000,$8010   (sub $0222)
         for (i=0;i<8;i++) begin w(24'h018450+6*i, 16'h0C78); w(24'h018452+6*i, 16'h0000); w(24'h018454+6*i, 16'h8010); end
         // I: the sub's idle spin loop, sub $0222..$022A, verbatim
         w(24'h018480, 16'h0C78); w(24'h018482, 16'h0000); w(24'h018484, 16'h8010); // cmpi.w #$0000,$8010
         w(24'h018486, 16'h6700); w(24'h018488, 16'hFFF8);                          // beq.w  $018480
      end else begin
         // ---- isolated blocks for MC68000UM cross-checks -------------------
         w(24'h018420, 16'h227C); w(24'h018422, 16'h00A1); w(24'h018424, 16'h2000); // movea.l #$00A12000,a1
         w(24'h018426, 16'h207C); w(24'h018428, 16'h00A1); w(24'h01842A, 16'h2000); // movea.l #$00A12000,a0
         // A: 8 x nop                                             $01842C..$01843B
         for (i=0;i<8;i++) w(24'h01842C + 2*i, 16'h4E71);
         // B: 8 x move.b #$01,(a1)   MC68000UM 12(2/1)            $01843C..$01845B
         for (i=0;i<8;i++) begin w(24'h01843C + 4*i, 16'h12BC); w(24'h01843E + 4*i, 16'h0001); end
         // C: 8 x move.w $0026(a0),d1  MC68000UM 12(3/0)          $01845C..$01847B
         for (i=0;i<8;i++) begin w(24'h01845C + 4*i, 16'h3228); w(24'h01845E + 4*i, 16'h0026); end
         // D: 8 x movea.l ($196A4).l,a0                           $01847C..$0184AB
         for (i=0;i<8;i++) begin w(24'h01847C + 6*i, 16'h2079); w(24'h01847E + 6*i, 16'h0001); w(24'h018480 + 6*i, 16'h96A4); end
         // E: 8 x move.w (a0),d1     MC68000UM 8(2/0)             $0184AC..$0184BB
         for (i=0;i<8;i++) w(24'h0184AC + 2*i, 16'h3210);
         // F: 8 x move.b d1,(a1)     MC68000UM 8(1/1)             $0184BC..$0184CB
         for (i=0;i<8;i++) w(24'h0184BC + 2*i, 16'h1281);
         w(24'h0184CC, 16'h60FE);                                                   // bra *
      end
   end

   // ------------------------------------------------- fine (MCLK2) edge dump
   // +fine=1 prints every MCLK2 edge between +flo and +fhi CPU clocks, so the
   // S0..S7 alignment of /AS, /UDS, /LDS can be read off directly instead of
   // assumed.
   bit FINE = 0; int FLO = 200, FHI = 215;
   initial begin
      void'($value$plusargs("fine=%d", FINE));
      void'($value$plusargs("flo=%d",  FLO));
      void'($value$plusargs("fhi=%d",  FHI));
   end
   always @(posedge MCLK2) begin
      if (FINE && clk_idx >= FLO && clk_idx <= FHI)
         $display("FINE clk=%0d ph=%0d CLKseen=%0d AS=%0d UDS=%0d LDS=%0d RW=%0d A=%06h D=%04h",
                  clk_idx, phase, vclk, AS_pin, UDS_pin, LDS_pin, RW_pin, {ADDRESS,1'b0}, DATA_o);
   end

   // -------------------------------------------------------- bus-cycle probe
   // A 68000 bus cycle is 4 CPU clocks: /AS asserts in S1 (low half of the first
   // clock) and negates at the start of S7 (low half of the fourth clock).
   reg  as_q = 1'b1;
   int  cyc_k0, ncyc = 0;
   logic [23:0] cyc_addr;
   logic cyc_rw, cyc_uds, cyc_lds;

   // recorded events of interest
   int  k_write_last  = -1;   // last clock of the $A12000 write bus cycle
   int  k_write_first = -1;
   int  k_read_first  = -1;   // first clock of the $A12026 read bus cycle
   int  k_read_last   = -1;
   int  iter = 0;
   int  n_report = 0;

   // full trace
   int  tr_k0 [0:4095];
   int  tr_k1 [0:4095];
   logic [23:0] tr_a [0:4095];
   logic tr_rw [0:4095];
   logic [15:0] tr_d [0:4095];
   logic [1:0]  tr_ds [0:4095];

   always @(posedge MCLK2) begin
      // /AS is asserted at the rising edge entering S2 and negated at the falling
      // edge entering S7 (verified with +fine, see README), so the clock in which
      // /AS falls is S2/S3 -> the cycle's first clock (S0/S1) is one earlier, and
      // the clock in which /AS rises is the cycle's last clock (S6/S7).
      if (as_q && !AS_pin) begin              // /AS falling: S2 of a new cycle
         cyc_k0   = clk_idx - 1;              // S0/S1
         cyc_addr = {ADDRESS, 1'b0};
         cyc_rw   = RW_pin;
      end
      if (!as_q && AS_pin) begin              // /AS rising: start of S7
         if (ncyc < 4096) begin
            tr_k0[ncyc] = cyc_k0;
            tr_k1[ncyc] = clk_idx;
            tr_a [ncyc] = cyc_addr;
            tr_rw[ncyc] = cyc_rw;
            tr_d [ncyc] = VD;
            tr_ds[ncyc] = {r_UDS, r_LDS};
         end
         ncyc = ncyc + 1;

         if (cyc_addr == 24'hA12000 && cyc_rw == 1'b0) begin
            k_write_first = cyc_k0;
            k_write_last  = clk_idx;
         end
         if (cyc_addr == 24'hA12026 && cyc_rw == 1'b1 && k_write_last >= 0 && k_read_first < 0) begin
            k_read_first = cyc_k0;
            k_read_last  = clk_idx;
            iter = iter + 1;
            $display("");
            $display("iteration %0d:", iter);
            $display("  write bus cycle $A12000 : clocks %0d..%0d", k_write_first, k_write_last);
            $display("  read  bus cycle $A12026 : clocks %0d..%0d", k_read_first,  k_read_last);
            $display("  write S0 -> read S0                       = %0d clocks = %.1f ns",
                     k_read_first-k_write_first, (k_read_first-k_write_first)*VCLK_PERIOD);
            $display("  LAST clock of write -> FIRST clock of read = %0d clocks = %.1f ns",
                     k_read_first-k_write_last, (k_read_first-k_write_last)*VCLK_PERIOD);
            $display("  clocks strictly between the two cycles     = %0d clocks = %.1f ns",
                     k_read_first-k_write_last-1, (k_read_first-k_write_last-1)*VCLK_PERIOD);
            $display("  write /DS asserted (S4 of write) -> read data latched (S6/S7 of read)");
            $display("      = %0d clocks + 7 MCLK2 = %.1f ns",
                     (k_read_last-(k_write_first+2)), (k_read_last-(k_write_first+2))*VCLK_PERIOD + 7.0*2.0*MCLK2_HALF);
            k_write_last = -1;
         end
         if (cyc_addr == 24'hA12026 && cyc_rw == 1'b1) k_read_first = -1;
      end
      as_q <= AS_pin;
   end

   // ------------------------------------------------------------------ run
   int guard;
   initial begin
      RESET_i = 0; HALT_i = 0;
      repeat (60) @(posedge CLK);
      RESET_i = 1; HALT_i = 1;

      if (PROG == 0) begin
         guard = 0;
         while (iter < ITERS && guard < 200000) begin @(posedge CLK); guard++; end
      end else begin
         repeat (900) @(posedge CLK);
      end

      dump_trace();
      $finish;
   end

   task automatic dump_trace();
      int i;
      $display("");
      $display("---- bus cycles (clk index, 1 clk = %.4f ns @ 7.670454 MHz) ----", VCLK_PERIOD);
      $display("  #   clk0  clk1  len  R/W  address   UDS LDS  data   dclk");
      for (i=0; i<ncyc && i<4096; i++) begin
         $display("%4d %6d %5d %4d   %s   %06h    %0d   %0d   %04h   %0d",
                  i, tr_k0[i], tr_k1[i], tr_k1[i]-tr_k0[i]+1,
                  tr_rw[i] ? "R" : "W", tr_a[i], tr_ds[i][1], tr_ds[i][0], tr_d[i],
                  (i>0) ? tr_k0[i]-tr_k0[i-1] : 0);
      end
      $display("---- %0d bus cycles ----", ncyc);
   endtask

endmodule
