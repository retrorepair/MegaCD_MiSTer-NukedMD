// ============================================================================
// tb_cdc.sv - ModelSim testbench for the Mega CD CDC + gate-array DMA path.
//
// Instantiates the real rtl/MCD/ASIC.vhd (gate-array DMA machine, sub-CPU
// register file, word-RAM interface) and rtl/MCD/CDC.vhd (LC8951 host-data
// transfer machine) exactly as MCD.vhd wires them, but replaces the Altera
// altsyncram-based RAMs (bram.vhd) with plain behavioural models so no
// altera_mf library is needed, and preloads the CDC decoder buffer with a
// known ramp so DMAs move deterministic data with no CD sector decode.
//
// It replays the mcd-verificator register sequences for the three failing
// CDC tests (testCDC_dma2 / dma3 / flags) over the sub-CPU (S68K_*) and
// main-CPU (EXT_*) bus interfaces and prints the SAME pass/fail + error code
// the verificator would, so a fix can be confirmed in seconds.
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
   initial for (i=0;i<16384;i=i+1) mem[i] = i[7:0];   // ramp
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
      .CD_DI(16'h0000), .CD_WR(1'b0),
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
   //  Reference buffer + word-RAM snoop helpers
   // ======================================================================
   localparam int PT = 0;                 // CDC buffer read pointer used everywhere

   function automatic [7:0] ramp(input int addr);
      ramp = addr[7:0];                   // matches tb_cdcram preload
   endfunction
   function automatic [7:0] buffref(input int i);   // == verificator buff[i]
      buffref = ramp(PT + i);
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

   // ---- sub-CPU (S68K) ----
   task automatic s68k_setaddr(input int addr);
      S68K_A = '0;
      S68K_A[7:1]   = (addr[7:0] >> 1);
      S68K_A[19:8]  = 12'hF80;
   endtask

   task automatic s68k_wr8(input int addr, input [7:0] val);
      int t;
      @(posedge CLK); #1;
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

   // -------- DMA3: EDT/DSR flag semantics for MAIN host-data (err 01..06) --
   task automatic test_dma3_main(output int err);
      int i;
      err = 0;
      cdc_dma_setup(CDC_DST_MAIN, 2352, PT);
      ext_rd8_hi('h12004, d8); if (d8 != 8'h02) begin err='h01; $display("    [dma3] setup flags=%02h (exp 02)",d8); return; end
      dttrg();
      repeat (40) @(posedge CLK);
      ext_rd8_hi('h12004, d8); if (d8 != 8'h42) begin err='h02; $display("    [dma3] after dttrg flags=%02h (exp 42)",d8); return; end
      for (i=0;i<2352-4;i+=2) ext_rd('h12008,1'b1,d16);
      ext_rd8_hi('h12004, d8); if (d8 != 8'h42) begin err='h03; $display("    [dma3] 2 words left flags=%02h (exp 42)",d8); return; end
      ext_rd('h12008,1'b1,d16);
      ext_rd8_hi('h12004, d8); if (d8 != 8'hC2) begin err='h04; $display("    [dma3] 1 word left flags=%02h (exp C2)",d8); return; end
      ext_rd('h12008,1'b1,d16);
      ext_rd8_hi('h12004, d8); if (d8 != 8'h82) begin err='h05; $display("    [dma3] all read flags=%02h (exp 82)",d8); return; end
      ext_rd('h12008,1'b1,d16);
      ext_rd8_hi('h12004, d8); if (d8 != 8'h82) begin err='h06; return; end
      s68k_rd8_hi('hFF8004, d8); if (d8 != 8'h82) begin err='h07; return; end
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

      test_dma1(e);  cdc_end(); if(e) begin $display("  CDC DMA1     ERROR %02h",e); fails++; end else $display("  CDC DMA1     PASS");
      test_flags(e); cdc_end(); if(e) begin $display("  CDC FLAGS    ERROR %02h",e); fails++; end else $display("  CDC FLAGS    PASS");
      test_dma2(e);  cdc_end(); if(e) begin $display("  CDC DMA2     ERROR %02h",e); fails++; end else $display("  CDC DMA2     PASS");
      test_dma3_main(e); cdc_end(); if(e) begin $display("  CDC DMA3     ERROR %02h",e); fails++; end else $display("  CDC DMA3     PASS");

      $display("======== %0d failure(s) ========", fails);
      $finish;
   end

   // global watchdog
   initial begin
      #300000000;
      $display("WATCHDOG TIMEOUT");
      $finish;
   end

endmodule
