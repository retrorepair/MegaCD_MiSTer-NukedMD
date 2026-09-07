// ============================================================================
// tb_pcm_halt_wait.sv - minimal, self-contained repro for a PCM-DMA deadlock in
// the Mega CD gate array (rtl/MCD/ASIC.vhd).
//
// BUG: PCM_HALT_WAIT is declared without an initialiser and is the only signal in
// its process that is missing from the reset branch:
//
//     signal PCM_HALT_WAIT : unsigned(1 downto 0);           -- no initialiser
//     ...
//     if RST_N = '0' then
//        S68K_PCM_DTACK_N <= '1';  PCMA <= PCMA_IDLE;
//        PCM_DMA_ADDR <= (others => '0');  PCM_DMA_DO <= (others => '0');
//        PCM_DMA_WR <= '0';  PCM_DMA_RUN <= '0';  PCM_S68K_HALT <= '0';
//        -- PCM_HALT_WAIT is never reset
//
// It is then used as a 2-cycle delay counter in the PCM DMA bus-steal handshake:
//
//     when PCMA_DMA_HALT2 =>
//        if S68K_AS_N = '1' and CLK_12M_R = '1' then
//           PCM_HALT_WAIT <= PCM_HALT_WAIT + 1;
//           if PCM_HALT_WAIT = 1 then          -- never true when it is 'U'
//              PCM_HALT_WAIT <= "00";
//              PCM_S68K_HALT <= '0';           -- ... so the sub-CPU is never released
//              PCM_DMA_WR <= '1';
//              PCMA <= PCMA_DMA_WRITE;
//           end if;
//        end if;
//
// With 'U' the increment stays 'U' and the "= 1" test is never true, so PCMA can
// never leave PCMA_DMA_HALT2, PCM_S68K_HALT stays asserted and the sub-CPU is
// halted forever. Any CDC DMA with DD = "100" (PCM) therefore deadlocks after a
// single byte. PCMA_DMA_WRITE has the same counter and the same problem.
//
// On the FPGA the register happens to power up to 0, so the handshake works and
// PCM DMA is fine in real use -- this only bites in simulation. The fix is to
// reset it like every other signal in the process (a no-op on silicon):
//
//     PCM_S68K_HALT <= '0';
//     PCM_HALT_WAIT <= (others => '0');      -- ADD THIS
//
// This bench needs only ASIC_PKG.vhd, ASIC.vhd and CDC.vhd -- no vendor IP, no
// ROM/BIOS image and no CD image. See run.sh.
//
// EXPECTED OUTPUT
//   unpatched: "PCM_HALT_WAIT after reset = xx"  then  "*** DEADLOCK ***"
//   patched:   "PCM_HALT_WAIT after reset = 00"  then  "PASS"
// ============================================================================
`timescale 1ns/1ps

// ---- behavioural single-port word RAM (word RAM models) ----
module pr_spram #(parameter AW=16, parameter DW=16) (
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

// ---- behavioural CDC decoder buffer (byte read port / word write port) ----
module pr_cdcram (
   input  logic        CLK,
   input  logic [15:0] a_rd,
   output logic [7:0]  q_rd,
   input  logic [15:1] a_wr,
   input  logic [15:0] d_wr,
   input  logic        we
);
   logic [7:0] mem [0:16383];
   integer i;
   initial for (i=0;i<16384;i=i+1) mem[i] = i[7:0];   // ramp: transferred bytes are deterministic
   always @(posedge CLK) begin
      if (we) begin
         mem[{a_wr[13:1],1'b0}] <= d_wr[7:0];
         mem[{a_wr[13:1],1'b1}] <= d_wr[15:8];
      end
      q_rd <= mem[a_rd[13:0]];
   end
endmodule


module tb_pcm_halt_wait;

   localparam int N_BYTES = 64;      // small transfer: a working design finishes quickly

   logic CLK = 0;  always #5 CLK = ~CLK;
   logic RST_N = 0;
   logic ENABLE = 1'b1;

   // 50 MHz enable, derived as CEGen does (IN_CLK = 53693175 NTSC)
   logic en50 = 0; integer clk_sum = 0;
   always @(posedge CLK) begin
      en50 <= 1'b0; clk_sum = clk_sum + 50000000;
      if (clk_sum >= 53693175) begin clk_sum = clk_sum - 53693175; en50 <= 1'b1; end
   end

   // ---------------- sub-CPU (S68K) bus ----------------
   logic [23:1] S68K_A     = '0;
   logic [15:0] S68K_DO_TB = '0;
   logic        S68K_AS_N  = 1'b1, S68K_RNW = 1'b1;
   logic        S68K_UDS_N = 1'b1, S68K_LDS_N = 1'b1;
   logic [1:0]  S68K_FC    = 2'b01;
   wire  [15:0] ASIC_DO;
   wire         S68K_DTACK_N; wire [2:0] S68K_IPL_N;
   wire         S68K_VPA_N, S68K_HALT_N, S68K_RESET_N;
   wire         S68K_CE_F, S68K_CE_R, S68K_CLK;

   // ---------------- main-CPU (EXT) bus: idle throughout ----------------
   logic [17:1] EXT_VA = '0; logic [15:0] EXT_VDI = '0;
   logic EXT_AS_N=1'b1, EXT_RNW=1'b1, EXT_UDS_N=1'b1, EXT_LDS_N=1'b1;
   logic EXT_ASEL_N=1'b1, EXT_RAS2_N=1'b1, EXT_ROM_N=1'b1, EXT_FDC_N=1'b1;
   wire  [15:0] EXT_VDO; wire EXT_DTACK_N;

   // ---------------- CDC <-> ASIC ----------------
   wire [7:0] CDC_DO, CDC_HDO;
   wire       CDC_HRD_N, CDC_DTEN_N, CDC_WAIT_N, CDC_INT_N;
   wire       CDC_N, COE_N, CLWE_N, ERES_N;
   wire [15:1] CDC_RAM_A_WR; wire [15:0] CDC_RAM_A_RD;
   wire [7:0]  CDC_RAM_DI;   wire [15:0] CDC_RAM_DO; wire CDC_RAM_WE;

   wire [15:0] WORDRAM0_A, WORDRAM1_A, WORDRAM0_DI, WORDRAM1_DI, WORDRAM0_DO, WORDRAM1_DO;
   wire        WORDRAM0_WR, WORDRAM1_WR;

   wire [17:0] PRG_A; wire [15:0] PRG_DO;
   wire        PRG_WRL_N, PRG_WRH_N, PRG_OE_N, PRG_RFS;
   wire [12:0] PCM_A;  wire [7:0] PCM_DI_O; wire PCM_WE_N, PCM_N;
   wire        ROM_CE_N, PRAM_N, BRAM_N, BROM_N, CUWE_N;
   wire [39:0] CDD_COMM; wire CDD_SEND;
   wire [10:0] FD_DAT; wire FD_WR, LED_RED, LED_GREEN;

   wire [15:0] S68K_DI_NET;
   assign S68K_DI_NET[7:0]  = (CDC_N==1'b0) ? CDC_DO : ASIC_DO[7:0];
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

   pr_cdcram cdcram (.CLK(CLK), .a_rd(CDC_RAM_A_RD), .q_rd(CDC_RAM_DI),
                     .a_wr(CDC_RAM_A_WR), .d_wr(CDC_RAM_DO), .we(CDC_RAM_WE));
   pr_spram #(16,16) wordram0 (.CLK(CLK), .address(WORDRAM0_A), .data(WORDRAM0_DO),
                               .wren(WORDRAM0_WR), .q(WORDRAM0_DI));
   pr_spram #(16,16) wordram1 (.CLK(CLK), .address(WORDRAM1_A), .data(WORDRAM1_DO),
                               .wren(WORDRAM1_WR), .q(WORDRAM1_DI));

   // ---------------- sub-CPU bus tasks ----------------
   localparam int TIMEOUT = 20000;
   task automatic s68k_setaddr(input int addr);
      S68K_A = '0; S68K_A[7:1] = addr[7:1]; S68K_A[19:8] = 12'hF80;
   endtask
   task automatic s68k_wr8(input int addr, input [7:0] val);
      int t; @(posedge CLK); #1;
      s68k_setaddr(addr);
      if (addr[0]) begin S68K_DO_TB = {8'h00,val}; S68K_UDS_N=1'b1; S68K_LDS_N=1'b0; end
      else         begin S68K_DO_TB = {val,8'h00}; S68K_UDS_N=1'b0; S68K_LDS_N=1'b1; end
      S68K_RNW = 1'b0; S68K_AS_N = 1'b0;
      t=0; while (S68K_DTACK_N!==1'b0 && t<TIMEOUT) begin @(posedge CLK); t++; end
      repeat (6) @(posedge CLK);
      S68K_AS_N=1'b1; S68K_UDS_N=1'b1; S68K_LDS_N=1'b1; S68K_RNW=1'b1;
      repeat (4) @(posedge CLK);
   endtask
   task automatic s68k_rd(input int addr, input bit word, output [15:0] data);
      int t; @(posedge CLK); #1;
      s68k_setaddr(addr); S68K_RNW = 1'b1;
      if (word)        begin S68K_UDS_N=1'b0; S68K_LDS_N=1'b0; end
      else if (addr[0])begin S68K_UDS_N=1'b1; S68K_LDS_N=1'b0; end
      else             begin S68K_UDS_N=1'b0; S68K_LDS_N=1'b1; end
      S68K_AS_N = 1'b0;
      t=0; while (S68K_DTACK_N!==1'b0 && t<TIMEOUT) begin @(posedge CLK); t++; end
      repeat (6) @(posedge CLK);
      data = S68K_DI_NET;
      S68K_AS_N=1'b1; S68K_UDS_N=1'b1; S68K_LDS_N=1'b1;
      repeat (4) @(posedge CLK);
   endtask

   // ---------------- count PCM writes the DMA performs ----------------
   int pcm_writes = 0; logic pcm_we_prev = 1'b1;
   always @(posedge CLK) begin
      if (PCM_WE_N===1'b0 && pcm_we_prev!==1'b0) pcm_writes++;
      pcm_we_prev <= PCM_WE_N;
   end

   logic [15:0] dummy;
   int i;

   initial begin
      $display("=========================================================");
      $display(" Mega CD ASIC: PCM DMA deadlock from unreset PCM_HALT_WAIT");
      $display("=========================================================");

      RST_N = 1'b0; repeat (20) @(posedge CLK);
      RST_N = 1'b1; repeat (40) @(posedge CLK);

      // Every other signal in this process is reset; this one is not.
      $display("  PCM_HALT_WAIT after reset = %b   (xx/UU => bug present)", asic.PCM_HALT_WAIT);
      $display("  (for reference PCM_DMA_RUN=%b PCM_S68K_HALT=%b PCMA=%0d - all reset correctly)",
               asic.PCM_DMA_RUN, asic.PCM_S68K_HALT, asic.PCMA);

      // ---- programme a CDC -> PCM host transfer ----
      // IFCTRL (CDC R1) = DOUTEN | DTEIEN : required for DTTRG to start a transfer
      s68k_wr8('hFF8005, 8'h01); s68k_wr8('hFF8007, 8'h42);
      // FF8004 = DD : 4 = PCM destination
      s68k_wr8('hFF8004, 8'h04);
      // CDC R2..R5 = DBCL, DBCH, DACL, DACH  (AR auto-increments to 6 = DTTRG)
      s68k_wr8('hFF8005, 8'h02);
      s68k_wr8('hFF8007, (N_BYTES-1) & 8'hFF);
      s68k_wr8('hFF8007, ((N_BYTES-1) >> 8) & 8'hFF);
      s68k_wr8('hFF8007, 8'h00);
      s68k_wr8('hFF8007, 8'h00);
      // FF800A = DMA destination address
      s68k_wr8('hFF800A, 8'h00); s68k_wr8('hFF800B, 8'h00);
      // DTTRG: write the CDC data port with AR == 6
      s68k_wr8('hFF8007, 8'h00);

      $display("  transfer of %0d bytes triggered (DD=4 PCM)", N_BYTES);

      // The PCM DMA steals a sub-CPU bus cycle, so it needs S68K_AS_N to keep
      // toggling. Issue harmless register reads to provide exactly that.
      for (i = 0; i < 400; i++) begin
         s68k_rd('hFF8004, 1'b0, dummy);
         if (pcm_writes >= N_BYTES) break;
      end

      $display("---------------------------------------------------------");
      $display("  PCM bytes written : %0d of %0d", pcm_writes, N_BYTES);
      $display("  PCMA              : %0d   (3 = PCMA_DMA_HALT2)", asic.PCMA);
      $display("  PCM_HALT_WAIT     : %b", asic.PCM_HALT_WAIT);
      $display("  PCM_S68K_HALT     : %b   (1 = sub-CPU still halted)", asic.PCM_S68K_HALT);
      $display("  S68K_HALT_N       : %b", S68K_HALT_N);
      if (pcm_writes >= N_BYTES) begin
         $display("  RESULT: PASS - the PCM DMA completed.");
      end else begin
         $display("  RESULT: *** DEADLOCK *** - PCMA is stuck in PCMA_DMA_HALT2 because");
         $display("          PCM_HALT_WAIT is 'U', so (PCM_HALT_WAIT = 1) is never true and");
         $display("          PCM_S68K_HALT is never released. Fix: reset PCM_HALT_WAIT.");
      end
      $display("=========================================================");
      $finish;
   end

   initial begin #20000000; $display("  RESULT: *** DEADLOCK *** (watchdog)"); $finish; end
endmodule
