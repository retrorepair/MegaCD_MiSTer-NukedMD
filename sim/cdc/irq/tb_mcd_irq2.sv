// ============================================================================
// tb_mcd_irq2.sv - INSTRUMENTED copy of tb_mcd_irq.sv.
//
// Same DUT, same stimulus, same measurement of the sub-CPU level-2 exception.
// Added probes (all hierarchical reads; nothing under rtl/ is touched):
//   * per bus cycle: the time /UDS|/LDS first goes low relative to /AS falling
//     (the 68000 asserts the data strobes in S2 on a read but only in S4 on a
//     write, one full CPU clock later), and DS -> DTACK on top of that;
//   * PRG_RDY, PRSS and S68K_PRGRAM_DTACK_N sampled at that DS edge, so the
//     PRS_IDLE guards can be seen taking effect (or not);
//   * +fine=N prints a per-CLK-edge log of the whole exception for offset N.
//   * an aggregate AS->DS / DS->DTACK table over the whole sweep.
// ============================================================================
`timescale 1ns/1ps

module tb_mcd_irq2;
   logic MCLK=0; always #4.657 MCLK=~MCLK;   // 107.386 MHz
   logic CLK =0; always #9.313 CLK =~CLK;    // 53.693 MHz
   logic RST_N=0, ENABLE=1'b1;

   bit  EN50SEL = 1'b1;
   logic en50_m=0; integer acc_m=0;
   always @(posedge MCLK) begin en50_m<=1'b0; acc_m=acc_m+50000000; if(acc_m>=107386350) begin acc_m=acc_m-107386350; en50_m<=1'b1; end end
   logic en50_c=0; integer acc_c=0;
   always @(posedge CLK)  begin en50_c<=1'b0; acc_c=acc_c+50000000; if(acc_c>= 53693175) begin acc_c=acc_c- 53693175; en50_c<=1'b1; end end
   wire EN50 = EN50SEL ? en50_c : en50_m;

   logic [17:1] EXT_VA='0; logic [15:0] EXT_VDI='0; wire [15:0] EXT_VDO;
   logic EXT_AS_N=1'b1,EXT_RNW=1'b1,EXT_LDS_N=1'b1,EXT_UDS_N=1'b1; wire EXT_DTACK_N;
   logic EXT_ASEL_N=1'b1,EXT_RAS2_N=1'b1,EXT_ROM_N=1'b1,EXT_FDC_N=1'b1;

   int PRGLAT = 3;
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
   // mcd-verificator IRQ TEST 0A deadline, MEASURED (not assumed) in sim/main68k:
   // 55 main-CPU clocks at 7.670454 MHz between the gate array's own two events -
   // INT_PEND(2) <= '1' at S4 of the arming write to $A12000, and
   // M68K_REG_DO <= CS(3) at S2 of the read of $A12026 (ASIC.vhd:561, 615-616, 757).
   // The old 6779 ns figure was the gap between the two *bus cycles*, which is
   // exactly 52 clocks but is 3 clocks short of the interval that actually matters.
   localparam real DEADLINE_NS = 55.0 * 130.3707;   // 7170.4 ns  (was 6779.0)

   localparam int TO=200000;
   real t_ext_end = 0.0;
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

   // ==========================================================================
   //                       SUB-CPU BUS-CYCLE TRACER
   // ==========================================================================
   localparam int MAXC = 96;
   int    sclk = 0;
   logic  clk68_p = 1'b0, as_p = 1'b1;
   bit    e_p = 1'b0; int e_phase = 0;

   bit    tr_arm = 0, tr_run = 0, tr_done = 0, cy_open = 0;
   real   t_req = 0.0; int sclk_req = 0;
   int    n_cyc = 0;

   real   cy_t0; int cy_s0; bit cy_pre;
   logic [23:0] cy_a; logic [2:0] cy_fc; logic cy_rnw, cy_uds, cy_lds;
   bit    cy_gotterm; real cy_tterm; int cy_term;
   bit    cy_e; int cy_ep;
   real   cy_tds; bit cy_rdy_ds; int cy_prss_ds; bit cy_dtn_ds;

   real   L_t0[MAXC], L_t1[MAXC], L_tt[MAXC], L_tds[MAXC];
   int    L_s0[MAXC], L_s1[MAXC], L_term[MAXC], L_prss[MAXC];
   logic [23:0] L_a[MAXC]; logic [2:0] L_fc[MAXC]; logic L_rnw[MAXC], L_uds[MAXC], L_lds[MAXC];
   bit    L_pre[MAXC]; bit L_e[MAXC]; int L_ep[MAXC]; bit L_rdy[MAXC]; bit L_dtn[MAXC];

   // PRSS enum position (VHDL enumeration read through the mixed-language interface)
   int prss_i = -1;
   always @(posedge MCLK) prss_i = dut.ASIC.PRSS;

   always @(posedge MCLK) begin
      if (dut.S68K_CLK===1'b1 && clk68_p===1'b0) begin
         sclk = sclk + 1;
         if ((dut.S68K.E===1'b1) !== e_p) begin e_p = (dut.S68K.E===1'b1); e_phase = 0; end
         else e_phase = e_phase + 1;
      end
      clk68_p = (dut.S68K_CLK===1'b1);

      if (tr_arm && !tr_run && !tr_done && dut.ASIC.INT_PEND[2]===1'b1) begin
         tr_run = 1; t_req = $realtime; sclk_req = sclk; n_cyc = 0;
         if (dut.S68K_AS_N===1'b0) begin
            cy_open=1; cy_pre=1; cy_t0=$realtime; cy_s0=sclk; cy_gotterm=0; cy_term=0; cy_tterm=0.0; cy_uds=1'b1; cy_lds=1'b1; cy_e=e_p; cy_ep=e_phase;
            cy_tds=0.0; cy_rdy_ds=1'b1; cy_prss_ds=-1; cy_dtn_ds=1'b1;
         end
      end

      if (tr_run && !tr_done) begin
         if (as_p===1'b1 && dut.S68K_AS_N===1'b0) begin
            cy_open=1; cy_pre=0; cy_t0=$realtime; cy_s0=sclk; cy_gotterm=0; cy_term=0; cy_tterm=0.0; cy_uds=1'b1; cy_lds=1'b1; cy_e=e_p; cy_ep=e_phase;
            cy_tds=0.0; cy_rdy_ds=1'b1; cy_prss_ds=-1; cy_dtn_ds=1'b1;
         end
         if (cy_open) begin
            cy_a = DBG_S68K_A; cy_fc = dut.S68K_FC; cy_rnw = dut.S68K_RNW;
            if (dut.S68K_UDS_N===1'b0) cy_uds = 1'b0;
            if (dut.S68K_LDS_N===1'b0) cy_lds = 1'b0;
            if (cy_tds==0.0 && (dut.S68K_UDS_N===1'b0 || dut.S68K_LDS_N===1'b0)) begin
               cy_tds     = $realtime;
               cy_rdy_ds  = (PRG_RDY===1'b1);
               cy_prss_ds = prss_i;
               cy_dtn_ds  = (dut.ASIC.S68K_PRGRAM_DTACK_N===1'b1);
            end
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
               L_t0[n_cyc]=cy_t0; L_t1[n_cyc]=$realtime; L_tt[n_cyc]=cy_tterm; L_tds[n_cyc]=cy_tds;
               L_s0[n_cyc]=cy_s0; L_s1[n_cyc]=sclk; L_term[n_cyc]=cy_term;
               L_a[n_cyc]=cy_a; L_fc[n_cyc]=cy_fc; L_rnw[n_cyc]=cy_rnw;
               L_uds[n_cyc]=cy_uds; L_lds[n_cyc]=cy_lds; L_pre[n_cyc]=cy_pre; L_e[n_cyc]=cy_e; L_ep[n_cyc]=cy_ep;
               L_rdy[n_cyc]=cy_rdy_ds; L_prss[n_cyc]=cy_prss_ds; L_dtn[n_cyc]=cy_dtn_ds;
               n_cyc = n_cyc + 1;
            end
            cy_open = 0;
            if (cy_a==24'hFF8026 && cy_rnw===1'b0) begin tr_done=1; tr_run=0; end
         end
      end
      as_p = dut.S68K_AS_N;
   end

   // ---------------- per-CLK fine log (one offset only) ----------------
   int FINE = -1; int cur_off = -1; bit fine_on = 0;
   string prss_name [0:10] = '{"IDLE","WAIT","READ","WRITE","END","DMA_WAIT","DMA_WRITE","DMA_END","RFS_WAIT","RFS","RFS_END"};
   always @(posedge MCLK) begin
      if (fine_on && tr_run && !tr_done)
         $display("    |M %9.1f sclk=%0d C68=%b E=%b | AS=%b UDS=%b LDS=%b RW=%b A=%06h | PRG_RDY=%b PRSS=%-9s dtP=%b dtR=%b dtALL=%b | OE=%b WRL=%b WRH=%b",
                  $realtime - t_req, sclk-sclk_req, dut.S68K_CLK, dut.S68K.E,
                  dut.S68K_AS_N, dut.S68K_UDS_N, dut.S68K_LDS_N, dut.S68K_RNW, DBG_S68K_A,
                  PRG_RDY, prss_name[dut.ASIC.PRSS], dut.ASIC.S68K_PRGRAM_DTACK_N, dut.ASIC.S68K_REG_DTACK_N,
                  dut.S68K_DTACK_N, PRG_OE_N, PRG_WRL_N, PRG_WRH_N);
   end

   // ---------------- aggregate stats over the sweep ----------------
   // bucket 0 PRG read, 1 PRG write, 2 REG read, 3 REG write, 4 VPA
   real g_dsmin[0:4], g_dsmax[0:4], g_dssum[0:4];
   real g_dtmin[0:4], g_dtmax[0:4], g_dtsum[0:4];
   real g_asmin[0:4], g_asmax[0:4], g_assum[0:4];
   int  g_n[0:4];
   int  g_rdy0[0:4];            // times PRG_RDY was 0 at the DS edge
   int  g_prssn[0:4];           // times PRSS was not IDLE at the DS edge

   // ---------------- report ----------------
   int iack_len_clk, iack_idx;
   real tot_from_req, tot_from_ext, tot_to_cs3;
   task automatic dump_trace(input int off, input bit verbose);
      int i, prev_s0, b; string fcs; string tns; string note; real dds, ddt, das;
      iack_len_clk = -1; iack_idx = -1;
      if (verbose) begin
         $display("  -----------------------------------------------------------------------------------------------------------------------------");
         $display("   #  AS_fall(+ns)  clk  A         FC  RW  DS   ASlow  term  AS->DS  DS->term  AS->term  len  cum(ns)   E/ph  PRSS@DS  RDY@DS");
         $display("  -----------------------------------------------------------------------------------------------------------------------------");
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
         if (L_pre[i]) note = " <-inflight";
         if (L_fc[i]==3'b111 && iack_idx<0) begin iack_idx=i; iack_len_clk = L_s1[i]-L_s0[i]; end
         dds = (L_tds[i]!=0.0) ? (L_tds[i]-L_t0[i]) : -1.0;
         ddt = (L_term[i]!=0 && L_tds[i]!=0.0) ? (L_tt[i]-L_tds[i]) : -1.0;
         das = (L_term[i]!=0) ? (L_tt[i]-L_t0[i]) : -1.0;
         if (verbose)
            $display("  %2d  %10.1f  %4d  %06h  %-3s %s  %s%s  %6.1f  %-4s  %6.1f  %8.1f  %8.1f  %3d  %8.1f  %s%0d  %-6s  %b%s",
                     i, L_t0[i]-t_req, L_s0[i]-sclk_req, L_a[i], fcs, (L_rnw[i]===1'b1)?"R":"W",
                     (L_uds[i]===1'b0)?"U":"-", (L_lds[i]===1'b0)?"L":"-",
                     L_t1[i]-L_t0[i], tns, dds, ddt, das,
                     L_s0[i]-prev_s0, L_t1[i]-t_req, L_e[i]?"H":"L", L_ep[i],
                     (L_prss[i]>=0 && L_prss[i]<=10) ? prss_name[L_prss[i]] : "?", L_rdy[i], note);
         prev_s0 = L_s0[i];
         // aggregate (skip the in-flight cycle: its AS fall is not the real one)
         if (!L_pre[i] && L_term[i]!=0 && L_tds[i]!=0.0) begin
            b = -1;
            if      (L_term[i]==1) b = 4;
            else if (L_term[i]==3) b = (L_rnw[i]===1'b1) ? 0 : 1;
            else if (L_term[i]==2) b = (L_rnw[i]===1'b1) ? 2 : 3;
            if (b>=0) begin
               if (g_n[b]==0) begin g_dsmin[b]=1e30; g_dsmax[b]=-1e30; g_dtmin[b]=1e30; g_dtmax[b]=-1e30; g_asmin[b]=1e30; g_asmax[b]=-1e30; end
               if (dds<g_dsmin[b]) g_dsmin[b]=dds;  if (dds>g_dsmax[b]) g_dsmax[b]=dds;  g_dssum[b]+=dds;
               if (ddt<g_dtmin[b]) g_dtmin[b]=ddt;  if (ddt>g_dtmax[b]) g_dtmax[b]=ddt;  g_dtsum[b]+=ddt;
               if (das<g_asmin[b]) g_asmin[b]=das;  if (das>g_asmax[b]) g_asmax[b]=das;  g_assum[b]+=das;
               if (!L_rdy[i])       g_rdy0[b]++;
               if (L_prss[i]!=0)    g_prssn[b]++;
               g_n[b]++;
            end
         end
      end
      tot_from_req = (n_cyc>0) ? (L_t1[n_cyc-1]-t_req)   : -1.0;
      // The deadline event is the CLK edge that loads CS(3) := 2, i.e. the instant the gate
      // array acknowledges the ISR's FF8026 write -- NOT the later /AS rise that ends the
      // 68000's bus cycle.  L_tt[] is exactly that edge.
      tot_to_cs3   = (n_cyc>0 && L_tt[n_cyc-1]!=0.0) ? (L_tt[n_cyc-1]-t_req) : -1.0;
      tot_from_ext = (n_cyc>0) ? (L_t1[n_cyc-1]-t_ext_end) : -1.0;
   endtask

   int sc_target;
   task automatic wait_sub_clks(input int n);
      sc_target = sclk + n;
      while (sclk < sc_target) @(posedge CLK);
   endtask

   task automatic int2_shot(input int off, input bit verbose, output bit ok);
      logic [15:0] v; logic [7:0] b; int t;
      mcd_rd8('hFF8000, b);
      ext_rd('h12026,1'b1,v);
      if (v[7:0]==8'd2) $display("    [warn] COMSTA3 still 2 before the arming write");
      repeat(200) @(posedge CLK);
      tr_arm=0; tr_run=0; tr_done=0; cy_open=0; n_cyc=0;
      wait_sub_clks(off);
      fine_on = (off==FINE);
      tr_arm=1;
      ext_wr('h12000, 16'h0100, 1'b1, 1'b0);
      t=0; while(!tr_done && t<20000) begin @(posedge CLK); t++; end
      ok = tr_done;
      tr_arm=0; fine_on=0;
      dump_trace(off, verbose);
      t=0; ok=0;
      for (t=0;t<4000;t++) begin ext_rd('h12026,1'b1,v); if(v[7:0]==8'd2) begin ok=1; break; end end
      if (!ok) $display("    [irq] off=%0d: NO INT2 SERVICE (A12026=%04h IPL=%b PEND2=%b)",
                        off, v, dut.S68K_IPL_N, dut.ASIC.INT_PEND[2]);
   endtask

   // ============================ main ============================
   int  sub_cycles=0; logic [23:0] a_last='1;
   always @(posedge MCLK) if(DBG_S68K_AS_N==1'b0 && DBG_S68K_A!==a_last) begin a_last<=DBG_S68K_A; sub_cycles++; end

   int off, i; bit ok;
   real tot_req_a [0:1023], tot_ext_a [0:1023], tot_cs3_a [0:1023]; int iack_a [0:1023]; int ncyc_a [0:1023];  // NOFF > 256 used to overflow these
   real mn, mx, sum; int imn, imx, nmiss;
   int NOFF = 13;
   string bname [0:4] = '{"PRG read ","PRG write","REG read ","REG write","VPA/IACK"};

   int en50arg = 1; int c0; real tm0;
   initial begin
      if (!$value$plusargs("prglat=%d", PRGLAT)) PRGLAT = 3;
      if (!$value$plusargs("noff=%d", NOFF))     NOFF   = 13;
      if (!$value$plusargs("en50=%d", en50arg))  en50arg= 1;
      if (!$value$plusargs("fine=%d", FINE))     FINE   = -1;
      EN50SEL = (en50arg!=0);
      for (i=0;i<5;i++) begin g_n[i]=0; g_dssum[i]=0.0; g_dtsum[i]=0.0; g_assum[i]=0.0; g_rdy0[i]=0; g_prssn[i]=0; end
      RST_N=1'b0; repeat(50) @(posedge CLK); RST_N=1'b1; repeat(50) @(posedge CLK);
      $display("======== MCD sub-CPU INT2 latency bench (INSTRUMENTED) ========");
      $display("  PRGLAT=%0d -> PRG_RDY low %0d CLK = %0.1f ns   fine log offset = %0d", PRGLAT, PRGLAT+1, (PRGLAT+1)*18.626, FINE);
      c0 = sclk; tm0 = $realtime; repeat(2000) @(posedge CLK);
      $display("  measured sub-CPU clock = %0.3f MHz", 1000.0*(sclk-c0)/($realtime-tm0));
      ext_wr('h12002,16'hFF00,1'b1,1'b0);
      ext_wr('h12000,16'h0003,1'b0,1'b1); ext_wr('h12000,16'h0002,1'b0,1'b1); ext_wr('h12000,16'h0000,1'b0,1'b1);
      ext_wr('h1200E,16'h0000,1'b1,1'b0); ext_wr('h12002,16'h0000,1'b1,1'b0); ext_wr('h12000,16'h0001,1'b0,1'b1);
      repeat(30000) @(posedge MCLK);
      ext_wr16('h12010, 16'h0000);
      repeat(2000) @(posedge MCLK);
      $display("  sub booted: %0d bus cycles, last A=%06h", sub_cycles, a_last);

      mcd_wr16('hFF8032, 16'h0004);
      $display("  IEN=%b (want xxx1x)", dut.ASIC.IEN);

      for (off=0; off<NOFF; off++) begin
         $display("");
         $display("  ==== offset %0d sub-CPU clocks ====", off);
         int2_shot(off, 1'b1, ok);
         tot_req_a[off]=tot_from_req; tot_ext_a[off]=tot_from_ext; tot_cs3_a[off]=tot_to_cs3;
         iack_a[off]=iack_len_clk; ncyc_a[off]=n_cyc;
         $display("  off=%0d: %0d bus cycles, IACK=%0d sub-clk, total from INT_PEND=%0.1f ns",
                  off, n_cyc, iack_len_clk, tot_from_req);
      end

      $display("");
      $display("======== SUMMARY (PRGLAT=%0d) ========", PRGLAT);
      mn=1e30; mx=-1e30; imn=0; imx=0; sum=0.0; nmiss=0;
      for (i=0;i<NOFF;i++) begin
         $display("  %3d  cycles=%0d  IACK=%0d  to_CS3=%0.1f  to_ASrise=%0.1f  %s", i, ncyc_a[i], iack_a[i], tot_cs3_a[i], tot_req_a[i],
                  (tot_cs3_a[i] <= DEADLINE_NS) ? "UNDER" : "OVER");
         if (tot_cs3_a[i] < mn) begin mn=tot_cs3_a[i]; imn=i; end
         if (tot_cs3_a[i] > mx) begin mx=tot_cs3_a[i]; imx=i; end
         sum = sum + tot_cs3_a[i];
         if (tot_cs3_a[i] > DEADLINE_NS) nmiss++;
      end
      $display("  INT_PEND(2) rise -> CS(3):=2 load :  min=%0.1f (off=%0d)  mean=%0.1f  max=%0.1f (off=%0d)  deadline=%0.1f  MISSES=%0d/%0d (%0.1f%%)",
               mn, imn, sum/NOFF, mx, imx, DEADLINE_NS, nmiss, NOFF, 100.0*nmiss/NOFF);
      $display("");
      $display("======== BUS-CYCLE TIMING BREAKDOWN (all %0d offsets) ========", NOFF);
      $display("  type        n     AS->DS (min/mean/max)      DS->term (min/mean/max)     AS->term (min/mean/max)   RDY=0@DS  PRSS/=IDLE@DS");
      for (i=0;i<5;i++) if (g_n[i]>0)
         $display("  %s %4d   %6.1f %6.1f %6.1f      %6.1f %6.1f %6.1f       %6.1f %6.1f %6.1f      %4d       %4d",
                  bname[i], g_n[i],
                  g_dsmin[i], g_dssum[i]/g_n[i], g_dsmax[i],
                  g_dtmin[i], g_dtsum[i]/g_n[i], g_dtmax[i],
                  g_asmin[i], g_assum[i]/g_n[i], g_asmax[i],
                  g_rdy0[i], g_prssn[i]);
      $display("======== done ========");
      $finish;
   end
   initial begin #300000000; $display("WATCHDOG"); $finish; end
endmodule
