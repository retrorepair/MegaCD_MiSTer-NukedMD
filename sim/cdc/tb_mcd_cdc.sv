// ============================================================================
// tb_mcd_cdc.sv - FAITHFUL sub-CPU CDC bench. Instantiates rtl/MCD/MCD.vhd (real
// gate-level sub-CPU running the verificator BIOS + ASIC + CDC + PCM), drives the
// main-side EXT bus, and relays FF80xx accesses THROUGH the real sub-CPU via the
// COMCMD mailbox (mcd.c protocol) -- so the SUB-dest host tests and the deep DMA3
// hang reproduce faithfully. A real CD sector is fed through CDC_DATA/CDC_DAT_WR.
// Stage: boot + relay + INIT (validate HEAD/PT via the relay). DMA3 added next.
// ============================================================================
`timescale 1ns/1ps

module tb_mcd_cdc;
   logic MCLK=0; always #4.657 MCLK=~MCLK;   // 107.386 MHz
   logic CLK =0; always #9.313 CLK =~CLK;    // 53.693 MHz
   logic RST_N=0, ENABLE=1'b1;
   logic EN50=0; integer acc=0;
   always @(posedge MCLK) begin EN50<=1'b0; acc=acc+50000000; if(acc>=107386350) begin acc=acc-107386350; EN50<=1'b1; end end

   logic [17:1] EXT_VA='0; logic [15:0] EXT_VDI='0; wire [15:0] EXT_VDO;
   logic EXT_AS_N=1'b1,EXT_RNW=1'b1,EXT_LDS_N=1'b1,EXT_UDS_N=1'b1; wire EXT_DTACK_N;
   logic EXT_ASEL_N=1'b1,EXT_RAS2_N=1'b1,EXT_ROM_N=1'b1,EXT_FDC_N=1'b1;

   // PRG-RAM with SDRAM-style RDY handshake, preloaded with the sub BIOS
   wire [17:0] PRG_A; wire [15:0] PRG_DO; wire PRG_WRL_N,PRG_WRH_N,PRG_OE_N,PRG_RFS;
   logic [15:0] PRG_DI; logic PRG_RDY=1'b1; logic [15:0] prg [0:262143];
   initial $readmemh("prg_bios.hex", prg);
   logic [2:0] prg_cnt=0; logic prg_busy=0;
   always @(posedge CLK) begin
      if(!prg_busy) begin
         if(!PRG_OE_N||!PRG_WRL_N||!PRG_WRH_N) begin
            prg_busy<=1'b1; PRG_RDY<=1'b0; prg_cnt<=3;
            if(!PRG_WRL_N) prg[PRG_A[17:0]][7:0]<=PRG_DO[7:0];
            if(!PRG_WRH_N) prg[PRG_A[17:0]][15:8]<=PRG_DO[15:8];
            PRG_DI<=prg[PRG_A[17:0]];
         end
      end else begin if(prg_cnt==0) begin prg_busy<=1'b0; PRG_RDY<=1'b1; end else prg_cnt<=prg_cnt-1'b1; end
   end

   logic [15:0] CDC_DATA='0; logic CDC_DAT_WR=0;
   wire [15:0] PCMRAM_A; wire [7:0] PCMRAM_DO; logic [7:0] PCMRAM_DI='0;
   wire PCMRAM_RD,PCMRAM_WR; logic PCMRAM_BUSY=0; logic [7:0] pcmram [0:65535];
   always @(posedge CLK) begin if(PCMRAM_WR) pcmram[PCMRAM_A]<=PCMRAM_DO; PCMRAM_DI<=pcmram[PCMRAM_A]; end

   wire MCD_RST_N; wire signed [15:0] PCM_SL,PCM_SR,CDDA_SL,CDDA_SR; wire ROM_CE_N;
   wire LED_RED,LED_GREEN,CDDA_WR_READY,GG_AVAILABLE; wire [13:1] BRAM_A; wire [7:0] BRAM_DO; wire BRAM_WE;
   wire [39:0] CDD_COMM; wire CDD_SEND;
   wire DBG_S68K_AS_N,DBG_S68K_DTACK_N,DBG_S68K_RNW,DBG_S68K_CE_F;
   wire DBG_PCM_SMP_CE,DBG_PCM_OUT_CE,DBG_PCM_LATE,DBG_PCM_WE_N,DBG_PCM_CS_N; wire [23:0] DBG_S68K_A;

   MCD dut (
      .CLK(CLK),.MCLK(MCLK),.RST_N(RST_N),.ENABLE(ENABLE),.EN50(EN50),.MCD_RST_N(MCD_RST_N),.PALSW(1'b0),
      .EXT_VA(EXT_VA),.EXT_VDI(EXT_VDI),.EXT_VDO(EXT_VDO),.EXT_AS_N(EXT_AS_N),.EXT_RNW(EXT_RNW),
      .EXT_LDS_N(EXT_LDS_N),.EXT_UDS_N(EXT_UDS_N),.EXT_DTACK_N(EXT_DTACK_N),.EXT_ASEL_N(EXT_ASEL_N),
      .EXT_VCLK_CE(1'b0),.EXT_RAS2_N(EXT_RAS2_N),.EXT_ROM_N(EXT_ROM_N),.EXT_FDC_N(EXT_FDC_N),
      .PRG_A(PRG_A),.PRG_DI(PRG_DI),.PRG_DO(PRG_DO),.PRG_WRL_N(PRG_WRL_N),.PRG_WRH_N(PRG_WRH_N),
      .PRG_OE_N(PRG_OE_N),.PRG_RFS(PRG_RFS),.PRG_RDY(PRG_RDY),
      .ROM_DI(16'h0),.ROM_CE_N(ROM_CE_N),.ROM_RDY(1'b1),
      .BRAM_A(BRAM_A),.BRAM_DI(8'h0),.BRAM_DO(BRAM_DO),.BRAM_WE(BRAM_WE),
      .CDD_STAT(40'h0),.CDD_COMM(CDD_COMM),.CDD_SEND(CDD_SEND),.CDD_REC(1'b0),.CDD_DM(1'b0),
      .CDC_DATA(CDC_DATA),.CDC_DAT_WR(CDC_DAT_WR),.CDC_SC_WR(1'b0),.CDC_CDDA_WR(1'b0),.CDDA_WR_READY(CDDA_WR_READY),
      .PCMRAM_A(PCMRAM_A),.PCMRAM_DO(PCMRAM_DO),.PCMRAM_DI(PCMRAM_DI),.PCMRAM_RD(PCMRAM_RD),.PCMRAM_WR(PCMRAM_WR),.PCMRAM_BUSY(PCMRAM_BUSY),
      .PCM_SL(PCM_SL),.PCM_SR(PCM_SR),.CDDA_SL(CDDA_SL),.CDDA_SR(CDDA_SR),.LED_RED(LED_RED),.LED_GREEN(LED_GREEN),
      .GG_RESET(1'b0),.GG_EN(1'b0),.GG_CODE(129'h0),.GG_AVAILABLE(GG_AVAILABLE),
      .DBG_S68K_AS_N(DBG_S68K_AS_N),.DBG_S68K_DTACK_N(DBG_S68K_DTACK_N),.DBG_S68K_RNW(DBG_S68K_RNW),
      .DBG_PCM_SMP_CE(DBG_PCM_SMP_CE),.DBG_PCM_OUT_CE(DBG_PCM_OUT_CE),.DBG_PCM_LATE(DBG_PCM_LATE),
      .DBG_PCM_WE_N(DBG_PCM_WE_N),.DBG_PCM_CS_N(DBG_PCM_CS_N),.DBG_S68K_CE_F(DBG_S68K_CE_F),.DBG_S68K_A(DBG_S68K_A)
   );

   // ---------------- main-side EXT bus tasks (A120xx gate-array) ----------------
   localparam int TO=200000;
   task automatic ext_wr(input int addr, input [15:0] val, input bit uds, input bit lds);
      int t; @(posedge CLK); #1;
      EXT_VA='0; EXT_VA[5:1]=((addr-'h12000)>>1); EXT_FDC_N=1'b0; EXT_ASEL_N=1'b1; EXT_RAS2_N=1'b1; EXT_ROM_N=1'b1;
      EXT_VDI=val; EXT_RNW=1'b0; EXT_UDS_N=~uds; EXT_LDS_N=~lds; EXT_AS_N=1'b0;
      t=0; while(EXT_DTACK_N!==1'b0 && t<TO) begin @(posedge CLK); t++; end
      repeat(3) @(posedge CLK); EXT_AS_N=1'b1; EXT_UDS_N=1'b1; EXT_LDS_N=1'b1; EXT_RNW=1'b1; EXT_FDC_N=1'b1;
      repeat(6) @(posedge CLK);
   endtask
   task automatic ext_rd(input int addr, input bit word, output [15:0] data);
      int t; @(posedge CLK); #1;
      EXT_VA='0; EXT_VA[5:1]=((addr-'h12000)>>1); EXT_FDC_N=1'b0; EXT_ASEL_N=1'b1; EXT_RAS2_N=1'b1; EXT_ROM_N=1'b1;
      EXT_RNW=1'b1; if(word)begin EXT_UDS_N=1'b0; EXT_LDS_N=1'b0; end else if(addr[0])begin EXT_UDS_N=1'b1; EXT_LDS_N=1'b0; end else begin EXT_UDS_N=1'b0; EXT_LDS_N=1'b1; end
      EXT_AS_N=1'b0; t=0; while(EXT_DTACK_N!==1'b0 && t<TO) begin @(posedge CLK); t++; end
      repeat(2) @(posedge CLK); data=EXT_VDO; EXT_AS_N=1'b1; EXT_UDS_N=1'b1; EXT_LDS_N=1'b1; EXT_FDC_N=1'b1;
      repeat(6) @(posedge CLK);
   endtask
   task automatic ext_wr16(input int addr, input [15:0] v); ext_wr(addr, v, 1'b1, 1'b1); endtask

   // ---------------- COMCMD relay (mcd.c: drives the real sub-CPU) ----------------
   // mailbox: cmd_idx=A12010 cmd_dat=A12012 cmd_adr=A12014(u32) sta_bsy=A12020 sta_rsp=A12022
   localparam CMD_RD_B=1, CMD_WR_B=2, CMD_RD_W=3, CMD_WR_W=4;
   task automatic wait_bsy0();   // wait sta_bsy==0
      int t; logic [15:0] v; t=0;
      forever begin ext_rd('h12020,1'b1,v); if(v==16'h0) break; if(++t>40000) begin $display("  >>> relay HANG: sta_bsy!=0 @%0t",$time); break; end end
   endtask
   task automatic mcd_cmd(input [15:0] cmd);
      int t; logic [15:0] v;
      wait_bsy0(); ext_wr16('h12010, cmd);
      t=0; forever begin ext_rd('h12020,1'b1,v); if(v!=16'h0) break; if(++t>40000) begin $display("  >>> relay HANG: sub didnt ack cmd %0d @%0t",cmd,$time); break; end end
      ext_wr16('h12010, 16'h0000);
   endtask
   task automatic mcd_set_adr(input int addr);
      ext_wr16('h12014, addr[31:16]); ext_wr16('h12016, addr[15:0]);
   endtask
   task automatic mcd_wr8(input int addr, input [7:0] val);
      wait_bsy0(); mcd_set_adr(addr); ext_wr('h12012, {val,8'h00}, 1'b1, 1'b0); mcd_cmd(CMD_WR_B);
   endtask
   task automatic mcd_wr16(input int addr, input [15:0] val);
      wait_bsy0(); mcd_set_adr(addr); ext_wr16('h12012, val); mcd_cmd(CMD_WR_W);
   endtask
   task automatic mcd_rd8(input int addr, output [7:0] val);
      logic [15:0] v; wait_bsy0(); mcd_set_adr(addr); mcd_cmd(CMD_RD_B);
      wait_bsy0(); ext_rd('h12022,1'b1,v); val=v[15:8];
   endtask
   task automatic mcd_rd16(input int addr, output [15:0] val);
      wait_bsy0(); mcd_set_adr(addr); mcd_cmd(CMD_RD_W); wait_bsy0(); ext_rd('h12022,1'b1,val);
   endtask

   // ---------------- CDC register helpers (via relay) + sector feed ----------------
   task automatic cdc_sel(input [7:0] r); mcd_wr8('hFF8005, r); endtask
   task automatic cdc_wr(input [7:0] v);  mcd_wr8('hFF8007, v); endtask
   task automatic cdc_rd(output [7:0] v); mcd_rd8('hFF8007, v); endtask

   logic [15:0] sector_word [0:1175];
   initial $readmemh("sector_words.hex", sector_word);
   // The CDC advances (and samples CD_WR) only on its EN = ENABLE and (CLKEN_N or CLKEN_P),
   // i.e. on a sub-CPU CE tick. Gate the feed on that tick (mixed-lang ref to MCD's S68K_CE_R/F)
   // exactly like the validated isolated bench, so no CD_WR edge is dropped or doubled.
   wire en_tick = dut.S68K_CE_R | dut.S68K_CE_F;
   task automatic wait_en_ticks(input int n);
      int k=0; while(k<n) begin @(posedge CLK); if(en_tick) k++; end
   endtask
   task automatic feed_word(input [15:0] w);
      CDC_DATA=w; CDC_DAT_WR=1'b1; wait_en_ticks(2); CDC_DAT_WR=1'b0; wait_en_ticks(2);
   endtask

   // ============================ main ============================
   int  sub_cycles=0; logic [23:0] a_last='1;
   always @(posedge MCLK) if(DBG_S68K_AS_N==1'b0 && DBG_S68K_A!==a_last) begin a_last<=DBG_S68K_A; sub_cycles++; end

   logic [7:0] h0,h1,h2,h3,ptl,pth; logic [15:0] pt; int i;
   initial begin
      RST_N=1'b0; repeat(50) @(posedge CLK); RST_N=1'b1; repeat(50) @(posedge CLK);
      $display("======== MCD sub-CPU CDC bench ========");
      // boot: mcdReset + mcdExec (PRG-RAM preloaded)
      ext_wr('h12002,16'hFF00,1'b1,1'b0);
      ext_wr('h12000,16'h0003,1'b0,1'b1); ext_wr('h12000,16'h0002,1'b0,1'b1); ext_wr('h12000,16'h0000,1'b0,1'b1);
      ext_wr('h1200E,16'h0000,1'b1,1'b0); ext_wr('h12002,16'h0000,1'b1,1'b0); ext_wr('h12000,16'h0001,1'b0,1'b1);
      $display("  boot writes done @ %0t (sub_cycles=%0d)", $time, sub_cycles);
      repeat(30000) @(posedge MCLK);   // let the sub boot to cmd_rx
      ext_wr16('h12010, 16'h0000);     // mcdInit: *cmd_idx = 0 -> sub leaves the boot spin, STA_BSY=0
      repeat(2000) @(posedge MCLK);
      $display("  sub booted: %0d bus cycles, last A=%06h", sub_cycles, a_last);
      // relay smoke test: write/read PRG word-RAM via the sub
      mcd_wr16('h010000, 16'h1234); mcd_rd16('h010000, pt);
      $display("  relay test: wrote PRG 010000=1234, read=%04h %s", pt, (pt==16'h1234)?"OK":"MISMATCH");
      // INIT: decoder on, feed a real sector, read HEAD/PT via relay
      cdc_sel(8'h0F); cdc_wr(8'h00);
      cdc_sel(8'h0A); cdc_wr(8'h84); cdc_wr(8'hC0);
      cdc_sel(8'h01); cdc_wr(8'h62);
      for(i=0;i<1176;i++) feed_word(sector_word[i]);
      repeat(4000) @(posedge CLK);
      cdc_sel(8'h04); cdc_rd(h0); cdc_rd(h1); cdc_rd(h2); cdc_rd(h3); cdc_rd(ptl); cdc_rd(pth);
      $display("  [init] HEAD=%02h %02h %02h %02h  PT=%02h%02h  %s",
               h0,h1,h2,h3,pth,ptl, ({h3,h2,h1,h0}==32'h01000200)?"HEAD OK":"HEAD MISMATCH");
      $display("======== done (sub_cycles=%0d) ========", sub_cycles);
      $finish;
   end
   initial begin #400000000; $display("WATCHDOG"); $finish; end
endmodule
