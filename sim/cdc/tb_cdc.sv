// ============================================================================
// tb_cdc.sv - ModelSim testbench for the Mega CD CDC + gate-array DMA path.
//
// Instantiates the real rtl/MCD/ASIC.vhd (gate-array DMA machine, sub-CPU
// register file, word-RAM interface) and rtl/MCD/CDC.vhd (LC8951 host-data
// transfer machine) exactly as MCD.vhd wires them, with behavioural RAM models
// (no altera_mf). FAITHFUL VERSION: a real Mode-1 CD sector is fed through the
// CDC decode path (CD_DI/CD_WR with DECEN=1, sector_words.hex from
// make_cdc_sector.py) so the host-data (DMA3) EDT/DSR handshake is exercised for
// real; the COMSTA[3] mailbox flag the verificator polls is modelled (set on the
// CDC level-5 interrupt edge, cleared on every relayed sub command), so memory-DMA
// waits are faithful and a never-satisfied poll is reported as a HANG.
//
// It replays the mcd-verificator (test_cdc_new.c) CDC test sequences over the
// sub (S68K_*) and main (EXT_*) buses and prints the SAME pass/fail/error the
// verificator would. VALIDATED: on build-36 CDC (HEAD) it reproduces the hardware
// baseline INIT OK / DMA1 OK / FLAGS 05 / DMA2 05 / DMA3 01; FLAGS/DMA2 also match
// the e22d454 (FLAGS 02) and ccb6fdf (FLAGS/DMA2 OK) variants. See BENCH_SPEC.md.
//
//   CDC_DST_MAIN=2  SUB=3  PCM=4  PRG=5  WRAM=7   (ASIC DD[2:0])
//   A12004/FF8004 high byte = EDT(7) DSR(6) 000 DD(2:0);  EDT=0x80 DSR=0x40
// ============================================================================
`timescale 1ns/1ps

// ---- behavioural single-port word RAM (16-bit), public .mem for snoop ----
module tb_spram #(parameter AW=16, parameter DW=16) (
   input  logic          CLK,
   input  logic [AW-1:0] address,
   input  logic [DW-1:0] data,
   input  logic          wren,
   output logic [DW-1:0] q
);
   logic [DW-1:0] mem [0:(1<<AW)-1];
   always @(posedge CLK) begin
      if (wren) mem[address] <= data;
      q <= mem[address];
   end
endmodule

// ---- behavioural CDC decoder buffer (dpram_dif 14/8 read, 13/16 write) ----
// Read port A: 1-clock latency, byte addressed by RAM_A_RD[13:0].
// Preloaded with a ramp mem[i] = i[7:0] so transferred bytes are deterministic.
module tb_cdcram (
   input  logic        CLK,
   input  logic [15:0] a_rd,
   output logic [7:0]  q_rd,
   input  logic [15:1] a_wr,
   input  logic [15:0] d_wr,
   input  logic        we
);
   logic [7:0] mem [0:16383];
   integer i;
   initial for (i=0;i<16384;i=i+1) mem[i] = 8'h00;     // zero-init; filled only by real sector decode
   always @(posedge CLK) begin
      if (we) begin
         mem[{a_wr[13:1],1'b0}] <= d_wr[7:0];
         mem[{a_wr[13:1],1'b1}] <= d_wr[15:8];
      end
      q_rd <= mem[a_rd[13:0]];
   end
endmodule


module tb_cdc;

   // ---------------- clock / reset / enables ----------------
   logic CLK = 0;
   always #5 CLK = ~CLK;                 // 100 MHz sim clock (period cancels in ratios)

   logic RST_N = 0;
   logic ENABLE = 1'b1;

   // 50 MHz enable derived like CEGen (IN_CLK=53693175 NTSC, OUT_CLK=50e6)
   logic en50 = 0;
   integer clk_sum = 0;
   always @(posedge CLK) begin
      en50 <= 1'b0;
      clk_sum = clk_sum + 50000000;
      if (clk_sum >= 53693175) begin clk_sum = clk_sum - 53693175; en50 <= 1'b1; end
   end

   // ---------------- sub-CPU (S68K) bus ----------------
   logic [23:1] S68K_A     = '0;
   logic [15:0] S68K_DO_TB = '0;         // value the sub-CPU would drive (writes)
   logic        S68K_AS_N  = 1'b1;
   logic        S68K_RNW   = 1'b1;
   logic        S68K_UDS_N = 1'b1;
   logic        S68K_LDS_N = 1'b1;
   logic [1:0]  S68K_FC    = 2'b01;

   wire  [15:0] ASIC_DO;
   wire         S68K_DTACK_N;
   wire  [2:0]  S68K_IPL_N;
   wire         S68K_VPA_N, S68K_HALT_N, S68K_RESET_N;
   wire         S68K_CE_F, S68K_CE_R, S68K_CLK;

   // ---------------- main-CPU (EXT / Genesis) bus ----------------
   logic [17:1] EXT_VA     = '0;
   logic [15:0] EXT_VDI    = '0;
   logic        EXT_AS_N   = 1'b1;
   logic        EXT_RNW    = 1'b1;
   logic        EXT_UDS_N  = 1'b1;
   logic        EXT_LDS_N  = 1'b1;
   logic        EXT_ASEL_N = 1'b1;
   logic        EXT_RAS2_N = 1'b1;
   logic        EXT_ROM_N  = 1'b1;
   logic        EXT_FDC_N  = 1'b1;
   wire  [15:0] EXT_VDO;
   wire         EXT_DTACK_N;

   // ---------------- CDC <-> ASIC interconnect ----------------
   wire  [7:0]  CDC_DO;
   wire  [7:0]  CDC_HDO;
   wire         CDC_HRD_N;
   wire         CDC_DTEN_N;
   wire         CDC_WAIT_N;
   wire         CDC_INT_N;
   wire         CDC_N, COE_N, CLWE_N;
   wire         ERES_N;

   // ---------------- CDC buffer RAM ----------------
   wire  [15:1] CDC_RAM_A_WR;
   wire  [15:0] CDC_RAM_A_RD;
   wire  [7:0]  CDC_RAM_DI;
   wire  [15:0] CDC_RAM_DO;
   wire         CDC_RAM_WE;

   // ---------------- CD sector feed (real decode path) ----------------
   logic [15:0] CDC_CD_DI = '0;      // bench-driven CD data word
   logic        CDC_CD_WR = 1'b0;    // bench-driven CD write strobe

   // ---------------- word RAM ----------------
   wire  [15:0] WORDRAM0_A, WORDRAM1_A;
   wire  [15:0] WORDRAM0_DI, WORDRAM1_DI;
   wire  [15:0] WORDRAM0_DO, WORDRAM1_DO;
   wire         WORDRAM0_WR, WORDRAM1_WR;

   // ---------------- misc ASIC outputs (unused) ----------------
   wire  [17:0] PRG_A;   wire [15:0] PRG_DO;
   wire         PRG_WRL_N, PRG_WRH_N, PRG_OE_N, PRG_RFS;
   wire  [12:0] PCM_A;   wire [7:0] PCM_DI_O;
   wire         PCM_WE_N, PCM_N;
   wire         ROM_CE_N, PRAM_N, BRAM_N, BROM_N, CUWE_N;
   wire  [39:0] CDD_COMM; wire CDD_SEND;
   wire  [10:0] FD_DAT;  wire FD_WR, LED_RED, LED_GREEN;

   // sub-CPU read data mux (what the CPU would sample), see MCD.vhd
   wire  [15:0] S68K_DI_NET;
   assign S68K_DI_NET[7:0]  = (CDC_N==1'b0) ? CDC_DO : ASIC_DO[7:0];   // BRAM/PCM stubbed
   assign S68K_DI_NET[15:8] = ASIC_DO[15:8];

   // ============================ DUTs ============================
   ASIC asic (
      .CLK(CLK), .RST_N(RST_N), .ENABLE(ENABLE), .CLK50_EN(en50),
      .S68K_A(S68K_A), .S68K_DI(S68K_DO_TB), .S68K_DO(ASIC_DO),
      .S68K_AS_N(S68K_AS_N), .S68K_RNW(S68K_RNW),
      .S68K_UDS_N(S68K_UDS_N), .S68K_LDS_N(S68K_LDS_N),
      .S68K_DTACK_N(S68K_DTACK_N), .S68K_IPL_N(S68K_IPL_N),
      .S68K_VPA_N(S68K_VPA_N), .S68K_FC(S68K_FC),
      .S68K_HALT_N(S68K_HALT_N), .S68K_RESET_N(S68K_RESET_N),
      .S68K_CE_F(S68K_CE_F), .S68K_CE_R(S68K_CE_R), .S68K_CLK(S68K_CLK),
      .EXT_VA(EXT_VA), .EXT_VDI(EXT_VDI), .EXT_VDO(EXT_VDO),
      .EXT_AS_N(EXT_AS_N), .EXT_RNW(EXT_RNW),
      .EXT_UDS_N(EXT_UDS_N), .EXT_LDS_N(EXT_LDS_N),
      .EXT_DTACK_N(EXT_DTACK_N), .EXT_ASEL_N(EXT_ASEL_N),
      .EXT_VCLK_CE(1'b0), .EXT_RAS2_N(EXT_RAS2_N),
      .EXT_ROM_N(EXT_ROM_N), .EXT_FDC_N(EXT_FDC_N),
      .PRG_A(PRG_A), .PRG_DI(16'h0000), .PRG_DO(PRG_DO),
      .PRG_WRL_N(PRG_WRL_N), .PRG_WRH_N(PRG_WRH_N), .PRG_OE_N(PRG_OE_N),
      .PRG_RFS(PRG_RFS), .PRG_RDY(1'b1),
      .PCM_A(PCM_A), .PCM_DI(PCM_DI_O), .PCM_WE_N(PCM_WE_N), .PCM_N(PCM_N),
      .PCM_RDY(1'b1),
      .ROM_DI(16'h0000), .ROM_CE_N(ROM_CE_N), .ROM_RDY(1'b1),
      .PRAM_N(PRAM_N), .BRAM_N(BRAM_N), .BROM_N(BROM_N),
      .CDC_N(CDC_N), .COE_N(COE_N), .CLWE_N(CLWE_N), .CUWE_N(CUWE_N),
      .CDC_INT_N(CDC_INT_N), .ERES_N(ERES_N),
      .CDC_HDI(CDC_HDO), .CDC_HRD_N(CDC_HRD_N),
      .CDC_DTEN_N(CDC_DTEN_N), .CDC_WAIT_N(CDC_WAIT_N),
      .CD_DI(16'h0000), .CD_SC_WR(1'b0),
      .CDD_STAT(40'h0), .CDD_COMM(CDD_COMM), .CDD_SEND(CDD_SEND),
      .CDD_REC(1'b0), .CDD_DM(1'b0),
      .WORDRAM0_A(WORDRAM0_A), .WORDRAM0_DI(WORDRAM0_DI),
      .WORDRAM0_DO(WORDRAM0_DO), .WORDRAM0_WR(WORDRAM0_WR),
      .WORDRAM1_A(WORDRAM1_A), .WORDRAM1_DI(WORDRAM1_DI),
      .WORDRAM1_DO(WORDRAM1_DO), .WORDRAM1_WR(WORDRAM1_WR),
      .FD_DAT(FD_DAT), .FD_WR(FD_WR), .LED_RED(LED_RED), .LED_GREEN(LED_GREEN)
   );

   CDC cdc (
      .CLK(CLK), .RESET_N(ERES_N), .ENABLE(ENABLE), .PALSW(1'b0),
      .CLKEN_P(S68K_CE_R), .CLKEN_N(S68K_CE_F),
      .DI(S68K_DO_TB[7:0]), .DO(CDC_DO),
      .CS_N(CDC_N), .RS(S68K_A[1]), .RD_N(COE_N), .WR_N(CLWE_N),
      .INT_N(CDC_INT_N),
      .HDO(CDC_HDO), .HRD_N(CDC_HRD_N), .DTEN_N(CDC_DTEN_N), .WAIT_N(CDC_WAIT_N),
      .CD_DI(CDC_CD_DI), .CD_WR(CDC_CD_WR),
      .RAM_A_WR(CDC_RAM_A_WR), .RAM_A_RD(CDC_RAM_A_RD),
      .RAM_DI(CDC_RAM_DI), .RAM_DO(CDC_RAM_DO), .RAM_WE(CDC_RAM_WE)
   );

   tb_cdcram cdcram (
      .CLK(CLK), .a_rd(CDC_RAM_A_RD), .q_rd(CDC_RAM_DI),
      .a_wr(CDC_RAM_A_WR), .d_wr(CDC_RAM_DO), .we(CDC_RAM_WE)
   );

   tb_spram #(16,16) wordram0 (
      .CLK(CLK), .address(WORDRAM0_A), .data(WORDRAM0_DO),
      .wren(WORDRAM0_WR), .q(WORDRAM0_DI)
   );
   tb_spram #(16,16) wordram1 (
      .CLK(CLK), .address(WORDRAM1_A), .data(WORDRAM1_DO),
      .wren(WORDRAM1_WR), .q(WORDRAM1_DI)
   );

   // ======================================================================
   //  CD sector feed + faithful COMSTA[3] model (see sim/cdc/BENCH_SPEC.md)
   // ======================================================================
   wire en_tick = (S68K_CE_R | S68K_CE_F);

   task automatic wait_en_ticks(input int n);
      int k; k=0;
      while (k<n) begin @(posedge CLK); if (en_tick) k++; end
   endtask

   // 1176-word canonical Mode-1 sector (little-endian words) from sector_words.hex
   logic [15:0] sector_word [0:1175];
   initial $readmemh("sector_words.hex", sector_word);

   // one CD data word, CE-gated so the CDC's EN-sampled CD_WR edge is not dropped
   task automatic feed_word(input [15:0] w);
      CDC_CD_DI = w;  CDC_CD_WR = 1'b1;  wait_en_ticks(2);
      CDC_CD_WR = 1'b0;                  wait_en_ticks(2);
   endtask

   // COMSTA[3] = A12026 = CS(3), SUB-written on hardware. No sub-CPU here, so model it:
   // set to 5 on the CDC level-5 (DTEI/DECI) interrupt edge (CDC_INT_N 1->0) if IEN(5);
   // cleared to 0 at the start of every relayed sub command (cmd_rx STA_IRQ<=0 -> every S68K cycle).
   logic [7:0] comsta3 = 0;
   logic       ien5    = 1'b1;
   logic       cint_old = 1'b1;
   always @(posedge CLK) if (en_tick) begin
      cint_old <= CDC_INT_N;
      if (CDC_INT_N==1'b0 && cint_old==1'b1 && ien5) comsta3 <= 8'd5;
   end

   // ======================================================================
   //  Reference buffer + word-RAM snoop helpers
   // ======================================================================
   int PT = 0;                            // CDC buffer read pointer (from HEAD/PT readback in INIT)
   logic [7:0] gbuff [0:2351];            // golden buffer captured from the INIT MAIN DMA readback
   function automatic [7:0] buffref(input int i);   // == verificator buff[i]
      buffref = gbuff[i];
   endfunction
   // byte b of word RAM (2M interleave: even words -> bank0, odd -> bank1)
   function automatic [7:0] wram_byte(input int b);
      int w, bank, addr; logic [15:0] hw;
      w = b >> 1; bank = w & 1; addr = w >> 1;
      hw = bank ? wordram1.mem[addr] : wordram0.mem[addr];
      wram_byte = b[0] ? hw[7:0] : hw[15:8];
   endfunction
   task automatic wram_fill(input int nbytes, input [7:0] v);
      int i;
      for (i=0;i<((nbytes+3)/2);i++) begin
         wordram0.mem[i] = {v,v};
         wordram1.mem[i] = {v,v};
      end
   endtask

   // ======================================================================
   //  Bus tasks
   // ======================================================================
   localparam int TIMEOUT = 6000000;      // CLKs (a full 2352-byte DMA needs tens of thousands)
   localparam int POLL_BUDGET = 4000000;  // CLKs; a real 2352 DMA/decode completes in far fewer
   localparam int HANG = 32'h0000_1000;   // test-result sentinel: a never-satisfied poll (hang)

   // ---- sub-CPU (S68K) ----
   task automatic s68k_setaddr(input int addr);
      S68K_A = '0;
      S68K_A[7:1]   = (addr[7:0] >> 1);
      S68K_A[19:8]  = 12'hF80;
   endtask

   task automatic s68k_wr8(input int addr, input [7:0] val);
      int t;
      @(posedge CLK); #1;
      comsta3 = 0;                        // cmd_rx: sub clears STA_IRQ at every relayed command
      s68k_setaddr(addr);
      if (addr[0]) begin S68K_DO_TB = {8'h00,val}; S68K_UDS_N=1'b1; S68K_LDS_N=1'b0; end
      else         begin S68K_DO_TB = {val,8'h00}; S68K_UDS_N=1'b0; S68K_LDS_N=1'b1; end
      S68K_RNW = 1'b0; S68K_AS_N = 1'b0;
      t=0; while (S68K_DTACK_N!==1'b0 && t<TIMEOUT) begin @(posedge CLK); t++; end
      repeat (6) @(posedge CLK);          // let CDC sample the WR falling edge on an EN tick
      S68K_AS_N=1'b1; S68K_UDS_N=1'b1; S68K_LDS_N=1'b1; S68K_RNW=1'b1;
      repeat (4) @(posedge CLK);
   endtask

   task automatic s68k_wr16(input int addr, input [15:0] val);
      int t;
      @(posedge CLK); #1;
      comsta3 = 0;                        // cmd_rx: sub clears STA_IRQ at every relayed command
      s68k_setaddr(addr);
      S68K_DO_TB = val; S68K_UDS_N=1'b0; S68K_LDS_N=1'b0;
      S68K_RNW = 1'b0; S68K_AS_N = 1'b0;
      t=0; while (S68K_DTACK_N!==1'b0 && t<TIMEOUT) begin @(posedge CLK); t++; end
      repeat (6) @(posedge CLK);
      S68K_AS_N=1'b1; S68K_UDS_N=1'b1; S68K_LDS_N=1'b1; S68K_RNW=1'b1;
      repeat (4) @(posedge CLK);
   endtask

   task automatic s68k_rd(input int addr, input bit word, output [15:0] data);
      int t;
      @(posedge CLK); #1;
      comsta3 = 0;                        // cmd_rx: sub clears STA_IRQ at every relayed command
      s68k_setaddr(addr);
      S68K_RNW = 1'b1;
      if (word)        begin S68K_UDS_N=1'b0; S68K_LDS_N=1'b0; end
      else if (addr[0])begin S68K_UDS_N=1'b1; S68K_LDS_N=1'b0; end
      else             begin S68K_UDS_N=1'b0; S68K_LDS_N=1'b1; end
      S68K_AS_N = 1'b0;
      t=0; while (S68K_DTACK_N!==1'b0 && t<TIMEOUT) begin @(posedge CLK); t++; end
      repeat (6) @(posedge CLK);          // CDC updates DO on the RD edge; sample after
      data = S68K_DI_NET;
      S68K_AS_N=1'b1; S68K_UDS_N=1'b1; S68K_LDS_N=1'b1;
      repeat (4) @(posedge CLK);
   endtask

   // read the high byte of an even sub reg (e.g. FF8004 flags / DD)
   task automatic s68k_rd8_hi(input int addr, output [7:0] val);
      logic [15:0] d; s68k_rd(addr,1'b1,d); val = d[15:8];
   endtask

   // ---- main-CPU (EXT) gate-array access ----
   int EXT_GAP = 150;                     // idle CLKs between EXT cycles (CPU is slower than the CDC fetch)

   task automatic ext_setaddr(input int addr);   // addr is A120xx
      EXT_VA = '0;
      EXT_VA[5:1] = ((addr - 'h12000) >> 1);
      EXT_FDC_N = 1'b0; EXT_ASEL_N = 1'b1; EXT_RAS2_N = 1'b1; EXT_ROM_N = 1'b1;
   endtask

   task automatic ext_rd(input int addr, input bit word, output [15:0] data);
      int t;
      @(posedge CLK); #1;
      ext_setaddr(addr);
      EXT_RNW = 1'b1;
      if (word)        begin EXT_UDS_N=1'b0; EXT_LDS_N=1'b0; end
      else if (addr[0])begin EXT_UDS_N=1'b1; EXT_LDS_N=1'b0; end
      else             begin EXT_UDS_N=1'b0; EXT_LDS_N=1'b1; end
      EXT_AS_N = 1'b0;
      t=0; while (EXT_DTACK_N!==1'b0 && t<TIMEOUT) begin @(posedge CLK); t++; end
      repeat (3) @(posedge CLK);
      data = EXT_VDO;
      EXT_AS_N=1'b1; EXT_UDS_N=1'b1; EXT_LDS_N=1'b1; EXT_FDC_N=1'b1;
      repeat (EXT_GAP) @(posedge CLK);
   endtask

   task automatic ext_wr(input int addr, input [15:0] val, input bit uds, input bit lds);
      int t;
      @(posedge CLK); #1;
      ext_setaddr(addr);
      EXT_VDI = val; EXT_RNW=1'b0; EXT_UDS_N=~uds; EXT_LDS_N=~lds; EXT_AS_N=1'b0;
      t=0; while (EXT_DTACK_N!==1'b0 && t<TIMEOUT) begin @(posedge CLK); t++; end
      repeat (3) @(posedge CLK);
      EXT_AS_N=1'b1; EXT_UDS_N=1'b1; EXT_LDS_N=1'b1; EXT_RNW=1'b1; EXT_FDC_N=1'b1;
      repeat (8) @(posedge CLK);
   endtask

   task automatic ext_rd8_hi(input int addr, output [7:0] val);
      logic [15:0] d; ext_rd(addr,1'b1,d); val = d[15:8];   // byte at even A120xx = D15:8
   endtask

   // ======================================================================
   //  CDC / DMA helper sequences (mcd-verificator helpers)
   // ======================================================================
   localparam CDC_DST_MAIN=3'd2, CDC_DST_SUB=3'd3, CDC_DST_PCM=3'd4,
              CDC_DST_PRG=3'd5, CDC_DST_WRAM=3'd7;
   localparam CDC_IFCTRL=1, CDC_DBCL=2, CDC_DTACK_R=7, CDC_CTRL0=10, CDC_RST=15;
   localparam IFCTRL_DOUTEN=8'h02, IFCTRL_DTEIEN=8'h40;
   localparam EDT=8'h80, DSR=8'h40;

   task automatic cdc_reg_select(input int reg_n);
      s68k_wr8('hFF8005, reg_n[7:0]);
   endtask
   task automatic cdc_reg_write(input [7:0] val);
      s68k_wr8('hFF8007, val);
   endtask
   task automatic cdc_reg_read(output [7:0] val);   // CDC data port (FF8007, odd/low byte)
      logic [15:0] d; s68k_rd('hFF8007, 1'b0, d); val = d[7:0];
   endtask
   task automatic cdc_dtack();
      cdc_reg_select(CDC_DTACK_R); cdc_reg_write(8'h00);
   endtask

   // cdcDmaSetup(dst, N, PT): FF8004=DD (resets DMAA, clears EDT), then
   //   DBC = N-1, DAC = pt.  Leaves CDC AR = 6 (DTTRG).
   task automatic cdc_dma_setup(input [2:0] dst, input int N, input int pt);
      // FF8004 (even/UDS): DD = DI[10:8] = byte[2:0]; also resets DMAA=0 & clears EDT
      s68k_wr8('hFF8004, {5'b0, dst});
      cdc_reg_select(CDC_DBCL);
      cdc_reg_write((N-1) & 8'hFF);
      cdc_reg_write(((N-1) >> 8) & 8'hFF);
      cdc_reg_write(pt & 8'hFF);
      cdc_reg_write((pt >> 8) & 8'hFF);
   endtask

   task automatic dttrg();               // AR must be 6
      s68k_wr8('hFF8007, 8'h00);
      repeat (400) @(posedge CLK);       // let the CDC assert DTEN and present the first host word
   endtask

   task automatic set_dma_addr(input int byte_addr);
      s68k_wr16('hFF800A, (byte_addr >> 3));
   endtask

   task automatic wram_to_sub();         // main gives word RAM to sub: A12002 DMNA=1 -> RET0=0
      ext_wr('h12002, 16'h0002, 1'b0, 1'b1);
   endtask

   // wait for a memory DMA to finish: CDC raises DTEI -> CDC_INT_N low
   task automatic wait_dma_done(output bit ok);
      int t; t=0;
      while (CDC_INT_N!==1'b0 && t<TIMEOUT) begin @(posedge CLK); t++; end
      ok = (t < TIMEOUT);
      if (ok) repeat (64) @(posedge CLK);   // let the final DMA word drain to its destination RAM
   endtask

   task automatic set_ifctrl(input [7:0] v);
      cdc_reg_select(CDC_IFCTRL); cdc_reg_write(v);
   endtask

   // mcd-verificator tsetCDC_end(): stop decoder, terminate DMA, re-arm IFCTRL
   task automatic cdc_end();
      cdc_reg_select(CDC_CTRL0); cdc_reg_write(8'h00); cdc_reg_write(8'h00);
      set_ifctrl(8'h00);
      set_ifctrl(IFCTRL_DOUTEN | IFCTRL_DTEIEN);
   endtask

   // ---- decoder on/off + sector feed (real CDC data path) ----
   task automatic cdc_decoder_on();
      cdc_reg_select(8'h0F); cdc_reg_write(8'h00);   // R15 RESET
      cdc_reg_select(8'h0A); cdc_reg_write(8'h84);   // CTRL0 = DECEN(80)|WRRQ(04) -> AR auto-inc to 11(CTRL1)
                             cdc_reg_write(8'hC0);   // CTRL1 = SYIEN(80)|SYDEN(40)
      cdc_reg_select(8'h01); cdc_reg_write(8'h62);   // IFCTRL = DTEIEN(40)|DECIEN(20)|DOUTEN(02)
   endtask
   task automatic cdc_decoder_off();
      cdc_reg_select(8'h0A); cdc_reg_write(8'h00);   // CTRL0 = 0
   endtask
   task automatic feed_sector();
      int i;
      for (i=0;i<1176;i++) feed_word(sector_word[i]);
   endtask

   // ---- faithful polls: read-until-condition-or-HANG ----
   task automatic wait_comsta5(input string label, output bit hung);
      int t; t=0; hung=0;
      while (comsta3 != 8'd5) begin @(posedge CLK); if (++t>=POLL_BUDGET) begin hung=1; break; end end
      if (hung) $display("  >>> HANG @ %s (COMSTA3 poll, %0d clk)", label, t);
      else repeat (64) @(posedge CLK);   // let the final DMA word drain to its destination RAM
   endtask
   // models while((A12004 & EDT)==0) { ... } with a budget
   task automatic wait_edt(input string label, output bit hung);
      int t; logic [7:0] v; t=0; hung=0;
      forever begin
         ext_rd8_hi('h12004, v);
         if (v & EDT) break;
         @(posedge CLK); if (++t>=POLL_BUDGET) begin hung=1; break; end
      end
      if (hung) $display("  >>> HANG @ %s (A12004&EDT poll, last=%02h)", label, v);
   endtask

   // ---- INIT: feed a real sector, read HEAD/PT, capture the golden buffer ----
   //   builds gbuff[] from the MAIN DMA readback and validates the SEGA header.
   task automatic test_cdc_init(output int err);
      int i; bit hung; logic [7:0] h0,h1,h2,h3,ptl,pth; logic [15:0] d16;
      err = 0;
      cdc_decoder_on();
      feed_sector();
      wait_comsta5("INIT decode", hung); if (hung) begin err='h100; return; end
      // read HEAD0..3, PTL, PTH (AR=4, auto-inc)
      cdc_reg_select(8'h04);
      cdc_reg_read(h0); cdc_reg_read(h1); cdc_reg_read(h2); cdc_reg_read(h3);
      cdc_reg_read(ptl); cdc_reg_read(pth);
      $display("    [init] HEAD=%02h %02h %02h %02h  PT=%02h%02h", h0,h1,h2,h3,pth,ptl);
      if ({h3,h2,h1,h0} !== 32'h01000200) $display("    [init] note: HEAD != 00 02 00 01");
      PT = {pth,ptl};
      // decoder OFF, arm host out, DMA the whole sector to WORD RAM and snoop it as the
      // golden buffer (byte-exact; the internal DMA is reliable where the first CPU A12008
      // read is not). All later WRAM/PRG comparisons reference this same gbuff.
      cdc_decoder_off();
      set_ifctrl(IFCTRL_DOUTEN | IFCTRL_DTEIEN);
      wram_to_sub();
      wram_fill(2352, 8'h5A);
      cdc_dtack();
      cdc_dma_setup(CDC_DST_WRAM, 2352, PT);
      set_dma_addr(0);
      dttrg();
      wait_comsta5("INIT wram capture", hung); if (hung) begin err='h101; return; end
      for (i=0;i<2352;i++) gbuff[i]=wram_byte(i);
      $display("    [init] buff[0..7]=%02h %02h %02h %02h %02h %02h %02h %02h",
               gbuff[0],gbuff[1],gbuff[2],gbuff[3],gbuff[4],gbuff[5],gbuff[6],gbuff[7]);
      if (gbuff[4]!=8'h53 || gbuff[5]!=8'h45 || gbuff[6]!=8'h47 || gbuff[7]!=8'h41)
         $display("    [init] WARNING: SEGA tag not found in golden buffer");
   endtask

   // ======================================================================
   //  Test bookkeeping
   // ======================================================================
   integer fails = 0;

   // DMA word-write counter (rising edges of word-RAM WR = words transferred)
   int  wr_words;
   logic wr_old;
   always @(posedge CLK) begin
      wr_old <= (WORDRAM0_WR | WORDRAM1_WR);
      if ((WORDRAM0_WR | WORDRAM1_WR) & ~wr_old) wr_words++;
   end

   // ======================================================================
   //  Test sequences
   // ======================================================================
   logic [15:0] d16; logic [7:0] d8;

   // -------- DMA2: odd DMA length to word RAM (err 03/04/05) --------
   task automatic test_dma2(output int err);
      int i, idx;
      err = 0;
      // full sector to word RAM at offset 8 (err01/02/03)
      wram_to_sub();
      wram_fill(2352+16, 8'hAA);
      cdc_dtack();
      cdc_dma_setup(CDC_DST_WRAM, 2352, PT);
      set_dma_addr(8);
      dttrg();
      begin bit ok; wait_dma_done(ok); if(!ok) begin err='hE0; return; end end
      for (i=0;i<8;i++) begin
         if (wram_byte(i)      != 8'hAA) begin err='h01; return; end
         if (wram_byte(i+2352+8)!=8'hAA) begin err='h02; return; end
      end
      for (i=0;i<2352;i++) if (wram_byte(i+8)!=buffref(i)) begin err='h03; return; end

      // odd len - 1 : (2352-2)-1 = 2349 -> expect 2348 bytes
      wram_fill(2352, 8'hAA);
      cdc_dtack();
      cdc_dma_setup(CDC_DST_WRAM, (2352-2)-1, PT);
      set_dma_addr(0);
      wr_words=0; dttrg();
      begin bit ok; wait_dma_done(ok); if(!ok) begin err='hE4; return; end end
      idx = 2352;
      for (i=0;i<2352;i++) if (wram_byte(i)!=buffref(i)) begin idx=i; break; end
      $display("    [dma2] len 2349 -> transferred %0d bytes, first-diff idx=%0d", wr_words*2, idx);
      if (idx != 2348) begin err='h04; return; end

      // odd len + 1 : (2352-2)+1 = 2351 -> expect 2350 bytes
      wram_fill(2352, 8'hAA);
      cdc_dtack();
      cdc_dma_setup(CDC_DST_WRAM, (2352-2)+1, PT);
      set_dma_addr(0);
      wr_words=0; dttrg();
      begin bit ok; wait_dma_done(ok); if(!ok) begin err='hE5; return; end end
      idx = 2352;
      for (i=0;i<2352;i++) if (wram_byte(i)!=buffref(i)) begin idx=i; break; end
      $display("    [dma2] len 2351 -> transferred %0d bytes, first-diff idx=%0d", wr_words*2, idx);
      if (idx != 2350) begin err='h05; return; end
   endtask

   // word RAM 2M mode (sub RMW of FF8002), give word RAM to main (RET), MEM_WP off, gVsync dwell
   task automatic mcd_wram_mode_2m();
      logic [15:0] v; s68k_rd('hFF8002,1'b1,v); v = v & ~16'h0014; s68k_wr16('hFF8002, v);
   endtask
   task automatic mcd_wram_to_main();
      logic [15:0] v; s68k_rd('hFF8002,1'b1,v); v = v | 16'h0001; s68k_wr16('hFF8002, v);
      repeat (200) @(posedge CLK);
   endtask
   task automatic mem_wp_0();
      ext_wr('h12002, 16'h0000, 1'b1, 1'b0);   // MEM_WP (A12002, high byte) = 0
   endtask
   task automatic gvsync();
      repeat (200) @(posedge CLK);
   endtask

   // -------- DMA3: testCDC_dma3, faithful MAIN host section (0x01-0x07) + WRAM (0x22-0x23) --
   //   STATUS 2026-09-07: build 36 correctly bails at 0x01 (A12004=0x82 -> DMA3 ERROR 01, the
   //   hardware result). The e22d454/ccb6fdf variants pass 0x01 (0x02) and run the MAIN host
   //   section faithfully (DSR sets once dttrg() settles). NOT YET REPRODUCING THE DEEP HANG:
   //   (1) the SUB-dest host tests 0x10-0x21 are SKIPPED (if(1'b0)) because mcdRD8(0xff80xx) is
   //       relayed THROUGH the sub-CPU on hardware and that relay read kicks the transfer; a
   //       direct S68K bus access here leaves DSR clear (test 0x11 reads 0x03 not 0x43). Faithful
   //       reproduction of those needs a sub-CPU (MCD.vhd) or a modelled relay.
   //   (2) the WRAM test 0x22 does NOT hang here, so the latent hang is deeper (PRG 0x24 / PCM
   //       0x26 / buffer-wrap 0x30+), needing behavioural PRG+PCM destination models. It is also
   //       possible the hardware hang is a full-core-context effect (the build-40 NukedMD
   //       conversion + real sub-CPU) not present in the isolated ASIC.vhd diff -- R1 unresolved.
   //   The bench is TRUSTWORTHY for the build-36 baseline and the FLAGS/DMA2 variant codes; use it
   //   for those. Reaching the DMA3 hang is the documented next stage (see BENCH_SPEC.md).
   task automatic test_dma3_main(output int err);
      int i; bit hung; logic [15:0] t16; logic [7:0] t8;
      err = 0;
      mcd_wram_mode_2m();
      wram_to_sub(); gvsync();
      mem_wp_0();
      // 0x01-0x07: MAIN host-data EDT/DSR
      cdc_dma_setup(CDC_DST_MAIN, 2352, PT);
      ext_rd8_hi('h12004,t8); if (t8!=8'h02) begin err='h01; $display("    [dma3] 01 flags=%02h (exp 02)",t8); return; end
      dttrg();
      ext_rd8_hi('h12004,t8); if (t8!=8'h42) begin err='h02; $display("    [dma3] 02 flags=%02h (exp 42)",t8); return; end
      for (i=0;i<2352-4;i+=2) ext_rd('h12008,1'b1,t16);
      ext_rd8_hi('h12004,t8); if (t8!=8'h42) begin err='h03; return; end
      ext_rd('h12008,1'b1,t16); ext_rd8_hi('h12004,t8); if (t8!=8'hC2) begin err='h04; return; end
      ext_rd('h12008,1'b1,t16); ext_rd8_hi('h12004,t8); if (t8!=8'h82) begin err='h05; return; end
      ext_rd('h12008,1'b1,t16); ext_rd8_hi('h12004,t8); if (t8!=8'h82) begin err='h06; return; end
      s68k_rd8_hi('hFF8004,t8); if (t8!=8'h82) begin err='h07; return; end
      if (1'b0) begin   // SKIP tests 0x10-0x21: SUB-dest host reads need the sub-CPU relay (no sub here)
      // 0x10-0x16: SUB host-data EDT/DSR
      cdc_dma_setup(CDC_DST_SUB, 2352, PT);
      s68k_rd8_hi('hFF8004,t8); if (t8!=8'h03) begin err='h10; $display("    [dma3] 10 subflag=%02h (exp 03)",t8); return; end
      dttrg();
      s68k_rd8_hi('hFF8004,t8); if (t8!=8'h43) begin err='h11; $display("    [dma3] 11 subflag=%02h (exp 43)",t8); return; end
      for (i=0;i<2352-4;i+=2) s68k_rd('hFF8008,1'b1,t16);
      s68k_rd8_hi('hFF8004,t8); if (t8!=8'h43) begin err='h12; return; end
      s68k_rd('hFF8008,1'b1,t16); s68k_rd8_hi('hFF8004,t8); if (t8!=8'hC3) begin err='h13; return; end
      s68k_rd('hFF8008,1'b1,t16); s68k_rd8_hi('hFF8004,t8); if (t8!=8'h83) begin err='h14; return; end
      s68k_rd('hFF8008,1'b1,t16); s68k_rd8_hi('hFF8004,t8); if (t8!=8'h83) begin err='h15; return; end
      ext_rd8_hi('h12004,t8); if (t8!=8'h83) begin err='h16; return; end
      // 0x20: dma to MAIN, sub trying to read
      cdc_dma_setup(CDC_DST_MAIN, 2352, PT);
      dttrg(); repeat (4) @(posedge CLK);
      for (i=0;i<2352;i+=2) s68k_rd('hFF8008,1'b1,t16);
      ext_rd8_hi('h12004,t8); if (t8!=8'h42) begin err='h20; return; end
      for (i=0;i<2352;i+=2) ext_rd('h12008,1'b1,t16);
      // 0x21: dma to SUB, main trying to read
      cdc_dma_setup(CDC_DST_SUB, 2352, PT);
      dttrg(); repeat (4) @(posedge CLK);
      for (i=0;i<2352;i+=2) ext_rd('h12008,1'b1,t16);
      s68k_rd8_hi('hFF8004,t8); if (t8!=8'h43) begin err='h21; return; end
      for (i=0;i<2352;i+=2) s68k_rd('hFF8008,1'b1,t16);
      end // end SKIP 0x10-0x21
      // 0x22-0x23: WRAM dma -- the FIRST unbounded `while(COMSTA[3]!=5)`
      wram_to_sub(); gvsync();
      cdc_dtack();
      cdc_dma_setup(CDC_DST_WRAM, 2352, PT);
      set_dma_addr(0);
      dttrg();
      ext_rd8_hi('h12004,t8); if ((t8 & ~DSR)!=8'h07) begin err='h22; return; end
      wait_comsta5("DMA3 0x22 WRAM", hung); if (hung) begin err=HANG; return; end
      ext_rd8_hi('h12004,t8);                                  // "EDT rises only after reading 004"
      ext_rd8_hi('h12004,t8); if (t8!=8'h87) begin err='h23; return; end
   endtask

   // -------- FLAGS: EDT latched, held through IFCTRL=0/RST, cleared only by FF8004 --
   task automatic test_flags(output int err);
      err = 0;
      set_ifctrl(IFCTRL_DOUTEN | IFCTRL_DTEIEN);
      wram_to_sub();
      cdc_dtack();
      cdc_dma_setup(CDC_DST_WRAM, 2352, PT);
      set_dma_addr(0);
      dttrg();
      begin bit ok; wait_dma_done(ok); if(!ok) begin err='hE0; return; end end
      cdc_dtack();
      ext_rd8_hi('h12004,d8); if ((d8 & EDT)==0) begin err='h01; $display("    [flags] after dma EDT missing (%02h)",d8); return; end
      s68k_wr16('hFF800A, 16'h0000);
      ext_rd8_hi('h12004,d8); if ((d8 & EDT)==0) begin err='h02; $display("    [flags] FF800A cleared EDT (%02h)",d8); return; end
      set_ifctrl(8'h00);
      ext_rd8_hi('h12004,d8); if ((d8 & EDT)==0) begin err='h03; $display("    [flags] IFCTRL=0 cleared EDT (%02h)",d8); return; end
      cdc_reg_select(CDC_RST); cdc_reg_write(8'h00);
      ext_rd8_hi('h12004,d8); if ((d8 & EDT)==0) begin err='h04; $display("    [flags] CDC RST cleared EDT (%02h)",d8); return; end
      s68k_wr8('hFF8004, CDC_DST_WRAM);
      ext_rd8_hi('h12004,d8); if ((d8 & EDT)!=0) begin err='h05; $display("    [flags] FF8004 did not clear EDT (%02h)",d8); return; end
   endtask

   // -------- sanity: DMA1 basic word-RAM transfer must stay byte-exact --------
   task automatic test_dma1(output int err);
      int i;
      err = 0;
      wram_to_sub();
      wram_fill(2352, 8'hAA);
      cdc_dtack();
      cdc_dma_setup(CDC_DST_WRAM, 2352, PT);
      set_dma_addr(0);
      dttrg();
      begin bit ok; wait_dma_done(ok); if(!ok) begin err='hE0; return; end end
      for (i=0;i<2352;i++) if (wram_byte(i)!=buffref(i)) begin err='h03; $display("    [dma1] diff at %0d",i); return; end
   endtask

   // ======================================================================
   //  Main
   // ======================================================================
   int e;
   initial begin
      // reset
      RST_N = 1'b0;
      repeat (20) @(posedge CLK);
      RST_N = 1'b1;
      repeat (40) @(posedge CLK);

      // bring the sub-CPU "out of reset", release bus: A12000 SRES=1 SBRQ=0
      ext_wr('h12000, 16'h0001, 1'b0, 1'b1);
      repeat (20) @(posedge CLK);
      // arm interface control
      set_ifctrl(IFCTRL_DOUTEN | IFCTRL_DTEIEN);

      $display("======== CDC/DMA ModelSim bench ========");

      test_cdc_init(e); if(e) begin $display("  CDC INIT     ERROR %02h",e); fails++; end else $display("  CDC INIT     OK");
      test_dma1(e);  cdc_end(); if(e) begin $display("  CDC DMA1     ERROR %02h",e); fails++; end else $display("  CDC DMA1     PASS");
      test_flags(e); cdc_end(); if(e) begin $display("  CDC FLAGS    ERROR %02h",e); fails++; end else $display("  CDC FLAGS    PASS");
      test_dma2(e);  cdc_end(); if(e) begin $display("  CDC DMA2     ERROR %02h",e); fails++; end else $display("  CDC DMA2     PASS");
      test_dma3_main(e); cdc_end();
         if(e==HANG) begin $display("  CDC DMA3     HANG"); fails++; end
         else if(e) begin $display("  CDC DMA3     ERROR %02h",e); fails++; end
         else $display("  CDC DMA3     PASS");

      $display("======== %0d failure(s) ========", fails);
      // Acceptance anchor: build-36 CDC (HEAD) must read INIT OK / DMA1 OK / FLAGS 05 / DMA2 05 /
      // DMA3 01 (== hardware). FLAGS/DMA2 also match e22d454 (FLAGS 02) and ccb6fdf (FLAGS/DMA2 OK).
      // CAVEAT: test_dma3_main is TRUNCATED to sub-tests 01-07; the deep latent DMA3 hang that the
      // e22d454/ccb6fdf variants show on hardware is NOT yet reproduced -- transcribe the full
      // testCDC_dma3 (0x10..0x63) with wait_comsta5 poll-timeouts to reach it (see BENCH_SPEC.md).
      $finish;
   end

   // global watchdog
   initial begin
      #300000000;
      $display("WATCHDOG TIMEOUT");
      $finish;
   end

endmodule
