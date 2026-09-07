// ============================================================================
// tb_mcd_boot.sv - FAIL-FAST test for the sub-CPU CDC bench.
// Instantiates the whole rtl/MCD/MCD.vhd block (real gate-level sub-CPU MC68K +
// ASIC + CDC + PCM + CDDA), preloads PRG-RAM with the verificator sub BIOS
// (prg_bios.hex, extracted from mcd-verificator.bin), drives the main-side EXT
// reset/exec sequence, and watches the sub-CPU's address bus (DBG_S68K_A) to
// confirm it BOOTS the BIOS and reaches its cmd_rx idle loop. Purpose: measure
// whether the gate-level sub-CPU boots in tractable ModelSim time before building
// the full COMCMD-relay + DMA3 bench.
// ============================================================================
`timescale 1ns/1ps

module tb_mcd_boot;

   // ---- clocks: MCLK 107.386 MHz (sub-CPU sampling), CLK 53.693 MHz (block) ----
   logic MCLK = 0; always #4.657 MCLK = ~MCLK;   // ~107.386 MHz
   logic CLK  = 0; always #9.313 CLK  = ~CLK;    // ~53.693 MHz
   logic RST_N = 0;
   logic ENABLE = 1'b1;

   // EN50: ~50 MHz enable in the MCLK domain (sub clock phase counter, 50/4=12.5MHz)
   logic EN50 = 0; integer acc = 0;
   always @(posedge MCLK) begin
      EN50 <= 1'b0; acc = acc + 50000000;
      if (acc >= 107386350) begin acc = acc - 107386350; EN50 <= 1'b1; end
   end

   // ---- main-side EXT bus ----
   logic [17:1] EXT_VA='0; logic [15:0] EXT_VDI='0; wire [15:0] EXT_VDO;
   logic EXT_AS_N=1'b1, EXT_RNW=1'b1, EXT_LDS_N=1'b1, EXT_UDS_N=1'b1;
   wire  EXT_DTACK_N; logic EXT_ASEL_N=1'b1, EXT_RAS2_N=1'b1, EXT_ROM_N=1'b1, EXT_FDC_N=1'b1;

   // ---- PRG-RAM (behavioural, SDRAM-style RDY handshake) ----
   wire [17:0] PRG_A; wire [15:0] PRG_DO; wire PRG_WRL_N, PRG_WRH_N, PRG_OE_N, PRG_RFS;
   logic [15:0] PRG_DI; logic PRG_RDY = 1'b1;
   logic [15:0] prg [0:262143];
   initial $readmemh("prg_bios.hex", prg);         // sub BIOS at word 0
   // request = any strobe asserted while we are idle (RDY=1); a few CLKs latency
   logic [2:0] prg_cnt = 0; logic prg_busy = 0;
   always @(posedge CLK) begin
      if (!prg_busy) begin
         if (!PRG_OE_N || !PRG_WRL_N || !PRG_WRH_N) begin
            prg_busy <= 1'b1; PRG_RDY <= 1'b0; prg_cnt <= 3;
            if (!PRG_WRL_N) prg[PRG_A[17:0]][7:0]  <= PRG_DO[7:0];
            if (!PRG_WRH_N) prg[PRG_A[17:0]][15:8] <= PRG_DO[15:8];
            PRG_DI <= prg[PRG_A[17:0]];
         end
      end else begin
         if (prg_cnt==0) begin prg_busy <= 1'b0; PRG_RDY <= 1'b1; end
         else prg_cnt <= prg_cnt - 1'b1;
      end
   end

   // ---- word RAM x2 (behavioural) ----
   wire [15:0] WR0_A,WR1_A,WR0_DO,WR1_DO; logic [15:0] WR0_DI,WR1_DI; wire WR0_WE,WR1_WE;
   // (MCD.vhd exposes word RAM only inside; it uses internal spram - not on the entity.
   //  The entity has no word-RAM ports: they are internal. So nothing to model here.)

   // ---- CDC sector feed ----
   logic [15:0] CDC_DATA='0; logic CDC_DAT_WR=0;

   // ---- PCM RAM (behavioural) ----
   wire [15:0] PCMRAM_A; wire [7:0] PCMRAM_DO; logic [7:0] PCMRAM_DI='0;
   wire PCMRAM_RD, PCMRAM_WR; logic PCMRAM_BUSY=0;
   logic [7:0] pcmram [0:65535];
   always @(posedge CLK) begin
      if (PCMRAM_WR) pcmram[PCMRAM_A] <= PCMRAM_DO;
      PCMRAM_DI <= pcmram[PCMRAM_A];
   end

   // ---- misc outputs ----
   wire MCD_RST_N; wire [15:0] PCM_SL,PCM_SR; wire signed [15:0] CDDA_SL,CDDA_SR;
   wire ROM_CE_N; wire [12:0] dummy; wire LED_RED,LED_GREEN,CDDA_WR_READY,GG_AVAILABLE;
   wire [13:1] BRAM_A; wire [7:0] BRAM_DO; wire BRAM_WE;
   wire [39:0] CDD_COMM; wire CDD_SEND;
   // ---- sub-CPU observation ----
   wire DBG_S68K_AS_N, DBG_S68K_DTACK_N, DBG_S68K_RNW, DBG_S68K_CE_F;
   wire DBG_PCM_SMP_CE,DBG_PCM_OUT_CE,DBG_PCM_LATE,DBG_PCM_WE_N,DBG_PCM_CS_N;
   wire [23:0] DBG_S68K_A;

   MCD dut (
      .CLK(CLK), .MCLK(MCLK), .RST_N(RST_N), .ENABLE(ENABLE), .EN50(EN50),
      .MCD_RST_N(MCD_RST_N), .PALSW(1'b0),
      .EXT_VA(EXT_VA), .EXT_VDI(EXT_VDI), .EXT_VDO(EXT_VDO),
      .EXT_AS_N(EXT_AS_N), .EXT_RNW(EXT_RNW), .EXT_LDS_N(EXT_LDS_N), .EXT_UDS_N(EXT_UDS_N),
      .EXT_DTACK_N(EXT_DTACK_N), .EXT_ASEL_N(EXT_ASEL_N), .EXT_VCLK_CE(1'b0),
      .EXT_RAS2_N(EXT_RAS2_N), .EXT_ROM_N(EXT_ROM_N), .EXT_FDC_N(EXT_FDC_N),
      .PRG_A(PRG_A), .PRG_DI(PRG_DI), .PRG_DO(PRG_DO),
      .PRG_WRL_N(PRG_WRL_N), .PRG_WRH_N(PRG_WRH_N), .PRG_OE_N(PRG_OE_N),
      .PRG_RFS(PRG_RFS), .PRG_RDY(PRG_RDY),
      .ROM_DI(16'h0), .ROM_CE_N(ROM_CE_N), .ROM_RDY(1'b1),
      .BRAM_A(BRAM_A), .BRAM_DI(8'h0), .BRAM_DO(BRAM_DO), .BRAM_WE(BRAM_WE),
      .CDD_STAT(40'h0), .CDD_COMM(CDD_COMM), .CDD_SEND(CDD_SEND), .CDD_REC(1'b0), .CDD_DM(1'b0),
      .CDC_DATA(CDC_DATA), .CDC_DAT_WR(CDC_DAT_WR), .CDC_SC_WR(1'b0), .CDC_CDDA_WR(1'b0),
      .CDDA_WR_READY(CDDA_WR_READY),
      .PCMRAM_A(PCMRAM_A), .PCMRAM_DO(PCMRAM_DO), .PCMRAM_DI(PCMRAM_DI),
      .PCMRAM_RD(PCMRAM_RD), .PCMRAM_WR(PCMRAM_WR), .PCMRAM_BUSY(PCMRAM_BUSY),
      .PCM_SL(PCM_SL), .PCM_SR(PCM_SR), .CDDA_SL(CDDA_SL), .CDDA_SR(CDDA_SR),
      .LED_RED(LED_RED), .LED_GREEN(LED_GREEN),
      .GG_RESET(1'b0), .GG_EN(1'b0), .GG_CODE(129'h0), .GG_AVAILABLE(GG_AVAILABLE),
      .DBG_S68K_AS_N(DBG_S68K_AS_N), .DBG_S68K_DTACK_N(DBG_S68K_DTACK_N),
      .DBG_S68K_RNW(DBG_S68K_RNW), .DBG_PCM_SMP_CE(DBG_PCM_SMP_CE), .DBG_PCM_OUT_CE(DBG_PCM_OUT_CE),
      .DBG_PCM_LATE(DBG_PCM_LATE), .DBG_PCM_WE_N(DBG_PCM_WE_N), .DBG_PCM_CS_N(DBG_PCM_CS_N),
      .DBG_S68K_CE_F(DBG_S68K_CE_F), .DBG_S68K_A(DBG_S68K_A)
   );

   // ---- EXT write task (main-side gate-array reg write) ----
   localparam int TO = 200000;
   task automatic ext_wr(input int addr, input [15:0] val, input bit uds, input bit lds);
      int t;
      @(posedge CLK); #1;
      EXT_VA='0; EXT_VA[5:1] = ((addr-'h12000)>>1);
      EXT_FDC_N=1'b0; EXT_ASEL_N=1'b1; EXT_RAS2_N=1'b1; EXT_ROM_N=1'b1;
      EXT_VDI=val; EXT_RNW=1'b0; EXT_UDS_N=~uds; EXT_LDS_N=~lds; EXT_AS_N=1'b0;
      t=0; while (EXT_DTACK_N!==1'b0 && t<TO) begin @(posedge CLK); t++; end
      repeat(3) @(posedge CLK);
      EXT_AS_N=1'b1; EXT_UDS_N=1'b1; EXT_LDS_N=1'b1; EXT_RNW=1'b1; EXT_FDC_N=1'b1;
      repeat(8) @(posedge CLK);
   endtask

   // ---- sub-CPU activity monitor: count distinct S68K addresses seen, track PC region ----
   int  sub_cycles = 0; logic [23:0] a_last = '1; logic [23:0] a_min='1, a_max=0;
   always @(posedge MCLK) if (DBG_S68K_AS_N==1'b0 && DBG_S68K_A!==a_last) begin
      a_last <= DBG_S68K_A; sub_cycles++;
      if (DBG_S68K_A < a_min) a_min <= DBG_S68K_A;
      if (DBG_S68K_A > a_max) a_max <= DBG_S68K_A;
   end

   initial begin
      RST_N=1'b0; repeat(50) @(posedge CLK); RST_N=1'b1; repeat(50) @(posedge CLK);
      $display("======== MCD sub-CPU boot test ========");
      // main-side reset/exec sequence (mcd.c mcdReset + mcdExec), PRG-RAM preloaded:
      ext_wr('h12002, 16'hFF00, 1'b1, 1'b0);   // MEM_WP = 0xFF00
      ext_wr('h12000, 16'h0003, 1'b0, 1'b1);   // RST = BUSREQ|RES0
      ext_wr('h12000, 16'h0002, 1'b0, 1'b1);   // RST = BUSREQ
      ext_wr('h12000, 16'h0000, 1'b0, 1'b1);   // RST = 0
      ext_wr('h1200E, 16'h0000, 1'b1, 1'b0);   // CFLAG_MC = 0
      ext_wr('h12002, 16'h0000, 1'b1, 1'b0);   // MEM_WP = 0
      ext_wr('h12000, 16'h0001, 1'b0, 1'b1);   // RST = RES0 -> sub runs
      // let the sub-CPU boot; sample its activity periodically
      for (int k=0;k<20;k++) begin
         repeat(20000) @(posedge MCLK);
         $display("  t=%0t  sub bus cycles=%0d  A range %06h..%06h  last=%06h",
                  $time, sub_cycles, a_min, a_max, a_last);
      end
      $display("======== boot test done: sub_cycles=%0d ========", sub_cycles);
      $finish;
   end

   initial begin #200000000; $display("WATCHDOG"); $finish; end
endmodule
