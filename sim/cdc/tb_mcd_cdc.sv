// ============================================================================
// tb_mcd_cdc.sv - FAITHFUL sub-CPU CDC bench. Instantiates rtl/MCD/MCD.vhd (real
// gate-level sub-CPU running the verificator BIOS + ASIC + CDC + PCM), drives the
// main-side EXT bus, and relays FF80xx accesses THROUGH the real sub-CPU via the
// COMCMD mailbox (mcd.c protocol) -- so the SUB-dest host tests and the deep DMA3
// hang reproduce faithfully. A real CD sector is fed through CDC_DATA/CDC_DAT_WR.
//
// Stage: boot + relay + INIT + DMA3 0x22/0x23 (CDC->word-RAM DMA).
// The DMA-complete handshake is END-TO-END REAL: the CDC raises DTEI, the ASIC routes it
// to sub IPL5 (needs IEN(5) via FF8032), the real sub-CPU takes the interrupt and its ISR
// at 0x37c writes COMSTA[3] (FF8026)=5, and the main polls A12026 for that 5.  So a DMA
// machine that never completes shows up here exactly as it does on hardware: a hang.
//
// NOTE (relay): the sub sets STA_BSY:=cmd_idx at 0x22c BEFORE it dispatches to the handler,
// so BSY!=0 means "accepted", not "done".  Every relay command therefore ends with a
// wait_bsy0() -- without it the bench races ahead of the sub and e.g. the DTTRG write has
// not yet happened when we look, which looks exactly like a dead DMA machine.
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
      // The sub sets STA_BSY:=cmd_idx at 0x22c BEFORE dispatching to the handler, so BSY!=0 only
      // means "accepted", not "done".  It returns to 0x21c (STA_BSY:=0) after the handler has run.
      // Wait for that, or the access has not actually hit the CDC/gate array when we return.
      wait_bsy0();
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

   // ---------------- DMA3 test helpers (mcd-verificator) ----------------
   localparam [2:0] CDC_DST_MAIN=3'd2, CDC_DST_SUB=3'd3, CDC_DST_PCM=3'd4, CDC_DST_PRG=3'd5, CDC_DST_WRAM=3'd7;
   localparam CDC_IFCTRL=1, CDC_DBCL=2, CDC_DTACK_R=7, CDC_CTRL0=10, CDC_RST=15;
   localparam [7:0] IFCTRL_DOUTEN=8'h02, IFCTRL_DTEIEN=8'h40, EDT=8'h80, DSR=8'h40;
   localparam int POLL_BUDGET=20000, HANGV=32'h1000;   // A12026 polls; a real 2352 DMA sets FF8026=5 in << this

   // main-side (EXT) byte read = hi byte of an even A120xx
   task automatic ext_rd8_hi(input int addr, output [7:0] val); logic [15:0] d; ext_rd(addr,1'b1,d); val=d[15:8]; endtask
   // CDC config via the sub-CPU relay
   task automatic cdc_dtack();  cdc_sel(CDC_DTACK_R); cdc_wr(8'h00); endtask
   task automatic set_ifctrl(input [7:0] v); cdc_sel(CDC_IFCTRL); cdc_wr(v); endtask
   task automatic cdc_dma_setup(input [2:0] dst, input int N, input int ptv);
      mcd_wr8('hFF8004, {5'b0,dst});                    // DD=dst: resets DMAA, clears EDT
      cdc_sel(CDC_DBCL);                                // AR=2
      cdc_wr((N-1)&8'hFF); cdc_wr(((N-1)>>8)&8'hFF);    // DBCL,DBCH  (AR->4)
      cdc_wr(ptv&8'hFF);   cdc_wr((ptv>>8)&8'hFF);      // DACL,DACH  (AR->6=DTTRG)
   endtask
   task automatic dttrg(); cdc_wr(8'h00); repeat(400)@(posedge CLK); endtask   // AR=6 write triggers DMA; settle DTEN
   // internal-state probe: everything that gates DTTRG -> DTEN_N -> ASIC DMA
   task automatic probe(input string tag);
      $display("  [probe %-10s] AR=%1h DBC=%04h DAC=%04h IFCTRL=%02h IFSTAT=%02h DTEN_N=%b WAIT_N=%b EDT=%b DD=%b DS_idle_EDT",
               tag, dut.CDC.AR, dut.CDC.DBC, dut.CDC.DAC, dut.CDC.IFCTRL, dut.CDC.IFSTAT,
               dut.CDC_DTEN_N, dut.CDC_WAIT_N, dut.ASIC.EDT, dut.ASIC.DD);
   endtask
   task automatic set_dma_addr(input int byte_addr); mcd_wr16('hFF800A, (byte_addr>>3)); endtask
   task automatic cdc_end();
      cdc_sel(CDC_CTRL0); cdc_wr(8'h00); cdc_wr(8'h00);        // decoder off
      set_ifctrl(8'h00); set_ifctrl(IFCTRL_DOUTEN|IFCTRL_DTEIEN);
   endtask
   // word-RAM ownership / mode
   task automatic mcd_wram_mode_2m(); logic [15:0] v; mcd_rd16('hFF8002,v); v=v & ~16'h0014; mcd_wr16('hFF8002,v); endtask
   task automatic wram_to_sub(); ext_wr('h12002,16'h0002,1'b0,1'b1); endtask   // main: DMNA=1 -> WRAM to sub
   task automatic mem_wp_0();    ext_wr('h12002,16'h0000,1'b1,1'b0); endtask   // main: MEM_WP=0
   task automatic gvsync();      repeat(200)@(posedge CLK); endtask
   // FAITHFUL DMA-complete wait: the real sub takes the CDC level-5 IRQ (DTEI) and its ISR
   // writes COMSTA[3] (FF8026)=5.  Main polls A12026.  If the DMA machine hangs (no DTEI),
   // the sub never interrupts, FF8026 stays 0, and this times out -- reproducing the hang.
   task automatic wait_comsta5(input string label, output bit hung);
      int t; logic [15:0] v; t=0; hung=0;
      forever begin
         ext_rd('h12026,1'b1,v);
         if (v[7:0]==8'd5) break;
         if (++t>=POLL_BUDGET) begin hung=1; break; end
         if (t%1500==0) $display("    [poll %0d] A12026=%04h DBC=%04h DAC=%04h IFSTAT=%02h DTEN_N=%b EDT=%b",
                                 t, v, dut.CDC.DBC, dut.CDC.DAC, dut.CDC.IFSTAT, dut.CDC_DTEN_N, dut.ASIC.EDT);
      end
      if (hung) $display("  >>> HANG @ %s (A12026 poll %0d reads, last=%04h)", label, t, v);
   endtask

   // ============================ main ============================
   int  sub_cycles=0; logic [23:0] a_last='1;
   always @(posedge MCLK) if(DBG_S68K_AS_N==1'b0 && DBG_S68K_A!==a_last) begin a_last<=DBG_S68K_A; sub_cycles++; end
   // ISR-entry probe: count times the sub fetches in the lvl5/lvl6 ISR window (0x37c..0x392)
   int  isr_hits=0; logic [23:0] isr_a='1;
   always @(posedge MCLK) if(DBG_S68K_AS_N==1'b0 && DBG_S68K_A>=24'h00037c && DBG_S68K_A<=24'h000392 && DBG_S68K_A!==isr_a) begin isr_a<=DBG_S68K_A; isr_hits++; end

   logic [7:0] h0,h1,h2,h3,ptl,pth,fl; logic [15:0] pt; int i; int PT; bit hung;
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
      PT = (pth<<8)|ptl;
      $display("  [init] HEAD=%02h %02h %02h %02h  PT=%04h  %s",
               h0,h1,h2,h3,PT, ({h3,h2,h1,h0}==32'h01000200)?"HEAD OK":"HEAD MISMATCH");

      // ---------------- DMA3: WRAM transfer (the first unbounded while(COMSTA[3]!=5)) ----------------
      // Faithful end-to-end: main sets up + triggers the WRAM DMA via the sub relay, then polls the
      // real A12026 that the sub's CDC-IRQ ISR writes to 5 on DTEI.  On build-36 CDC the DMA finishes
      // (COMSTA3=5); on the build-40 variants the DMA machine is expected to hang here (no DTEI).
      cdc_end();                                   // decoder off, IFCTRL re-armed (DOUTEN|DTEIEN)
      mcd_wr16('hFF8032, 16'h0020);                // IEN(5)=1: route the CDC (DTEI) IRQ to sub IPL5
                                                   //   (gate-array int mask, FF8032 low byte, DI(6:1))
      $display("  [dbg] after FF8032 write: IEN=%b  isr_hits=%0d", dut.ASIC.IEN, isr_hits);
      mcd_wram_mode_2m(); wram_to_sub(); gvsync(); mem_wp_0();
      wram_to_sub(); gvsync();
      cdc_dtack();               probe("after_dtack");
      cdc_dma_setup(CDC_DST_WRAM, 2352, PT);  probe("after_setup");
      set_dma_addr(0);           probe("after_dmaaddr");
      dttrg();                   probe("after_dttrg");
      ext_rd8_hi('h12004,fl);
      $display("  [dma3] 0x22 pre-poll A12004 flags=%02h (exp 07/47)  IEN=%b isr_hits=%0d IPL_N=%b CDC_INT_N=%b",
               fl, dut.ASIC.IEN, isr_hits, dut.S68K_IPL_N, dut.CDC_INT_N);
      probe("mid_poll_0");
      wait_comsta5("DMA3 0x22 WRAM", hung);
      probe("post_poll");
      $display("  [dbg] post-poll: isr_hits=%0d IPL_N=%b CDC_INT_N=%b", isr_hits, dut.S68K_IPL_N, dut.CDC_INT_N);
      if (hung) $display("  CDC DMA3 (WRAM)  HANG");
      else begin
         ext_rd8_hi('h12004,fl);
         ext_rd8_hi('h12004,fl);
         $display("  [dma3] 0x23 post-DMA A12004 flags=%02h (exp 87)  %s", fl, (fl==8'h87)?"OK":"MISMATCH");
         $display("  CDC DMA3 (WRAM)  %s", (fl==8'h87)?"PASS":"FLAGS-DIFF");
      end
      $display("======== done (sub_cycles=%0d) ========", sub_cycles);
      $finish;
   end
   initial begin #900000000; $display("WATCHDOG"); $finish; end
endmodule
