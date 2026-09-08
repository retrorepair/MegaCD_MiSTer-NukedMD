// ============================================================================
// tb_mcd_irq.sv - MEASUREMENT bench for the sub-CPU level-2 (INT2) exception.
//
// Derived from sim/cdc/tb_mcd_cdc.sv (same MCD.vhd DUT, same real verificator sub
// BIOS in PRG-RAM, same main-side EXT bus tasks and COMCMD relay), stripped to the
// IRQ TEST 0A sequence and instrumented to log EVERY sub-CPU bus cycle between the
// INT2 request and the ISR's write of FF8026.
//
// Nothing under rtl/ is touched: every probe is a hierarchical read.
//
// PRG-RAM latency is a plusarg: +prglat=N  ->  PRG_RDY low for N+1 CLK (18.626 ns
// each).  N=3 is the legacy bench model (5 CLK / 93 ns busy); N=0 is the fast model
// (1 CLK / 18.6 ns busy) that matches the measured hardware AS->DTACK of ~31.9 ns.
// +off=N inserts N extra sub-CPU (12.5 MHz) clocks of delay before the arming write
// so the request lands in a different phase of the 68000's internal E clock.
// ============================================================================
`timescale 1ns/1ps

module tb_mcd_irq;
   logic MCLK=0; always #4.657 MCLK=~MCLK;   // 107.386 MHz
   logic CLK =0; always #9.313 CLK =~CLK;    // 53.693 MHz
   logic RST_N=0, ENABLE=1'b1;

   // ---- EN50: the ASIC's 50 MHz enable for the sub-CPU clock phase counter ----
   // LEGACY (tb_mcd_cdc.sv, +en50=0): generated in the MCLK (107.4 MHz) domain.  The ASIC
   //   samples CLK50_EN in the CLK (53.7 MHz) domain, and in this bench the CLK edges sit
   //   midway between MCLK edges, so HALF of those one-MCLK-wide pulses are never seen ->
   //   CLK_CNT steps at ~25 MHz and the sub-CPU clock comes out at ~6.7 MHz, not 12.5 MHz.
   // FIXED  (+en50=1, default): the real core (MegaCD.sv) makes this enable with CEGen on
   //   clk_sys, i.e. IN_CLK=53693175 OUT_CLK=50000000 in the CLK domain.  Same algorithm here.
   bit  EN50SEL = 1'b1;
   logic en50_m=0; integer acc_m=0;
   always @(posedge MCLK) begin en50_m<=1'b0; acc_m=acc_m+50000000; if(acc_m>=107386350) begin acc_m=acc_m-107386350; en50_m<=1'b1; end end
   logic en50_c=0; integer acc_c=0;
   always @(posedge CLK)  begin en50_c<=1'b0; acc_c=acc_c+50000000; if(acc_c>= 53693175) begin acc_c=acc_c- 53693175; en50_c<=1'b1; end end
   wire EN50 = EN50SEL ? en50_c : en50_m;

   logic [17:1] EXT_VA='0; logic [15:0] EXT_VDI='0; wire [15:0] EXT_VDO;
   logic EXT_AS_N=1'b1,EXT_RNW=1'b1,EXT_LDS_N=1'b1,EXT_UDS_N=1'b1; wire EXT_DTACK_N;
   logic EXT_ASEL_N=1'b1,EXT_RAS2_N=1'b1,EXT_ROM_N=1'b1,EXT_FDC_N=1'b1;

   // ---- PRG-RAM behavioural model, SDRAM-style RDY handshake ----
   int PRGLAT = 3;                          // legacy default; +prglat=N overrides
   wire [17:0] PRG_A; wire [15:0] PRG_DO; wire PRG_WRL_N,PRG_WRH_N,PRG_OE_N,PRG_RFS;
   logic [15:0] PRG_DI; logic PRG_RDY=1'b1; logic [15:0] prg [0:262143];
   initial $readmemh("prg_bios.hex", prg);
   logic [2:0] prg_cnt=0; logic prg_busy=0;
   always @(posedge CLK) begin
      if(!prg_busy) begin
         if(!PRG_OE_N||!PRG_WRL_N||!PRG_WRH_N) begin
            prg_busy<=1'b1; PRG_RDY<=1'b0; prg_cnt<=PRGLAT[2:0];
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
   real t_ext_end = 0.0;                    // AS rise of the last EXT cycle
   task automatic ext_wr(input int addr, input [15:0] val, input bit uds, input bit lds);
      int t; @(posedge CLK); #1;
      EXT_VA='0; EXT_VA[5:1]=((addr-'h12000)>>1); EXT_FDC_N=1'b0; EXT_ASEL_N=1'b1; EXT_RAS2_N=1'b1; EXT_ROM_N=1'b1;
      EXT_VDI=val; EXT_RNW=1'b0; EXT_UDS_N=~uds; EXT_LDS_N=~lds; EXT_AS_N=1'b0;
      t=0; while(EXT_DTACK_N!==1'b0 && t<TO) begin @(posedge CLK); t++; end
      repeat(3) @(posedge CLK); EXT_AS_N=1'b1; EXT_UDS_N=1'b1; EXT_LDS_N=1'b1; EXT_RNW=1'b1; EXT_FDC_N=1'b1;
      t_ext_end = $realtime;
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

   // ---------------- COMCMD relay (drives the real sub-CPU) ----------------
   localparam CMD_RD_B=1, CMD_WR_B=2, CMD_RD_W=3, CMD_WR_W=4;
   task automatic wait_bsy0();
      int t; logic [15:0] v; t=0;
      forever begin ext_rd('h12020,1'b1,v); if(v==16'h0) break; if(++t>40000) begin $display("  >>> relay HANG: sta_bsy!=0 @%0t",$time); break; end end
   endtask
   task automatic mcd_cmd(input [15:0] cmd);
      int t; logic [15:0] v;
      wait_bsy0(); ext_wr16('h12010, cmd);
      t=0; forever begin ext_rd('h12020,1'b1,v); if(v!=16'h0) break; if(++t>40000) begin $display("  >>> relay HANG: sub didnt ack cmd %0d @%0t",cmd,$time); break; end end
      ext_wr16('h12010, 16'h0000);
      wait_bsy0();
   endtask
   task automatic mcd_set_adr(input int addr);
      ext_wr16('h12014, addr[31:16]); ext_wr16('h12016, addr[15:0]);
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

   // ==========================================================================
   //                       SUB-CPU BUS-CYCLE TRACER
   // Everything below runs in ONE always @(posedge MCLK) block with blocking
   // assignments, so the sub-clock counter and the /AS edge detection can never
   // race each other.  Every edge is therefore reported with the same uniform
   // +1 MCLK (9.31 ns) sampling offset, which cancels in every delta.
   // ==========================================================================
   localparam int MAXC = 96;
   int    sclk = 0;                       // free-running 12.5 MHz sub-CPU clock count
   logic  clk68_p = 1'b0, as_p = 1'b1;
   bit    e_p = 1'b0; int e_phase = 0;

   bit    tr_arm = 0, tr_run = 0, tr_done = 0, cy_open = 0;
   real   t_req = 0.0; int sclk_req = 0;
   int    n_cyc = 0;

   real   cy_t0; int cy_s0; bit cy_pre;
   logic [23:0] cy_a; logic [2:0] cy_fc; logic cy_rnw, cy_uds, cy_lds;
   bit    cy_gotterm; real cy_tterm; int cy_term;   // 0 none 1 VPA 2 REG 3 PRG 4 WRAM 5 PCM 6 BRAM 7 ?
   bit    cy_e; int cy_ep;

   real   L_t0[MAXC], L_t1[MAXC], L_tt[MAXC];
   int    L_s0[MAXC], L_s1[MAXC], L_term[MAXC];
   logic [23:0] L_a[MAXC]; logic [2:0] L_fc[MAXC]; logic L_rnw[MAXC], L_uds[MAXC], L_lds[MAXC];
   bit    L_pre[MAXC]; bit L_e[MAXC]; int L_ep[MAXC];


   always @(posedge MCLK) begin
      // ---- 1. count sub-CPU (12.5 MHz) clock periods, rising edge of the CPU CLK pin
      if (dut.S68K_CLK===1'b1 && clk68_p===1'b0) begin
         sclk = sclk + 1;
         // E-clock phase: sub-CPU clocks since the last transition of the 68000's own E
         // output (E = CPU clock / 10, low 6 / high 4).  dut.S68K.E is an open output of
         // the M68K_WRAP instance, still driven by the gate-level model inside.
         if ((dut.S68K.E===1'b1) !== e_p) begin e_p = (dut.S68K.E===1'b1); e_phase = 0; end
         else e_phase = e_phase + 1;
      end
      clk68_p = (dut.S68K_CLK===1'b1);

      // ---- 2. start of the trace window: the gate array latches the INT2 request
      if (tr_arm && !tr_run && !tr_done && dut.ASIC.INT_PEND[2]===1'b1) begin
         tr_run = 1; t_req = $realtime; sclk_req = sclk; n_cyc = 0;
         if (dut.S68K_AS_N===1'b0) begin       // a bus cycle was already in flight
            cy_open=1; cy_pre=1; cy_t0=$realtime; cy_s0=sclk; cy_gotterm=0; cy_term=0; cy_tterm=0.0; cy_uds=1'b1; cy_lds=1'b1; cy_e=e_p; cy_ep=e_phase;
         end
      end

      // ---- 3. bus cycle capture
      if (tr_run && !tr_done) begin
         if (as_p===1'b1 && dut.S68K_AS_N===1'b0) begin
            cy_open=1; cy_pre=0; cy_t0=$realtime; cy_s0=sclk; cy_gotterm=0; cy_term=0; cy_tterm=0.0; cy_uds=1'b1; cy_lds=1'b1; cy_e=e_p; cy_ep=e_phase;
         end
         if (cy_open) begin
            cy_a = DBG_S68K_A; cy_fc = dut.S68K_FC; cy_rnw = dut.S68K_RNW;
            // latch the strobes as SEEN ASSERTED at any point in the cycle (they are released
            // on the same edge as /AS, so sampling at the rise alone always reads them high)
            if (dut.S68K_UDS_N===1'b0) cy_uds = 1'b0;
            if (dut.S68K_LDS_N===1'b0) cy_lds = 1'b0;
            if (!cy_gotterm) begin
               if (dut.S68K_VPA_N===1'b0) begin cy_gotterm=1; cy_term=1; cy_tterm=$realtime; end
               else if (dut.S68K_DTACK_N===1'b0) begin
                  cy_gotterm=1; cy_tterm=$realtime;
                  if      (dut.ASIC.S68K_REG_DTACK_N    ===1'b0) cy_term=2;
                  else if (dut.ASIC.S68K_PRGRAM_DTACK_N ===1'b0) cy_term=3;
                  else if (dut.ASIC.S68K_WORDRAM_DTACK_N===1'b0) cy_term=4;
                  else if (dut.ASIC.S68K_PCM_DTACK_N    ===1'b0) cy_term=5;
                  else if (dut.ASIC.S68K_BRAM_DTACK_N   ===1'b0) cy_term=6;
                  else                                           cy_term=7;
               end
            end
         end
         if (as_p===1'b0 && dut.S68K_AS_N===1'b1 && cy_open) begin
            if (n_cyc < MAXC) begin
               L_t0[n_cyc]=cy_t0; L_t1[n_cyc]=$realtime; L_tt[n_cyc]=cy_tterm;
               L_s0[n_cyc]=cy_s0; L_s1[n_cyc]=sclk; L_term[n_cyc]=cy_term;
               L_a[n_cyc]=cy_a; L_fc[n_cyc]=cy_fc; L_rnw[n_cyc]=cy_rnw;
               L_uds[n_cyc]=cy_uds; L_lds[n_cyc]=cy_lds; L_pre[n_cyc]=cy_pre; L_e[n_cyc]=cy_e; L_ep[n_cyc]=cy_ep;
               n_cyc = n_cyc + 1;
            end
            cy_open = 0;
            // the ISR's move.w #2,(FF8026).w -- the event the deadline is measured to
            if (cy_a==24'hFF8026 && cy_rnw===1'b0) begin tr_done=1; tr_run=0; end
         end
      end
      as_p = dut.S68K_AS_N;
   end

   // ---------------- report ----------------
   int iack_len_clk, iack_idx;
   real tot_from_req, tot_from_ext;
   task automatic dump_trace(input int off, input bit verbose);
      int i, prev_s0; string fcs; string tns; string note;
      iack_len_clk = -1; iack_idx = -1;
      if (verbose) begin
         $display("  --------------------------------------------------------------------------------------------------");
         $display("   #  AS_fall(+ns)  clk  A         FC  RW  DS   ASlow(ns) term     term@(+ns)  len(clk)  cum(ns)   E/phase");
         $display("  --------------------------------------------------------------------------------------------------");
      end
      prev_s0 = sclk_req;
      for (i=0; i<n_cyc; i++) begin
         case (L_fc[i])
            3'b001: fcs="ud"; 3'b010: fcs="up"; 3'b101: fcs="sd"; 3'b110: fcs="sp"; 3'b111: fcs="CPU";
            default: fcs="??";
         endcase
         case (L_term[i])
            1: tns="VPA"; 2: tns="REG"; 3: tns="PRG"; 4: tns="WRAM"; 5: tns="PCM"; 6: tns="BRAM";
            default: tns="none";
         endcase
         note = "";
         if (L_pre[i]) note = "  <- in flight at request";
         if (L_fc[i]==3'b111 && iack_idx<0) begin iack_idx=i; iack_len_clk = L_s1[i]-L_s0[i]; end
         if (verbose)
            $display("  %2d  %10.1f  %4d  %06h  %-3s %s  %s%s  %8.1f  %-5s  %8.1f  %6d    %8.1f   %s%0d%s",
                     i, L_t0[i]-t_req, L_s0[i]-sclk_req, L_a[i], fcs, (L_rnw[i]===1'b1)?"R":"W",
                     (L_uds[i]===1'b0)?"U":"-", (L_lds[i]===1'b0)?"L":"-",
                     L_t1[i]-L_t0[i], tns,
                     (L_term[i]!=0)? (L_tt[i]-L_t0[i]) : -1.0,
                     L_s0[i]-prev_s0, L_t1[i]-t_req, L_e[i]?"H":"L", L_ep[i], note);
         prev_s0 = L_s0[i];
      end
      tot_from_req = (n_cyc>0) ? (L_t1[n_cyc-1]-t_req)   : -1.0;
      tot_from_ext = (n_cyc>0) ? (L_t1[n_cyc-1]-t_ext_end) : -1.0;
   endtask

   // ---------------- one INT2 shot ----------------
   int sc_target;
   task automatic wait_sub_clks(input int n);
      sc_target = sclk + n;
      while (sclk < sc_target) @(posedge CLK);
   endtask

   task automatic int2_shot(input int off, input bit verbose, output bit ok);
      logic [15:0] v; logic [7:0] b; int t;
      // put the sub back in its FF8010 spin loop with FF8026 cleared (relay pass through 0x20c)
      mcd_rd8('hFF8000, b);
      ext_rd('h12026,1'b1,v);
      if (v[7:0]==8'd2) $display("    [warn] COMSTA3 still 2 before the arming write");
      repeat(200) @(posedge CLK);            // let the sub settle in the spin loop
      tr_arm=0; tr_run=0; tr_done=0; cy_open=0; n_cyc=0;
      wait_sub_clks(off);
      tr_arm=1;
      ext_wr('h12000, 16'h0100, 1'b1, 1'b0); // UDS, VDI(8)=1 -> INT2 request; t_ext_end set inside
      // let the exception run to completion (trace stops itself on the FF8026 write)
      t=0; while(!tr_done && t<20000) begin @(posedge CLK); t++; end
      ok = tr_done;
      tr_arm=0;
      dump_trace(off, verbose);
      // resynchronise with the sub (it must be back in the spin loop before the next shot)
      t=0; ok=0;
      for (t=0;t<4000;t++) begin ext_rd('h12026,1'b1,v); if(v[7:0]==8'd2) begin ok=1; break; end end
      if (!ok) $display("    [irq] off=%0d: NO INT2 SERVICE (A12026=%04h IPL=%b PEND2=%b)",
                        off, v, dut.S68K_IPL_N, dut.ASIC.INT_PEND[2]);
   endtask

   // ============================ main ============================
   int  sub_cycles=0; logic [23:0] a_last='1;
   always @(posedge MCLK) if(DBG_S68K_AS_N==1'b0 && DBG_S68K_A!==a_last) begin a_last<=DBG_S68K_A; sub_cycles++; end

   int off, i; bit ok;
   real tot_req_a [0:255], tot_ext_a [0:255]; int iack_a [0:255]; int ncyc_a [0:255];
   real mn, mx; int imn, imx;
   int NOFF = 13;

   int en50arg = 1; int c0; real tm0;
   initial begin
      if (!$value$plusargs("prglat=%d", PRGLAT)) PRGLAT = 3;
      if (!$value$plusargs("noff=%d", NOFF))     NOFF   = 13;
      if (!$value$plusargs("en50=%d", en50arg))  en50arg= 1;
      EN50SEL = (en50arg!=0);
      RST_N=1'b0; repeat(50) @(posedge CLK); RST_N=1'b1; repeat(50) @(posedge CLK);
      $display("======== MCD sub-CPU INT2 latency bench ========");
      $display("  EN50 domain = %s   PRGLAT=%0d -> PRG_RDY low %0d CLK = %0.1f ns",
               EN50SEL ? "CLK 53.69MHz (matches MegaCD.sv CEGen) [FIXED]" : "MCLK 107.4MHz [LEGACY tb_mcd_cdc.sv]",
               PRGLAT, PRGLAT+1, (PRGLAT+1)*18.626);
      // measure the sub-CPU clock the DUT actually produces
      c0 = sclk; tm0 = $realtime; repeat(2000) @(posedge CLK);
      $display("  measured sub-CPU clock = %0.3f MHz (%0d periods in %0.1f ns; want 12.500 MHz / 80.0 ns)",
               1000.0*(sclk-c0)/($realtime-tm0), sclk-c0, $realtime-tm0);
      ext_wr('h12002,16'hFF00,1'b1,1'b0);
      ext_wr('h12000,16'h0003,1'b0,1'b1); ext_wr('h12000,16'h0002,1'b0,1'b1); ext_wr('h12000,16'h0000,1'b0,1'b1);
      ext_wr('h1200E,16'h0000,1'b1,1'b0); ext_wr('h12002,16'h0000,1'b1,1'b0); ext_wr('h12000,16'h0001,1'b0,1'b1);
      repeat(30000) @(posedge MCLK);
      ext_wr16('h12010, 16'h0000);
      repeat(2000) @(posedge MCLK);
      $display("  sub booted: %0d bus cycles, last A=%06h", sub_cycles, a_last);

      mcd_wr16('hFF8032, 16'h0004);            // IEN(2) = 1
      $display("  IEN=%b (want xxx1x)", dut.ASIC.IEN);

      for (off=0; off<NOFF; off++) begin
         $display("");
         $display("  ==== offset %0d sub-CPU clocks ====", off);
         int2_shot(off, 1'b1, ok);
         tot_req_a[off]=tot_from_req; tot_ext_a[off]=tot_from_ext;
         iack_a[off]=iack_len_clk; ncyc_a[off]=n_cyc;
         $display("  off=%0d: %0d bus cycles, IACK=%0d sub-clk, total from INT_PEND=%0.1f ns, from EXT AS rise=%0.1f ns",
                  off, n_cyc, iack_len_clk, tot_from_req, tot_from_ext);
      end

      $display("");
      $display("======== SUMMARY (EN50=%s PRGLAT=%0d) ========", EN50SEL?"CLK/FIXED":"MCLK/LEGACY", PRGLAT);
      $display("  off  cycles  IACK(clk)   total_from_INT_PEND(ns)   total_from_EXT_AS_rise(ns)   deadline 6779 ns");
      mn=1e30; mx=-1e30; imn=0; imx=0;
      for (i=0;i<NOFF;i++) begin
         $display("  %3d  %6d  %9d   %21.1f   %24.1f   %s",
                  i, ncyc_a[i], iack_a[i], tot_req_a[i], tot_ext_a[i],
                  (tot_req_a[i] <= 6779.0) ? "UNDER" : "OVER");
         if (tot_req_a[i] < mn) begin mn=tot_req_a[i]; imn=i; end
         if (tot_req_a[i] > mx) begin mx=tot_req_a[i]; imx=i; end
      end
      $display("  min total (from INT_PEND) = %0.1f ns (off=%0d)   max = %0.1f ns (off=%0d)   deadline = 6779 ns", mn, imn, mx, imx);
      $display("======== done ========");
      $finish;
   end
   initial begin #300000000; $display("WATCHDOG"); $finish; end
endmodule
