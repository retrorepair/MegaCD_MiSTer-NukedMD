# HANDOFF — MegaCD on NukedMD (session 2026-09-03)

## What this tree is
`MegaCD_MiSTer-master` with the fpgagen Genesis replaced by NukedMD-FPGA. The pristine
upstream tree is kept next to it in `MegaCD_MiSTer-master_ORIG` for diffing.

## Done this session
- Removed `rtl/GEN` (fpgagen: gen.sv, vdp, T80, jt12, jt89, gen_io, multitap, CART.vhd, ...),
  the Quartus 13 project files, ddram/cache (dead, `use_sdr=1`) and mlab.vhd (unused).
- Imported from `MegaDrive_MiSTer-main`: `rtl/nuked-md/*`, `nuked-md.qip`, `ram_md.v`,
  `audio_cond.sv`, `video_cond.sv`, `md_io.sv`, `pad_io.sv`, `teamplayer.sv`, `fourway.sv`,
  `multitap_sms.sv`, `saturn_keyboard.sv`, `lightgun.sv`, `EEPROM_STM95.sv`, `bram.vhd`
  (byteena version), `cofi.sv`. Kept MegaCD's `CEGen.vhd` (rising edge), `genesis_lpf.v` and
  `audio_iir_filter.v` (they export `ce_out`, needed by `audio_fix`).
- `rtl/nuked-md/md_board.v`: expansion connector brought out (`exp_*`), `ext_cart` (/CART pin)
  and `ext_disk` (I/O chip DISK pin) inputs, expansion data drive into the VD mux. Marked
  `// MegaCD`.
- New `rtl/mcd_cart.sv`: ROM cart (SSF2 banks, Pier Solar EEPROM/protection) and backup RAM
  cart (ID/RAM/WP) on the NukedMD cart connector, SDRAM-backed, data returned inside the
  fixed /CE0 cycle (same scheme as cartridge.sv).
- `rtl/sdram.sv`: 5 ports (cart, BIOS, PRG-RAM, PCM RAM, load/save), fixed priority.
- `rtl/audio_cond.sv`: Mega CD audio mixed in before the Genesis LPF ("CD Audio: Filtered"),
  FM/PSG debug mutes, `ce_out` for `audio_fix`.
- `MegaCD.sv`: rewritten around md_board + MCD. Status bits kept where the option survived.
  Dropped fpgagen-only options: Sprite Limit High, HiFi PCM, BGA/BGB/SPR toggles, Adaptive blend.
  Added: Keyboard, SNAC port select, Pause when OSD open, Stereo mix. No TMSS (no ROM index free).
- **Expansion timing decision**: the FC1004 arbiter auto-DTACKs every A23=0 access one VCLK
  after /AS (traced in ym6045.v; no cart/expansion gating). So the Mega CD must answer inside
  the fixed 68k cycle. The ASIC is fed `/AS` where it expected `/ASEL` (ASEL comes one VCLK
  late), /ROM, /RAS2, /FDC are the real pins. The MCD's /DTACK is still driven onto the bus
  (harmless, earlier than the arbiter's).
- **Fit**: NukedMD + Mega CD needs more M10K than the 5CSEBA6 has (561 vs 553 before fixes).
  Two zero-behaviour-change fixes applied:
  1. `rtl/pcm_mem.sv` + `PCM.vhd`/`ASIC.vhd`/`MCD.vhd`: PCM wave RAM (64KB) in SDRAM
     (write FIFO, read holds sub-CPU /DTACK via `PCM_RDY`, fetch issued on address change).
  2. `rtl/ram_md.v`: VRAM banks write full 256-bit rows (byte merge in logic) so M10K x40
     mode is used: 7 blocks per bank instead of 13.
  Expected total ~511 blocks.
- Simulation bench in the scratchpad `sim/` dir (ModelSim ASE): `compile.sh`, `run.sh`,
  `tb_mcd.sv`, `sdram_model.sv`, real `boot.rom` (pulled from the MiSTer). Measures margin of
  every expansion read against the /AS end. ModelSim Starter throttles this design to a few
  microseconds per minute — only useful for the first bus cycles.

## Open / next
- Build result of the third Quartus run (started 23:32). If it fits: deploy
  `output_files/MegaCD.rbf` to `/media/fat/_Test/` on the MiSTer,
  load via `echo "load_core <path>" > /dev/MiSTer_cmd`, watch COM3 (HPS console, 115200).
- Hardware checks in order: BIOS boot screen, RAM cart detection (Backup RAM = Internal+Cart),
  CD boot of a USA title, CDDA/PCM audio, Pier Solar cart.rom if available.
- If BIOS/PRG-RAM reads are marginal on hardware: next lever is the S1 speculative start
  (issue the SDRAM read from the address alone, before /AS) or BIOS in BRAM (needs the
  M10K budget: 128 blocks, not available).
- MegaCD.CFG on the MiSTer is from the old core; status bits were kept compatible where the
  option survived, new options sit in bits 60-66.

## Build 1 results (2026-09-04 00:09, deployed as _Console/MegaCD_TEST_NukedMD_20260904.rbf)
- Fit: 35,663/41,910 ALMs (85%), 553/553 M10K, 56 DSP.
- Timing (slow 85C): worst setup -3.38ns @107MHz, -1.75ns @53.7MHz.
  * 107MHz top paths: VD -> CODES (cheat engine, 32-way compare) -> m68k_data. Fixed in
    cheatcodes.sv by registering the address match (not yet built).
  * 107MHz next: ym7101 internals / AS -> md_board VD[8] mux (-2.46ns): NukedMD itself.
  * 53.7MHz: audio_cond psg_iir multiplier (-1.75ns): stock module, consumed at 7MHz ce.
- TimeQuest helper scripts: sta_paths.tcl / sta_paths2.tcl (quartus_sta -t).

## Simulation result (2026-09-04 01:05)
ModelSim needed explicit power-up values (md_board MCLK_e/bus regs, sdram state/mode — all
0 in hardware anyway) and a force of the arbiter's 17ms power-on timer (w328) to get going.
With that, the bench boots the real BIOS: vectors FFFF FD00 0000 0426 read correctly,
gate array /DTACK 75-84ns after /AS, data on VD at 84-93ns, 223-233ns margin to the 68k
latch. The arbiter's own DTACK arrives at 121ns, /ASEL at 112ns. So the expansion glue is
functionally right; the hardware black screen (build 1/2) must come from something the sim
does not model: the BIOS download into SDRAM, or silicon timing. Build 3 adds a 32-cycle
bus trace to the telemetry to decide.

## Root cause of the black screen (build 4 trace, 2026-09-04 02:15)
Hardware trace: SDRAM returns the right BIOS word (FD00 @ 65ns), gate array DTACKs @ 84ns,
but the bus ends the cycle with 0000 on ~1 in 15 ROM reads. The gate array's EXT_VDO gives
word-RAM data priority over ROM data, and the FC1004 arbiter pulses /RAS2 (CAS-before-RAS,
/CAS2 already low) to refresh the expansion DRAM in the middle of unrelated CPU cycles. The
ASIC treated every /RAS2 low as a word RAM access -> zeros won. fpgagen's /RAS2 was a pure
address decode, so this never happened before. Fix (MegaCD.sv): word RAM select is set only
when /RAS2 falls with /CAS2 high, held to the end of the bus cycle (exp_ras2_acc). Build 5.

## Build 5 (2026-09-04 02:55) — BIOS boots
Telemetry after the /RAS2 fix: every traced fetch matches the SDRAM word, late=0, main CPU
~1.1M BIOS fetches/s, sub CPU >100M PRG-RAM accesses, RAM-cart probes, VDP polling loops.
Fit 36,886 ALMs (88%), 553/553 M10K; timing -2.9ns@107 / -1.4ns@53.7 (slow corner).
`nodtack` grows ~16k/s: those are the raw /RAS2 refresh pulses the telemetry still counts
as expansion reads (classification only; the gate array ignores them now).
Not yet exercised on hardware: CD boot (CDC/CDDA path unchanged from upstream), PCM audio
(wave RAM now in SDRAM via pcm_mem.sv), RAM cart save/load, ROM cart / Pier Solar.
The telemetry block (mcd_debug.sv) is still in the build; drop it from files.qip and the
DDRAM assigns in MegaCD.sv for a release build.

## Build 6 (2026-09-04 03:40) — deployed, boots
Cheat engine data path reduced to one compare; timing -2.59ns@107 (TNS -764) / -1.7ns@53.7.
Telemetry identical to build 5 plus the Mega CD green LED asserted by the sub-CPU BIOS.
Deployed as _Console/MegaCD_TEST_NukedMD_20260904.rbf and in releases/.
Waiting for the user's visual/CD verdict. Telemetry reader: `python3 /media/fat/mcd_telemetry.py [interval] [count]`.
Build 6 worst paths (slow corner): all ym7101 mclk_clk3_l -> md_board VD mux / ram_68k
address (-2.6ns), i.e. NukedMD internals as in the MegaDrive core; the Mega CD glue and the
cheat engine no longer appear. Next timing lever, if ever needed: seed sweep or the
MegaDrive core's fitter settings are already applied (AGGRESSIVE PERFORMANCE).

## Build 7 (2026-09-04 08:05) — /RAS2 decoded by address window
Build 6 ran for a while then the main CPU crashed (AS frozen): RAS-only refresh pulses on
/RAS2 during RAM/VDP cycles (/CAS2 high) passed the CAS-before-RAS rule and became word RAM
writes of bus garbage. Build 7 qualifies /RAS2 with the word RAM window. Telemetry: word RAM
accesses ~140k/s, ignored refresh pulses ~65k/s, late=0, CPU running. Timing -1.75ns@107.

## Build 7 screen = stripes every 4px (2026-09-04 08:30)
Screenshot (/media/fat/screenshots/MegaCD, `echo "screenshot name" > /dev/MiSTer_cmd`): border
colour right, active area one repeated word. VDP DMA from the expansion returned the same word:
during VDP DMA the FC1004 drives /AS,/UDS,/LDS inactive; /ROM or /RAS2 stay asserted for the
burst (address decode with w223=0), /ASEL follows w254, and the per-word strobe is CAS0
(cart_oe = vdp_dma_oe_early). fpgagen presented DMA to the gate array as word reads with
strobes, so MegaCD.sv now synthesises select+UDS+LDS from cart_dma & cart_oe (dma_rd) and
the word RAM select is a level (/RAS2 low inside the window). Build 9. Telemetry traces DMA
strobes as cycles (flag DMA).

## Build 9 lost, build 10 = DMA fix + cartridge slot (2026-09-04 09:08)
Editing files.qip while a flow runs makes Quartus rewrite MegaCD.qsf mid-flow (error 125085,
inlines 300 lines) and the fitter then died (293007). Rule: never touch files.qip/qsf/sources
while quartus_sh runs; keep a copy of the 62-line qsf. Build 10 carries the DMA select
synthesis plus the new cartridge slot (mcd_cart.sv v2, EEPROM_24CXX.sv, OSD FS6, J-Cart
option status[31]); the cart logic is inert until a cartridge is inserted.

## Build 10 verified (2026-09-04 09:45) — BIOS screen correct, cartridge path broken
Screenshot of build 10: Mega-CD logo, "(c) 1993 SEGA Ver. 2.00", "PRESS THE START BUTTON"
drawn correctly, border right. So the DMA select synthesis (dma_rd) was the last piece for
the BIOS. Fit 36,398/41,910 ALMs (87%), 553/553 M10K, 56 DSP; setup -2.03ns@107 / -0.93ns@53.7
(slow corner, NukedMD internals).
Cartridge test (Alien 3 via an MGL, index 6): black screen. Two findings:
- MGL relative paths resolve against Main's HomeDir, which on this MiSTer is the CIFS share
  cifs/MegaCD (Main prints "Found CIFS dir"); use absolute paths in test MGLs. Main console
  output is on COM3 (115200); a stale COM3 logger from last night was killed.
- Real bug (telemetry: CPU running, every cart read = 0000): mcd_cart.sv's SRAM clear sweep
  held its SDRAM write request high; sdram.sv accepts a request on the rising edge only, so
  the sweep wrote one word and stalled forever while masking all cartridge reads. Fixed: one
  request pulse per word, and `clearing` extends md_reset until the sweep is done (~15ms,
  longer than the ~1.8ms post-download reset). Build 11 started 09:58.
Test MGL on the MiSTer: /media/fat/_Console/MegaCD_cart_test.mgl (absolute path to
/media/fat/games/MegaCD/Alien3.bin, index 6). Note the telemetry dl_words counter counts
each ioctl_wr twice (53MHz pulse sampled at 107MHz): BIOS 128KB -> 131072, 512KB cart -> 524288.

## Build 11 (2026-09-04 10:32) — BIOS and cartridge both verified on hardware
Deployed as _Console/MegaCD_TEST_NukedMD_20260904.rbf and releases/. Screenshots: BIOS 2.00
boot screen (no cart), Alien 3 attract mode + intro (cart inserted via the MGL). Telemetry
in cart mode: bus data matches the ROM words at the traced addresses, /RAS2 never accepted
(word RAM window moved to 600000), no late reads.
Fit 36,060/41,910 ALMs (86%), 553/553 M10K, 56 DSP, 56,119 registers. Timing (slow 85C):
-2.68ns@107MHz (TNS -1322), -1.90ns@53.7MHz — same NukedMD-internal paths as before,
placement varies build to build; the core runs.
Test MGL now points at the original ROM in games/MegaDrive (the Alien3.bin copy was removed).
Still untested on hardware: CD boot (no CD image available here), PCM audio, RAM cart
save/load, Pier Solar / EEPROM / J-Cart mappers. The telemetry block is still in the build.

## Build 12 (2026-09-04 11:35) — TMSS, verified
TMSS as in the MegaDrive core: 2KB ROM auto-loaded by Main as `boot2.rom` from the core
folder (index 80 hex; boot1.rom = index 40 is what Main uses for cart.rom next to a CD, so it
is not usable), stored in MLABs (no M10K free), OSD "TMSS" (status[9], menumask bit 3 =
tmss_loaded). Main takes this core's folder from the user's CIFS share (cifs/MegaCD), so the
ROM was copied there and to games/MegaCD. Verified: "PRODUCED BY OR UNDER LICENSE FROM SEGA
ENTERPRISES LTD." then Alien 3. Fit 37,158 ALMs (89%), 553 M10K. Test trick: set status bits
in /media/fat/config/MegaCD.CFG (16 bytes = status[127:0]) before loading via MGL.
Main cannot load games/MegaDrive/boot.rom for this core nor start the cartridge browser
outside games/MegaCD (SelectFile resets any path outside the core's home); user accepted.

## Build 13 (started 11:45) — Nuked 68000 as Mega CD sub-CPU, VRAM block RAM fix
- rtl/MCD/MC68K.vhd now wraps nuked-md's m68kcpu instead of FX68K (rtl/FX68K removed).
  The model samples CLK as a level on MCLK (new MCD/M68K_WRAP port, 107.38 MHz); the
  12.5 MHz clock is rebuilt from CLK_12M_R/F. RESET pulls HALT low too (68000 reset needs
  both; the board's SRES drives both). Released strobes read as '1'.
- Fitter RAM summary showed the VRAM banks as True Dual Port 256x256 (13 M10K each) although
  vram_ip only needs a single port: bram.vhd's spram_sz carries
  `lpm_hint ENABLE_RUNTIME_MOD=YES` (In-System Memory Content Editor), which forces the
  bidirectional mode plus a JTAG hub on every spram. Set to NO: expected 7 blocks per bank
  (-48 M10K), which pays for the Nuked sub-CPU microcode (+14 M10K, -6 for FX68K).
- Cost estimate: +1,450 ALMs for the CPU, ~+8 M10K net before the VRAM saving.

## Build 13 (2026-09-04 13:20) — Nuked 68000 sub-CPU works; VRAM fix pays off
BIOS boots (sub-CPU: PRG-RAM traffic 1.8M/s, green LED set by the BIOS), Alien 3 runs.
Fit 36,502 ALMs (87%), **519/553 M10K** (VRAM banks now Single Port 256x256, 7 blocks
each; Nuked sub-CPU microcode 14 blocks in M10K), 54,544 registers.
Timing (slow 85C): -1.92ns @107MHz, -2.32ns @53.7MHz. Worst 40 paths (sta_paths.tcl ->
output_files/worst_paths.txt): almost all start at md_board|AS (107MHz register) and end in
ASIC combinational decode (S68K_DO mux, PRG_RAM_ADDR/WRL, WR1R.DO), the md_board VD mux
(through MCD DTACK -> exp_data_en) or the sdram data register (via mcd_cart's write mux),
plus two NukedMD-internal paths (~-1.7ns: m68k w6->w980, _M3 -> ym7101 sr bits).
User reports intermittent audio pops/wobble (build 12): consistent with marginal timing.
Next: register the MCD expansion interface in the 53.69MHz domain (inputs and DTACK/DO
outputs: +37ns round trip, within the measured ~230ns CPU margin; DMA-from-ROM margin to be
verified on hardware), register mcd_cart's address decodes, then seed sweep.

## Build 14 (2026-09-04 14:00) — registered MCD interface; PSG filter paths are false
BIOS and cartridge fine, late=0, maxlat 29 (BIOS) / 19 (cart): the +37ns interface latency
is absorbed. Fit 36,992 ALMs (88%), 519 M10K. Timing: -2.22ns@107 (TNS -967),
-2.47ns@53.7 (TNS -74, down from -338). The gate array paths are gone from the worst list;
the whole 53.7MHz worst-40 is now audio_cond|psg_iir (inp -> iir_tap intreg), which is a
false path: every register in sys/iir_filter.v is written under `if (ce)` (7.056MHz), so
register-to-register paths inside it span >= 7 clocks. Added a multicycle (setup 4 / hold 3)
for psg_iir in MegaCD.sdc. sta_paths.tcl now also writes worst_paths_107.txt /
worst_paths_53.txt per clock. User reports no audible distortion on build 13 (was on 12).

## Build 15 (2026-09-04 14:40) — 53.7 MHz domain clean
BIOS and cartridge verified. 36,965 ALMs, 54,281 regs, 519 M10K. Timing: -2.03ns@107 (TNS
-2153, all ym7101-internal: mclk_and1 -> sl_hit / cnt_sa_low, io_address -> VD),
-0.42ns@53.7 (TNS -0.5: cart ram_wr strobe -> sav_pending, now registered in mcd_cart).
mcd_debug is now behind `MCD_TELEMETRY` (set in the test qsf). Seed sweep started: release
configuration (no telemetry), seeds 2 and 3, in scratchpad copies seed2/ seed3/.

## Seed sweep (release config, no telemetry) and mcd-verificator (2026-09-04 15:20)
Seeds in scratchpad copies: seed 2 = 36,051 ALMs, -1.92ns@107 (TNS -787), +0.31ns@53.7 (met);
seed 3 = 36,060 ALMs, -1.92ns@107 (TNS -391), -0.02ns@53.7. The 107 MHz floor at this density
is the ym7101 clock-gate paths; seed 2 is the release-candidate configuration.
mcd-verificator (krikzz, V1.02, cartridge mode; ROM in games/MegaCD/mcd-verificator.bin,
MGL _Console/MegaCD_verificator.mgl) results, expected ranges from jgenesis issue 105:
  b12 (NukedMD main + FX68K sub): IRQ TEST OK, REG 8030 OK, VAR 22381 err02, COLOR CALC err05,
      CDC REGS err01, hangs at CDC INIT (upstream core: IRQ 223 err09, 8030 1299 err07 - NukedMD
      fixed those two).
  b13/b14/b15 (Nuked sub-CPU): IRQ err0A / 125 err06 / 121 err06 (expected 224-226),
      REG 8030 1285 err07 (expected 1286-1288), VAR 25808.  -> regression from the sub-CPU
      wrapper, not from the interface registers.
A/B bench (scratchpad sim_sub: same program, memory, enables on the FX68K wrapper and the
Nuked wrapper) showed identical bus cycle (298ns) and loop timing, but the Nuked core's bus
events sat one 53 MHz clock later relative to the enables: the wrapper rebuilt the CPU clock
through a register (high one CLK after CE_R) while FX68K acts in the CE_R cycle itself.
Fix: ASIC exports S68K_CLK = '1' when CLK_CNT is "11" or "00" (level from the phase counter),
MCD routes it to M68K_WRAP.CLK_LEVEL; bench now shows an integer 3-clock offset (reset
sequence) only. Build 16 tests it on hardware. Remaining known Mega CD-side inaccuracies
(from jgenesis' verificator work): CDC decoder interrupt must run at 75Hz with DECEN even
without sectors (why CDC INIT hangs), transfer-end interrupt when one word is left, FF for
invalid register reads, no stacking of unacknowledged DECI/DTEI, odd-length DMA rules,
word RAM 2M-mode sub-CPU halt, COLOR CALC error 05. Main: minimum seek latency (GPGX uses
12 frames; Thunder Storm FX).

## Build 16 (2026-09-04 16:05) — clock-level fix alone changes nothing on the verificator
IRQ 121 err06, REG 8030 1285 err07, VAR 25808 err02: identical to build 15. The bench (sim_sub)
with an enable-timed DTACK model and periodic HALT pulses shows FX68K and Nuked wrappers cycle-
identical, so the difference is in the real gate array timing.
Root cause found in the Mega CD side: MCD.ENABLE was tied to 1 (original core too), so the gate
array's CLK_CNT steps every 53.69 MHz clock and the sub-CPU, PCM chip and CDC run at 13.42 MHz
instead of 12.5 MHz (+7.4%). srg320 compensated only the interrupt timer divider (412 instead
of 384 -> 30.7us tick). That is why the verificator's VAR test was -4.7% upstream / -6% with
FX68K and +8% with the die-accurate CPU: neither CPU can be right on a fast clock.
Build 17: CEGen 53693175 -> 50000000 drives MCD.ENABLE (12.5 MHz exact on average), timer
divider back to 384, plus the CDC 75 Hz decoder frame (DECI with DECEN+SYIEN, release at
40%, DECI=1 when DECEN=0, resync on sector end) from the verificator/jgenesis findings.
Expected audible side effect: PCM (RF5C164) pitch was 7.4% sharp before; now correct.

## Build 17 (2026-09-04 16:50) — 12.5 MHz: REG 8030 passes; PRG-RAM wait states now visible
Verificator: REG 8030 OK (timer vs sub-CPU correct at 12.5 MHz), IRQ 106/128 err06, VAR 27906
err02 (expected 23753-23980), CDC INIT still hangs, BIOS boots. With the die-accurate CPU on
the right clock, the sub-CPU's memory path is ~17% slower than real hardware: SDRAM-backed
PRG-RAM (and word RAM through the ASIC state machines) return DTACK 2-3 CPU clocks after /AS,
where real DRAM gives ~1 wait state. FX68K hid this by accepting a late DTACK in the same
cycle. Next: MCD-level bench (real ASIC + sdram + Nuked CPU) to count clocks per access type,
then shorten the PRG-RAM/word RAM acknowledge path (speculative SDRAM read on address valid).
37,309 ALMs (89%).

## Sub-CPU DTACK window (2026-09-04 17:30) — the one-clock skew
sim_sub DTACK sweep (DTACK k CLKs after /AS -> loop length): FX68K 0-wait up to k=3, then +1
wait every 4 CLK (4/8/12). Nuked with registered outputs: 3/7/11 (window closes one CLK
early -> one extra wait on every late DTACK: PRG-RAM through SDRAM, word RAM state machine).
Nuked with direct outputs and the phase-counter clock: 4/8/12, identical to FX68K. Build 13
had direct outputs but the late clock (same net skew), so no build so far was skew-free.
Build 18: MC68K.vhd outputs direct again. The 53.7 MHz paths sub-CPU -> PCM decode (-1.77 ns
in build 14) will return; fix them on the PCM side if needed (input registers in PCM.vhd are
harmless: PCM accesses are HALT-throttled by the gate array).
CDC INIT in the verificator starts with a TOC read from the drive (cddInitToc) and times
out without a disc: not a core defect, needs a CD image mounted.

## Build 18 (2026-09-04 17:35) — direct sub-CPU outputs
Verificator: IRQ 122/128 err06 (was 106), VAR 26742 err02 (was 27906; expected 23753-23980),
REG 8030 OK, BIOS boots. Timing -2.37@107 (TNS -918), -0.91@53.7 (TNS -11). 37,082 ALMs.
Remaining ~12% sub-CPU slowness is in the memory path; build 19 adds sub-CPU bus-cycle
latency statistics per region (MCD debug ports -> mcd_debug) to measure it on hardware.

## Build 19 telemetry (2026-09-04 18:30) — sub-CPU bus latency on hardware
AS->DTACK: PRG-RAM avg 99-105 ns (min 93, max 280-335), word RAM 27 ns during the VAR loop
(99 ns while the BIOS idles), registers 20-30 ns. The 68000 samples DTACK ~100 ns after /AS
(S4 falling edge minus setup), so PRG-RAM sits on the 0/1-wait boundary: the die-accurate CPU
takes a wait state on nearly every PRG-RAM fetch, FX68K did not, and the verificator's
expected count corresponds to ~0 wait states (18.7 clocks per 4-access loop iteration).
Build 20: ASIC asserts the sub-CPU PRG-RAM read DTACK when the SDRAM controller accepts the
request (PRG_RDY falls) instead of when the data is back; data then arrives deterministically
~60 ns later, inside the 80 ns the CPU waits between sampling DTACK and latching data.

## Build 20 (2026-09-04 18:50) — VAR TESTS pass
Verificator: VAR OK (was 26742 err02), REG 8030 OK, IRQ err0A (sub-tests 06/08/09 now pass:
128/128 handled, 1024 requests with 224-226 timer ticks; 0A wants INT2 answered within ~6
NOPs of the main CPU incl. exception stacking), BIOS boots. Telemetry: PRG-RAM AS->DTACK avg
44-55 ns (was 99-105), word RAM 25 ns in the loop / 100 ns idle, regs 24-30 ns.
Next (build 21): post PRG-RAM writes (DTACK at issue) - the stack pushes of the exception
entry are the remaining wait states in the 0A window.

## Build 21 (2026-09-04 19:30) — posted writes broke the BIOS (reverted on the MiSTer to build 20)
Posted PRG-RAM write DTACK was released only in PRS_END, which a posted write does not reach
before the CPU's next cycle: DTACK stayed low into the next access (telemetry min AS->DTACK
0 ns), that cycle ended at once with stale data -> corrupted BIOS screen, then a crash.
Build 22: DTACK release on strobe negation in every state; PRS_END -> IDLE when released.

## Build 22 (2026-09-05 10:40) — boots, but the read-after-write hazard remains
BIOS runs, verificator as build 20 (VAR OK, IRQ 0A). Telemetry still shows PRG-RAM min
AS->DTACK 0 ns: after a write is accepted the PRS machine returns to IDLE before the SDRAM
write completes, so the next read is issued while the port is still busy, PRS_WAIT takes the
residual PRG_RDY=0 as "read accepted", acknowledges early and captures the write's completion
as read data. Build 23: a new PRG-RAM request (sub-CPU or DMA) is issued only when PRG_RDY=1.
Note: the flow now writes output_files/MegaCD_TEST_NukedMD_20260904_<build>.rbf (build_id.tcl
naming), not MegaCD.rbf - the first "build 22" deploy silently re-sent build 20.

## Build 24 (2026-09-05 11:20) — ENABLE gating regression (scratchy NTSC audio) fixed at the source
Users and the owner heard scratchy audio in NTSC since build 18 (PAL fine). Cause: build 17 fed
the 50 MHz CEGen into MCD.ENABLE, so every process gated by ENABLE skips one clock in 14.5;
the CDDA and PCM sample enables (their own CEGens on CLK) and the CD sector data strobes from
the HPS are single-clock pulses and were dropped ~7% of the time (CDDA/PCM samples, sector
words). Fix: ENABLE back to 1 (as upstream) and a new EN50 port that only steps the gate
array's CLK_CNT (sub-CPU 12.5 MHz clock, CE_F/CE_R for timer, CDC and PCM register timing).
Build 23 (idle-port guard only) was aborted; build 24 carries the guard and this fix.

## Build 24 (2026-09-05 11:25) — on the MiSTer; NTSC audio fix candidate
BIOS renders correctly; verificator = build 20 (VAR OK, REG 8030 OK, IRQ err0A, CDC REGS 01).
37,580 ALMs (90%). Telemetry: PRG-RAM AS->DTACK avg 50 ns, max 224 ns; the per-region minimum
still reads 0 ns since posted writes (build 21) - a single-event statistic, cause not yet
identified (no visible effect; build 20 read 37 ns). Open: add an "early DTACK" counter to the
telemetry to see whether it is rare or systematic. Next accuracy item: IRQ sub-test 0A (INT2
answered within ~6 main-CPU NOPs including exception entry); COLOR CALC 05.

## Build 25 (2026-09-05 12:00) — timing: reset multicycle, cartridge mapper inputs registered
Build 24 timing -3.95@107 / -1.61@53.7: worst paths md_reset -> VD mux / ram_68k / mcd_cart
(static in play) and VDP io_address -> mcd_cart mapper registers (107 -> 53 MHz combinational).
SDC: md_reset / sys_reset multicycle setup 3 / hold 2. mcd_cart.sv: the clk_sys mapper, EEPROM
and protection blocks work from clk_sys-registered copies of the bus inputs and reset
(cart_addr_s etc.); the 107 MHz data-response path is unchanged.

## Build 25 (2026-09-05 12:40) — timing changes; not deployed
37,676 ALMs, -2.97@107 (VDP io_address -> ram_68k address), -0.74@53.7 (VDP DMA control ->
mcd_lds_n/mcd_sel_n interface registers: dma_rd = cart_dma & cart_oe, and cart_oe is
combinational deep inside the VDP). The reset multicycle removed the md_reset paths.
NTSC investigation: forcing the OSD region with a mismatching BIOS makes every BIOS halt at
0x7E0 by design (A10001 region-bit check, error message). A US image mounted from the share
(Main loads usa/cd_bios.rom) boots in NTSC on build 24 (3 Ninjas Kick Back title screen).
The user hears PCM-only warble in NTSC (PAL fine) since ~build 18. Build 26 adds PCM
telemetry: sample-enable rate, CE_F rate, PCM write strobes raw vs. as sampled by the chip
on CE_F, and late SDRAM sample fetches.

## Build 26 (2026-09-05 13:36) — PCM telemetry lands, but reads zero
Deployed (md5 5e941107); Final Fight CD (USA) boots in NTSC. The sub-CPU statistics count
normally, but record words 18-20 (sample_ce, ce_f, writes, seen_by_chip, late_fetch) read 0,
before and after a core reload. Checked: the rbf on the card is build 26; the fitted netlist
(quartus_sta get_fanins) has sp_ce/sp_late/sp_we/sp_cef fed by PCM CEGen CE, pcm_mem late, the
sub-CPU strobes + PCM_DMA_WR and ASIC CLK_CNT/EN50, and the counters feed DDRAM_DIN. The
record is one 40-beat burst at a fixed address (DDRAM_ADDR[0..21] constant). Open question:
are words 18-23 written at all (planting a marker from Linux was not possible: the MiSTer
went offline). Build 27 answers it by design (word 21 = {seq, FEEDC0DE}, word 22 = live
synchronizer bits, word 23 = 107 MHz clocks with pcm_smp_ce high).

## Build 27 (2026-09-05 16:25) — "Disc Insert: Keep Running" test aid + telemetry freshness
OSD: "Disc Insert: Reset / Keep Running" (status[36]). Main re-sends cd_bios.rom and pulses
status[0] on every image mount; with Keep Running on and a BIOS already loaded, the BIOS
download is ignored (bios_download masked, so no reset, no SDRAM write, no rom_cart_mode
clear, region unchanged) and status[0] is ignored (host_reset). The OSD "Reset & Eject CD" is
masked too while it is on (main menu Reset still works). Purpose: run the verificator's CDC
tests (CDC INIT needs a mounted disc) and swap discs without restarting the core, as on
hardware where the BIOS sees the new disc through the CDD status.
PCM path review while waiting for hardware: PCM.vhd needs each channel's sample from RAM
within one 520.8 kHz slot (address changes every second SAMPLE_CE, loop-marker check after
one slot, sample used after two); pcm_mem.sv fetches from SDRAM port 3 (lowest priority but
the other ports issue one 7-clock access at a time, so starvation looks unlikely); the gate
array's CDC->PCM DMA writes one byte per ~6 sub-CPU clocks without checking PCM_RDY (a write
into a full 8-entry FIFO is dropped, needs >4 us of SDRAM starvation). The late_fetch counter
(build 26/27) decides whether the SDRAM path is the NTSC PCM warble.

## Thunder Storm FX (2026-09-05 16:45) — Main-side patch written, untested
tools/main_patches/megacdd_seek_latency.patch: cdd_t::SeekToLBA adopts the Genesis Plus GX
drive latency rule for the MegaCD core (Play and Seek at least 12 CDD interrupts unless a
latency is still running, plus the distance term; Main had Play 11 / Seek 0). Needs a Main
build (no ARM toolchain here); test with MegaCD_tsfx_jp.mgl, then Final Fight CD intro,
Sonic CD track 26, Radical Rex.

## CD system audit against jgenesis issue 105 (2026-09-05 16:55) — to verify with a disc on build 27
jsgroth's list of behaviours needed to pass the verificator's CDC / DMA / word RAM tests,
checked against CDC.vhd and ASIC.vhd:
- Already matching: sub-CPU access to 2M word RAM owned by the main CPU is not acknowledged
  until RET0=0 (word RAM 20: the sub-CPU stalls in the bus cycle); DMA to word RAM waits the
  same way (DMA3 44); DMA to PRG-RAM waits while SBRQ/SRES (DMA3 48); odd DMA length drops
  the last byte for PRG/word RAM and not for PCM RAM (DMA2 04/12); the other CPU's host-data
  read returns HD without advancing the DMA (DMA3 28); FF800A readable (FLAGS 46); DECI flag
  independent of DECIEN (FLAGS 44); INT5 is edge-detected from the CDC's level /INT, so a
  second event while the first is unacknowledged does not re-trigger (FLAGS 26/34/36); the
  75 Hz decoder frame and the 40% release are in since build 17 (FLAGS 30/40).
- Candidates (fail on hardware if jsgroth is right, all cheap to fix):
  1. CDC register reads of R0 (COMIN) and undefined registers keep the previous DO; hardware
     returns FF (FLAGS 32). CDC.vhd read mux: DO <= x"FF" for x"0" and others.
  2. DTEI (and the gate array's EDT) are raised after the host reads the last word (TS_SEND,
     DBC=0); hardware raises them when the last word is moved into the host data register,
     i.e. with one word left to read (FLAGS 22, DMA3 04). Move the DBC=0 end handling to the
     point where the last word is loaded (TS_FIFO), keep DTEN/DTBSY semantics.
  3. A write to the host data register (FF8008 / A12008) should advance the DMA like a read
     (DMA3 60); the ASIC treats FF8008 writes as null.
  4. Changing DD mid-transfer resets the DMA address only; the ASIC also forces DS to IDLE
     through DMA_ADDR_SET (DMA3 50) and would drop a byte in flight.
Run order once the board is back: MegaCD_verificator.mgl with a disc mounted through the
OSD (Keep Running), read CDC INIT / FLAGS / DMA1-3 / WORD RAM results, then fix in the order
the tests fail (each test stops at its first error).

## 2026-09-05 17:20 — the "build 26 zero PCM counters" were build 22 running
A marker test (writing markers into DDR3 words 18-23 from Linux) showed the core rewrites them
every burst, so the counters really were zero. Cause: two files in /media/fat/_Console shared
the prefix `MegaCD_TEST_NukedMD_20260904` (`.rbf` = the deployed build, `_22.rbf` = build 22
copied on 2026-09-04 20:15). Main resolves an MGL `<rbf>` by prefix and takes the last match
in sort order, so every MGL load since then ran build 22 (posted writes, BIOS corruption).
The `_22` file is renamed to `MegaCD_TEST_b22_20260904.rbf`. The BIOS hangs reported on
"builds 24-26" via MGL, and the earlier PRG-RAM "min 0 ns", need re-checking on the real
builds; the owner's OSD-menu loads may have hit the `_22` file as well.
Real build 26, Final Fight CD (USA), NTSC, 3.0 s window: sample_ce 520,741 Hz (expected
520,832), ce_f 12.498 MHz, PCM writes 180 all seen by the chip, late_fetch 0. The PCM clocking
is right; the warble scene still has to be measured (Final Fight's title uses little PCM).

## Build 27 (2026-09-05 17:12) — fits, but the placement is poor: -6.15 ns @107, -4.29 @53.7
37,540 ALMs. Worst paths: md_board RW -> ram_68k write enable, VDP w129 -> md_board VD[5],
RW / VDP DMA control -> mcd_sel_n/mcd_uds_n (same families as builds 24-26, 3 ns worse).
Not deployed. Seeds 2 and 3 of the same sources plus the INT2 telemetry (build 28 content)
are compiling in the scratchpad seed2/ seed3/ copies.

## Build 28 (2026-09-05 18:00) — seed 2 of the build 27 sources + INT2 telemetry; deployed
Seeds of the same netlist: seed 1 (build 27) -6.15 @107 / -4.29 @53.7; seed 2 -1.84 @107
(TNS -1024) / -0.32 @53.7, 37,543 ALMs; seed 3 -2.65 / -0.77. Seed 2 is on the card as
MegaCD_TEST_NukedMD_20260904.rbf (md5 cf43dbbd) = build 28: Disc Insert Keep Running,
telemetry freshness words (word 21 tag verified fresh on hardware), INT2 latency words.
JP BIOS (blank disc, JP region, 60 Hz) on build 28: PCM sample_ce 520.8 kHz, ce_f 12.5 MHz,
writes all seen, late_fetch 0, as on build 26. The seed spread (4.3 ns between seeds on the
same netlist) means every future build needs a multi-seed fit before deploy.

## 2026-09-05 18:20 — NTSC pops/warble and BIOS hangs: root cause and fix (build 30 compiling)
Owner's observation: build 28 (a better fit of the same netlist) sounded better than 26 but
with small pops, then the JP BIOS hung with both CPUs alive (main CPU in `tst.b $FFFE26 /
bne` waiting for its VBlank handler's clear, which never read back as 0). The behaviour is
fit dependent and NTSC only (clocks 1% faster than PAL), i.e. marginal timing, and it dates
from build 18, which made the Nuked sub-CPU's bus outputs (address, data, /AS, /UDS, /LDS,
R/W, FC) drive the gate array combinationally from the 107 MHz model clock into the 53.7 MHz
domain. Fix (MC68K.vhd): register those outputs at MCLK. This adds 9.3 ns, lands in the same
gate array CE_F sample as before, and the bench shows the fetch loop period unchanged and
identical to FX68K (1340928 ps), interrupt timings within 10 ns. Also made region-proper:
the 50 MHz CEGen takes the real clock (PAL 53.203 MHz) so the sub-CPU is 12.5 MHz in PAL
too (was 12.386), and the CDC 75 Hz decoder frame timer takes the PAL clock (was 74.3 Hz).
The remaining fit-dependent paths are in the main-side glue (md_board RW -> ram_68k write
enable, VDP DMA control -> mcd_sel_n/mcd_uds_n) and are the next timing target.
Build 29 (main tree, compiling) = PCM output capture on the OLD wrapper, kept as a baseline;
build 30 = seeds 2 and 3 of the fixed sources (scratchpad seed2/ seed3/).

## Build 30 (2026-09-05 19:02) — sub-CPU outputs registered at MCLK, region-proper clocks; deployed
Seed 2: 37,653 ALMs, -1.91 @107 (TNS -703), **+0.13 @53.7** (the 53.7 MHz domain is clean for
the first time since build 15; the sub-CPU -> gate array paths were in it). Seed 3: -2.45 /
-0.43. Seed 2 is on the card (md5 7658026f). Build 29 (old wrapper + PCM capture ring,
md5 afaf57dc) served as the baseline: on the JP BIOS with no disc it played music (captured
0.25 s, clean waveform) and went silent about a minute later with the main CPU in the VBlank
wait loop at 0x8E4 and the sub-CPU polling registers. On build 30 the same no-disc JP BIOS
shows the silent state from ~45 s on, so the silence may be the BIOS's normal behaviour
rather than a hang; needs the owner's screen/ear confirmation. The capture ring delivers the
full 32,552 samples/s (pointer wraps every 0.25 s).
Board state: /media/fat/cifs/MegaCD/boot.rom is the JP BIOS for these tests (EU original in
boot.rom.eu_backup) - RESTORE when done.

## Build 30 verificator (2026-09-05 19:25) — registered outputs are clean; PAL ratio question open
NTSC (region forced US in MegaCD.CFG byte 0 = 0x88): VAR OK, REG 8030 OK, IRQ err 0A, CDC
REGS 01, COLOR CALC 05 = identical to builds 20-28. So the MCLK-registered sub-CPU outputs
cost nothing measurable, and the PRG-RAM "min 0 ns" anomaly is gone (min 27.9 ns).
PAL (cart header region): VAR 23609 (23753-23980), IRQ 228 (224-226), REG 8030 1275
(1286-1288): all 0.9% off with the exact 12.5 MHz sub clock in PAL. The verificator's windows
are NTSC-ratio windows; what real 50 Hz hardware does decides the model:
- variant A (scratchpad seed2/, SEED 2): mcd_cegen IN_CLK fixed 53693175 and CDC frame fixed,
  i.e. the sub-CPU scales with the console clock (12.386 MHz in PAL) as in builds 17-29;
- variant B (scratchpad seed3/, SEED 2): IN_CLK by region (12.5 MHz in PAL) and the CDC frame
  by PALSW, i.e. a region-independent Mega CD crystal.
Both include the work RAM write register stage (build 31). CORRECTION: there is no real-hardware run to lean on (misattribution). Decided by the documented
clock source and by Genesis Plus GX / jgenesis, which both model a fixed 50 MHz CD clock: variant B.
Board state: MegaCD.CFG byte0 0x88 (region forced US) and byte4 0x10 (Keep Running) set;
/media/fat/cifs/MegaCD/boot.rom is still the JP BIOS (EU original in boot.rom.eu_backup).

## 2026-09-05 19:45 — the sub-CPU clock is the Mega CD's own (documented)
RetroTechCollection, "Sega CD (Model 1)": the 12.5 MHz sub-CPU clock (25 MHz / 2) is generated
on the Sega CD board and supplied to the console on expansion connector pin B25 "CDCLK 12.5 MHz
clock from Sega CD"; the console supplies "EXCLK 7.67 MHz clock from Genesis" on B26. So the
sub-CPU, its timer, the PCM sample clock and the CDC run at the same speed in a 50 Hz machine
as in a 60 Hz one, and only the console side slows down by 0.9% in PAL: variant B is the
hardware-true model. Consequence for the verificator: its VAR / IRQ 09 / REG 8030 windows
encode the 60 Hz console-to-Mega CD ratio, so a real 50 Hz console fails them by 0.9% too
(CORRECTION: nobody here ran the verificator on real hardware; the "real model 2" claim in these notes was a misattribution).

## 2026-09-05 19:50 — decision: variant B (fixed 50 MHz Mega CD clock) is the model
Evidence: expansion connector pin B25 CDCLK 12.5 MHz is driven by the Mega CD (RetroTech
Collection); Genesis Plus GX core/cd_hw/scd.h: `#define SCD_CLOCK 50000000` with ~3184 SCD
clocks per line on NTSC and ~3214 on PAL; jgenesis backend/segacd-core/src/api.rs:
`SEGA_CD_MASTER_CLOCK_RATE = 50_000_000`, Sega CD cycles derived against the NTSC or PAL
Genesis master clock. The repo now carries this (mcd_cegen IN_CLK by region, CDC frame by
PALSW). Verificator consequence: VAR / IRQ 09 / REG 8030 are 60 Hz-ratio windows; in a 50 Hz
console (real or emulated) they read 0.9% off. Build 31 = this + registered sub-CPU outputs
+ work RAM write stage, compiling as seeds 2 and 3 (scratchpad seed3/ and seed2/).

## 2026-09-05 19:55 — reference material (jgenesis / GPGX / upstream) and what it settles
- Stock MegaCD_MiSTer (issue 50, screenshot 2025-06-21, run as CD boot ROM): COLOR CALC 05,
  VAR 22744 err 02, IRQ 223 err 09, REG 8030 1299 err 07, CDC REGS 01, hangs at CDC INIT.
  This core (build 30, NTSC): VAR OK, IRQ err 0A, REG 8030 OK - ahead of upstream on timing.
- GPGX issue 408: a European Model 1 Mega CD run showed the timing errors ("only NTSC seems to
  have been tested on krikzz's end") - real 50 Hz hardware fails VAR/IRQ/REG 8030 windows, so
  variant B (fixed 50 MHz CD clock) is confirmed by hardware, not just by emulators.
- CDC REGS: passes only on CDX/Multi-Mega/X'Eye/Wondermega M2 (LC8913 CDC, 5-bit address
  register); confirmed by the BlastEm author on most models. Not a defect of this core.
- ekeeke fixed every verificator test in GPGX with one commit each (issue 408): the roadmap.
  First one applied here: COLOR CALC 05 = FF804C font colour byte write at the even address
  must not be ignored (/LDS,/UDS irrelevant; GPGX 58accf0). ASIC.vhd FF804C write ungated.
  Remaining from that list: CDC INIT 04, CDC DMA3 02/04/13/20/21/42-56/60-63, CDC FLAGS
  22/26/27/30/40-42/46, REG X002 03/29/2B, REG 2006 02/03/05 (as CD boot ROM), WORD RAM 20.
- jgenesis 178 (Thunder Storm FX) and 100 (Radical Rex): drive-side behaviours, see
  tools/main_patches/README.md.
- SpritesMind t=3166 (Mask of Destiny, BlastEm): on a Sega CD 2 (LC89515) and a Wondermega M1
  (LC8951) the verificator fails CDC REGS 01 and CDC FLAGS 40 (error value 25); only the CDX /
  Multi-Mega / X'Eye / Wondermega M2 CDC (LC8913/LC89513, 5-bit address register) passes them.
  This is the origin of the earlier "model 2 fails CDC REGS 01 / CDC FLAGS 40" note (not an
  owner measurement). The core models the Model 1/2 CDC, so CDC REGS 01 is correct behaviour.

## Build 31 (2026-09-05 20:31) — deployed; Keep Running (as built) breaks the BIOS boot
Seed 2: 37,843 ALMs, -2.03 @107 (TNS -360, was -703), +0.23 @53.7; seed 3: -2.19 / -0.68.
Remaining 107 MHz failures all end at the board's VD bus register fed by the VDP address decode
(AS, _M3, io_address, w100/w124/w45 -> VD[12]): the chipset's own bus mux at 90% fill.
NTSC verificator: VAR OK, REG 8030 OK, IRQ 0A, COLOR CALC 05, CDC REGS 01 (as build 30).
JP BIOS, no disc: with Keep Running ON (CFG byte4 0x10) the BIOS stays on the intro clouds,
main CPU polling A1200E - Main's start-up reset pulse / second BIOS send were masked and the
BIOS never restarts after the drive is initialised. Builds 30/31 "silent" runs were this, not
a wrapper regression. With Keep Running OFF the JP BIOS boots to its menu with music on build
31: 3 s captured (12 windows), no single-sample spike above 3000 in the chip output, 28 above
2000 clustered in a 4 ms burst (likely programme material). Fix committed: the masking arms
3 s after the first BIOS load (build 32). The CFG bit is now OFF on the card.

## 2026-09-05 21:05 — the BIOS hang: what is known
Signature (build 31, JP BIOS menu, ~10 min in; and within seconds after OSD Reset & Eject):
screen normal, main CPU cycling its VBlank frame loop (0x8E4) with the handler running, sub-CPU
spinning on one gate array register at ~89k reads/s, PCM output silent, VDP 59.9 Hz, Main's
process alive and consuming CPU. Reset & Eject recovers it. This did NOT happen on the original
core: the regression is in this port (sub-CPU model/clock/bus changes), not in Main.
Protocol facts (Eke, SpritesMind t=3020): the gate array asserts HOCK to receive the 75 Hz
status, INT4 fires after the 8th status nibble, the command is transferred after the status,
and the drive stops sending statuses if the gate array stops sending commands - so Main's
one-status-per-command exchange is faithful. The ASIC diff against the original tree (55
lines) touches CLK_CNT/EN50, the timer divider, PRG-RAM DTACK, PCM_RDY and FF804C only; the
CDD/INT4/IACK logic is the original's. hps_ext.v counts request toggles (Main cannot miss one).
Next: build 33 telemetry (last sub register address, CDD command/status counters) read in the
hung state right after a Reset & Eject.

## Build 32 (2026-09-05 21:30) — font colour fix + Keep Running arming; not deployed (33 supersedes)
37,846 ALMs, -1.85 @107 (TNS -549), -0.41 @53.7 (seed 2). The same sources with
PLACEMENT_EFFORT_MULTIPLIER 4.0 and ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM produced a
bit-identical rbf (md5 7f6ea523): with OPTIMIZATION_MODE "AGGRESSIVE PERFORMANCE" and physical
synthesis already on, the fitter has no further effort setting to give; the remaining 107 MHz
paths (VDP address decode -> VD bus register) need a logic change or lower utilisation.

## Build 33 (2026-09-05 21:40) — deployed: hang telemetry
37,698 ALMs, -1.84 @107 (TNS -370), -0.09 @53.7. Baseline, JP BIOS menu with music (no
disc): CDD commands 75/s, statuses 75/s, statuses = commands + 6 since start; sub-CPU's last
gate array/PCM address FF0010 / FF8034. Waiting for the owner's Reset & Eject to catch the
hang and read the same words.

## Release-shape fit (2026-09-05 22:20) — build 33 sources without telemetry
36,196 ALMs (86%), -1.77 @107 (TNS -483), +0.25 @53.7, seed 2 (scratchpad
rc_notelemetry_seed2.rbf, md5 01c33bb9). Dropping the 1,500 ALMs of telemetry buys ~0.1 ns:
the 107 MHz failures (VDP address decode -> md_board VD register, -1.8 to -2.0 ns in every
fit) are structural. Options left: (a) a logic change to that bus mux in md_board.v (the one
nuked-md file already modified for the expansion connector; the expansion data term added a
sixth source to the 16-bit VD OR-mux and could be folded into the cartridge term from
MegaCD.sv) - needs the owner's OK since it is nuked-md; (b) accept, as the MegaDrive core
does (the same VDP paths fail there by ~2 ns at the slow corner).

## 2026-09-05 22:30 — hang on build 33, second look
Screen: JP BIOS menu with the MEGA CD logo half drawn. Main CPU: only A1200E reads, data
0107 (main flag 01, sub flag 07): waiting for the sub-CPU to finish logo step 7. Sub-CPU:
PRG-RAM 2.8M/s (running code), word RAM 0/s, registers ~1.1k/s, PCM writes 63/s, CDD
exchange alive at 75/s. Last-register histogram: FFFFF6 (563), FF0010 (524), FF8000 (375),
FF8036 (20), FF8034 (9), FFFFF8 (9). FFFFF6/FFFFF8 are interrupt-acknowledge cycles (FC=111,
A3..1 = level 3 / level 4): the timer interrupt (INT3, music engine polling PCM channel
addresses at FF0010) keeps firing, INT4 (CDD) at 75 Hz, so the sub-CPU is not crashed; its
main program spins without touching word RAM. The timer/INT3 logic is the original core's.
Build 34 (compiling) records the sub-CPU's last 32 bus addresses to locate that loop.
The state arrived on its own about two minutes after boot on build 33 (no Reset & Eject in
the counters).

## 2026-09-05 22:35 — PRG-RAM acknowledge audit: a real hazard, fixed (build 35)
Independent audit of the sub-CPU PRG-RAM machine (ASIC.vhd PRSS): PRS_WRITE re-asserted
S68K_PRGRAM_DTACK_N after the posted acknowledge had already been given in PRS_IDLE and
released on strobe negation. When the SDRAM accepted the write late (refresh + other ports,
up to ~300 ns) the CPU was already in its next bus cycle, which that DTACK terminated with
S68K_PRGRAM_DO (the previous read's data) whatever its target (a PRG-RAM read never issued,
word RAM, PCM, BRAM): random corruption a few times a minute, and the "0 ns AS->DTACK
minimum" in the telemetry since build 21. Fix: PRS_WRITE no longer asserts DTACK. The audit
found no hazard in the read-at-acceptance path (>= 28 ns margin), byte strobes or DMA
ordering. Pre-existing (original core) issues noted, untouched: a DMA write below the write
protect boundary leaves PR_DMA_RUN set (DMA engine stuck); the main-CPU PRG-RAM machine
shares PRG_RAM_* with the sub-CPU one without a PRG_RDY gate (race within ~0.3 us of SBRQ).
Also in build 35: wave RAM reads acknowledged only after the SDRAM read completed; the
sub-CPU address ring; font colour fix; Keep Running arming.

## 2026-09-05 22:55 — hang root cause confirmed by the address ring (build 34)
JP BIOS menu program (Kosinski block at ROM 0x13000, 11,314 bytes, loaded at PRG-RAM 0x6000):
sub-CPU loop 60BE: bsr 61C8 (btst #7,($800E).w = main CPU command bit) / beq 60EE (idle:
move.w 8C32,d0; jsr 60FC(pc,d0.w) = rts; bra 60BE). Every ring entry matches (stack at 5E78:
bsr push / rts pop). The sub-CPU is in its normal wait-for-command loop while the main CPU
(10EC-10F2, A1200E reads, data 0107) waits for the sub's answer with its command bit clear:
a lost handshake step. Mechanism = the audited PRS_WRITE late DTACK: a posted stack write
(bsr) immediately followed by the register read (btst FF800E) is exactly the sequence in
which a late SDRAM acceptance made the write state's second DTACK terminate the register read
with stale PRG-RAM data; a spurious bit 7 runs the command handler with no command pending
and desynchronises the protocol. Kernel: Kosinski block at 0x16000 -> PRG-RAM 0 (21,466
bytes). Tools: scratchpad/m68kdis.py (also /tmp/m68kdis.py on the MiSTer), /tmp/kos.py.
Build 35 (fix) compiling as seeds 2 and 3.

## Build 35 (2026-09-05 23:15) — deployed: hang fix + wave RAM read fix + font colour + Keep Running arming
Seed 3: 37,547 ALMs, -1.87 @107 (TNS -586), -0.24 @53.7 (md5 e7f75363, on the card). Seed 2:
-2.07 / -0.43. Soak running: JP BIOS, no disc, monitor every 20 s (CDD counters, PCM ring,
word RAM and register rates, PRG-RAM minimum acknowledge, main CPU address) for 13 minutes.
Expected if the fix is right: music stays on, PRG-RAM minimum acknowledge never 0 ns, no
handshake loss. Then: verificator NTSC (COLOR CALC expected OK), Keep Running + disc.

## Conversion step 1 done: tmss (2026-09-05 23:30)
rtl/nuked-md/tmss_rtl.v = tmss 1:1 (same ports, same assigns, ym_slatch -> `if (en) mem <= inp`,
ym_sdffr/ym_sdffs kept as two registers because their clocks are bus-decode nets, not phases).
Bench sim/tmss (tb_tmss.sv, compile.sh, run.sh; ModelSim): die model and tmss_rtl side by side,
all 11 outputs and 8 storage registers compared twice per MCLK edge; seeds 1 and 7: 510,040 and
610,032 compare points, 0 mismatches; two mutants caught (cycle 1 and cycle 1498). Not yet wired
into the build (fc1004.v still instantiates `tmss`); switching is a one-line change behind a
define once the arbiter and I/O are converted too, per the plan.

## Build 35 verificator (2026-09-05 23:40) and CDC INIT root cause
NTSC (US forced): COLOR CALC OK (first time), VAR OK, REG 8030 OK, IRQ 0A, CDC REGS 01.
PAL (cart region): COLOR CALC OK, VAR 23608 (02), IRQ 227 (09), REG 8030 1275 (07), CDC
REGS 01. IRQ 09 and VAR are the 60 Hz windows (hardware-true at 50 Hz); REG 8030 in PAL is
OUR inaccuracy: PRG-RAM in SDRAM whose clock follows the console, so in PAL more accesses take
a wait state; real PRG-RAM has none in either region -> next: acknowledge/read on address valid.
Disc mounted 6 s after the cartridge under Keep Running: mount works (12 statuses), but the
verificator issued 0 CDD commands: its cddInit sets HOCK then only polls the status until it
leaves 0xF; the core hands commands to Main only on an FF804A write and Main answers one status
per command, so the last status (0xF, mount latency) never refreshed. Upstream has the same
limitation (issue 50 "hangs on cdc init"). Hardware: the gate array retransmits its command
registers every 75 Hz frame while HOCK is set. Implemented (build 36): CDD_SEND on HOCK rising
and once per 166,667 ticks of the 12.5 MHz enable unless software wrote a command.
"CD hardware detected at 0x00400000" = cartridge mode (Mode 1); upstream's screenshot shows
0x00000000 because it ran the verificator as the CD boot ROM.

## 2026-09-06 morning — status after the overnight run
- **Composite video**: a rogue agent left uncommitted "composite video" edits (cvbs_sim.sv,
  composite_video.md, tools/cvbs, and edits to MegaCD.sv/video_cond.sv/files.qip/README/HANDOFF).
  None was ever committed (`git log -S cvbs` = base commit only, i.e. stock sys/yc_out.sv). The
  faux files are gone from the tree. "Composite Blend" (MegaCD.sv) and sys/yc_out.sv are STOCK
  MiSTer, kept. Nothing of ours was lost.
- **Conversion steps 1-3 pushed**: tmss_rtl.v, ym6046_rtl.v (I/O), ym6045_rtl.v (arbiter), each
  1:1 with an A/B ModelSim bench in sim/ (all outputs + every storage bit compared twice/MCLK,
  0 mismatches over millions of cycles, mutants caught). fc1004.v selects them under the
  `NUKED_RTL_STAGE1` Verilog macro (die models otherwise); RTL files added to rtl/nuked-md.qip.
- **Stage-1 measurement build** (HEAD + NUKED_RTL_STAGE1, telemetry still in): Analysis &
  Synthesis 0 errors (the conversion integrates), Fitter "can't fit" on that seed at 88% ALM
  (routing at the capacity edge, telemetry compiled in). ALM count == die-model build, as the
  plan predicts for stage 1 (savings come when the modules leave the 107 MHz sampling clock).
  Redo with telemetry off + a good seed to get real numbers.
- **z80_rtl.v + sim/z80/**: WIP, untracked. The z80 conversion agent verified its transformer
  output but was cut off (session limit) before running the bench; do NOT trust/commit until the
  bench passes. ym3438 (FM) conversion agent was cut off before writing ym3438_rtl.v.
- **Build 36** (35 + CDD 75 Hz command retransmit for CDC INIT): first seed -3.78 @107 (bad
  seed; the change is in the 53 MHz gate array). Reseeding (seeds 1,3) for a deployable rbf.
- **Main patched** (seek latency 12, tools/main_patches) built with the Arm 10.2 toolchain in
  WSL and deployed 07:32; original saved at /media/fat/MiSTer.orig_20260906. Thunder Storm FX
  (JP) mounts and the JP BIOS shows its menu with music; awaiting the owner's Start press to see
  if the Sega-logo freeze is gone.

## Build 36 (2026-09-06) — CDC INIT fixed; verificator runs to completion for the first time
Deployed seed3 (md5 33405809, -2.21 @107 / -0.85 @53.7; seed1 -2.35/-0.58; seed2 -3.78 = bad).
The 75 Hz CDD command retransmit made "insert disc without reset" read the disc: the
verificator's cddInit now completes (build 35 froze with cdd cmds=0 stats=8). Disc-mounted run
(FF CD USA via verificator_disc.mgl, Keep Running armed, region auto -> PAL-ratio timing):
COLOR CALC OK, VAR 23608 (02), IRQ 227 (09), REG 8030 1275 (07), REG X/PROG/WORD/WRAM OK,
CDC REGS 01 (correct, CDX-only), **CDC INIT OK**, CDC DMA1 OK, CDC FLAGS 05, CDC DMA2 05,
CDC DMA3 01, "Diagnostics complete." No hang across the whole suite (~2.5 min) on a -2.21 seed.
Next CDC accuracy items (GPGX issue 408 roadmap): FLAGS 05, DMA2 05, DMA3 01.
Release rbf (releases/) updated to build 36.

## Build 38 (2026-09-06) — PROMOTED TO RELEASE
Thunder Storm FX boots (patched Main) and FM audio confirmed OK on hardware; FM collapse enabled
by default (NUKED_RTL_FM in MegaCD.qsf) so a source rebuild matches the release rbf (md5 fc1a3f6e).
Build 36 superseded.

## Build 38 (superseded note) —
Two changes, both measured on hardware/build:
- FM collapse (NUKED_RTL_FM): same-seed full-core comparison, die-FM vs opt-FM (seed 2, telemetry
  on): 37,500 -> 37,328 ALMs (-172, -0.46%), 54,466 -> 52,608 registers (-1,858). The register
  saving is real but only ~0.4% ALM headroom, because the core is LUT-limited not register-limited.
  Modest. The FM opt is sim-proven bit-exact (both seeds, 200k cycles, 0 mismatches).
- CDC EDT-latch fix (unconditional, ASIC.vhd): verificator NTSC (region US), vs build 36:
  DMA3 01 -> 03 (progress: EDT now reads 0 after a DMA setup), FLAGS 05 -> 03 (shifted earlier:
  the word-RAM DMA path now doesn't hold EDT through IFCTRL=0), DMA2 05 unchanged. Directionally
  right (EDT is a latch) but incomplete: does not yet do "EDT set when one word remains" (host-data)
  nor the word-RAM path. Verificator-only, no gameplay impact. Needs the CDC sim bench to finish.
Decision: build 36 stays the RELEASE (releases/, md5 33405809). Build 38 (md5 fc1a3f6e) is a
measurement/test build; its gains (0.4% ALM, partial CDC) don't justify changing the release.
NUKED_RTL_FM stays off by default; the EDT fix is in HEAD (verificator-only effect).
Next for CDC accuracy: build a ModelSim bench for MCD.vhd (ASIC DMA + CDC) that replays the
verificator DMA2/DMA3/FLAGS register sequences, to iterate the EDT/DSR + odd-length fixes in
seconds instead of 45-min builds (see docs/CDC_ACCURACY_TODO.md).

## Build 39 (2026-09-07) — CDC fixes + full 1:1 conversion default + OSD; timing under review
Overnight session bundling four tasks. All source committed + pushed (commits ccb6fdf, f0a3f92,
331ca96, 404c6ea, 147b1ec, e84d473).

**Contents**
- CDC accuracy (ASIC.vhd): the DMA2 odd-length byte-drop and the EDT-latch clear were root-caused
  with a new ModelSim bench (sim/cdc/tb_cdc.sv, drives real ASIC+CDC with behavioural RAM). Fixes:
  reset DMA_BYTE on DMA_ADDR_SET (word-align every DMA); clear EDT only on the FF8004 write (new
  DMA_EDT_CLR), not on the FF800A address write. Bench now: DMA1/FLAGS/DMA2/DMA3 all PASS, 0 fail.
  This COMPLETES the partial build-38 EDT fix. Hardware verificator check pending on this rbf.
- 1:1 netlist->Verilog conversions wired as the DEFAULT build (task: convert regardless of fitment):
  FM ym3438_rtl, Z80 z80cpu_rtl, Stage1 tmss/ioc/arb _rtl — all proven storage-exact in sim/.
  Corrected a faithfulness bug: the default FM was the register-collapsed ym3438_opt, which is only
  output-exact (200k cyc) and NOT storage-exact (a dead-time two-phase master-slave has no single-FF
  equivalent); demoted it to opt-in (NUKED_OPT_FM) and made the exhaustively-proven ym3438_rtl the
  default. VDP ym7101_rtl is wired (NUKED_RTL_VDP) but OFF in build 39 (VDP w129 is on the critical
  path) — measured separately in the sweep.
- OSD: "Remove Cartridge & Reset" (R[37], keeps disc) + new "Eject Disc" (R[38], eject w/o reset).
  R[38] needed a Main hook: mcd_eject() (Unload+CD_STAT_OPEN, no reset), built into
  releases/main_mister/MiSTer (md5 f7fa87d4, also carries the seek-latency fix). Patch:
  tools/main_patches/megacd_eject_disc.patch. Eject built, hardware check pending.
- docs/MD_MCD_32X_ROADMAP.md — theory/roadmap for a separate combined MD+MCD+32X core (analysis only).

**Build 39 fit (seed 2, telemetry on, VDP die):** 37,805/41,910 ALMs (90%), 520/553 M10K (94%),
54,651 registers, 56 DSP. RBF md5 d1da203b (scratchpad MegaCD_b39_seed2.rbf).
**Timing (slow 85C):** -2.873 @107 (TNS -1069), -1.187 @53.7. This is ~0.9 ns WORSE than the
build-35/36/38 seed-2 baseline (~-1.85 to -2.03 @107, TNS -360..-586). Cause: FM opt->rtl adds
~2000 registers and the density rose to 90%; Stage1 (arb) may also touch the critical path. But
seed variance here is ~2 ns (build 36 saw -3.78 bad vs -1.87 good), so a seed sweep is needed
before concluding the conversions cost timing.
**In progress:** scratchpad/seed_sweep.sh builds b39-seed3 (VDP die) and b40-seed2/seed3 (VDP rtl),
results -> scratchpad/sweep_summary.txt. Pick the best-timing seed; enable VDP only if it holds
near the -2.0 baseline, else ship build-39 config (VDP converted but not enabled) and document.
Only the two die 68000s remain un-converted.

## Build 40 (2026-09-07) — PROMOTED: full 1:1 conversion, best timing + area (commit fc5a2f6)
The seed sweep resolved the build-39 timing question decisively. Full table (slow 85C):

| config (all have CDC fix + OSD R37/R38) | @107 | @53.7 | ALM | rbf |
|---|---|---|---|---|
| b39 FM/Z80/Stage1 rtl, VDP die, seed2 | -2.873 | -1.187 | 37,805 (90%) | scratchpad |
| b39 VDP die, seed3 | -2.092 | -0.140 | 37,638 (90%) | scratchpad |
| b40 + VDP rtl, seed2 | -2.504 | -0.471 | 36,799 (88%) | scratchpad |
| b40 VDP rtl, seed3 | -2.324 | -0.329 | 36,738 (88%) | scratchpad |
| **b40 VDP rtl, seed4 (PROMOTED)** | **-1.971** | **-0.115** | **36,829 (88%)** | releases/..20260907 |
| b40 VDP rtl, seed5 | -2.510 | -0.495 | 37,980 (91%) | scratchpad |

Decision: **b40 seed4** is the release. It is the COMPLETE cell-netlist conversion (VDP+FM+Z80+
tmss/ioc/arb all 1:1 rtl), and it BEAT the pre-conversion baseline on timing (-1.971 vs ~-2.0
@107) while using ~900 fewer ALMs than the VDP-die variants (the 1:1 VDP synthesises better than
the die netlist). QSF locked to SEED 4 + NUKED_RTL_{FM,STAGE1,Z80,VDP}=1. RBF md5 824adafc.

Lesson reinforced: timing here is dominated by placement seed (-1.971..-2.873 for the same logic).
Always multi-seed before judging a netlist change; commit the winning SEED so the rbf reproduces.

**Not hardware-tested** (built overnight, user asleep; not deployed). Morning checklist:
1. Load releases/MegaCD_TEST_NukedMD_20260907.rbf. Install releases/main_mister/MiSTer (md5
   f7fa87d4) for the OSD "Eject Disc" + seek-latency (back up /media/fat/MiSTer first).
2. Run mcd-verificator with a disc mounted: confirm CDC DMA2/DMA3/FLAGS now pass on hardware.
3. Sanity: BIOS boots (US+JP+EU), a CD game runs, FM/PCM/CDDA audio clean (the FM is now the 1:1
   rtl, not the collapse; the VDP is the 1:1 rtl - watch for any video regression).
4. Test OSD "Remove Cartridge & Reset" (R[37]) and "Eject Disc" (R[38], needs patched Main).

**Remaining conversion:** only the two 68000s. m68kcpu (68k.v) is already one self-contained
`always @(posedge MCLK)` module (99 always blocks + gate-level assigns), NOT a ym_lib-style cell
netlist, so it has no latch-cell overhead to convert and little synthesis benefit; on the 53.7 MHz
(non-critical) domain. Recommend discussing whether a 1:1 68000 rewrite is wanted before spending
the multi-hour agent on a near-identity transform. The sub-CPU 68000 is the same Nuked m68kcpu.

## Builds 41-43 (2026-09-07) — hardware test of build 40; CDC EDT change reverted; core un-hung
Deployed build 40 (full 1:1 conversion) + patched Main (Eject Disc, f7fa87d4) to hardware and ran
the mcd-verificator with a disc. Findings:

- **Build 40 HUNG at CDC DMA3.** Telemetry showed the core alive (seq++) but the sub-CPU idle-
  looping FF8010/PRG while the MAIN 68000 (verificator) was wedged in the DMA3 host-data test.
- **Root cause: commit e22d454 (the build-38 "EDT is a latched flag" edge-latch) hangs DMA3 when a
  disc is mounted.** It was validated WITHOUT a disc (DMA3 showed 03); with a disc the verificator's
  host-data poll never completes. Present in builds 38/40/41/42 -> all hang. Tonight's DMA_BYTE reset
  (ccb6fdf) additionally hangs DMA3 (it fixed DMA2 05->OK but the shared DMA_ADDR_SET pulse corrupts
  the DMA3 transfer). Isolated by: build 41 (revert DMA_EDT_CLR, keep DMA_BYTE) still hung; build 42
  (revert DMA_BYTE too, keep e22d454 EDT latch) still hung; **build 36 (predates e22d454) COMPLETES**
  with the current Main+disc (FLAGS 05, DMA2 05, DMA3 01, DMA1 OK, "Diagnostics complete").
- **Fix: reverted ASIC.vhd to build 36 CDC** (git checkout 3e6e1aa -- rtl/MCD/ASIC.vhd): dropped
  e22d454 (EDT edge-latch) AND ccb6fdf (DMA_BYTE/DMA_EDT_CLR); kept all other CDC fixes (CDD 75 Hz
  retransmit, PRG/wave-RAM ack). **Build 43 COMPLETES the suite, no hang** (FLAGS 05, DMA2 05,
  DMA3 01). Release rbf now build 43 (releases/..20260907, md5 041eed47), seed4, -2.085 @107.

**State of things on hardware (build 43, confirmed):**
- 1:1 NukedMD conversions (FM/VDP/Z80/tmss/ioc/arb) RUN CORRECTLY on silicon (core boots, video +
  all non-CDC tests pass). This validates the whole conversion effort incl. the VDP on hardware.
- Patched Main (Eject Disc R[38] + seek-latency) booted fine.
- CDC verificator errors are UNFIXED, back to build-36 level: FLAGS 05, DMA2 05, DMA3 01. CDC REGS 01
  (correct Model 1/2) and PAL VAR/IRQ/REG windows are expected, not bugs. IRQ 0A (NTSC) jitters
  OK/0A run-to-run.

**CDC accuracy is deferred to a proper investigation.** The sim bench (sim/cdc) gives FALSE PASSES
(passed the DMA3 that hangs, failed the DMA2 that passes) -- it stubs the sector-decode path. A
faithful bench must model the CDC decoder buffer filled by real sector reads and replay the
verificator's exact A12004/A12008/FF8004/FF800A sequence. See docs/CDC_ACCURACY_TODO.md. Do NOT
reintroduce e22d454 or the DMA_ADDR_SET DMA_BYTE reset without such a bench proving DMA3 completes
with a disc.

**107 MHz timing:** analysed exhaustively (docs/TIMING_107MHZ_ANALYSIS.md). No faithful SDC exception
exists (io_address & VD free-run every edge); fitter knobs are near-maxed and adding effort
multipliers REGRESSED to -4.994. Best remains seed selection (-1.971 seed4 on the build-40 netlist).
A seed sweep was interrupted to prioritise the CDC hang fix. Genuine closure needs RTL pipelining
(behaviour change, out of scope) or a lower clock -- a human decision.

**Note:** Quartus inlined sys.tcl/files.qip into MegaCD.qsf during the rapid build/kill cycles (the
known 125085 hazard); restored the clean 68-line qsf before committing.

---

## Session 2026-09-07 (cont.): the faithful sub-CPU CDC bench works

`sim/cdc/tb_mcd_cdc.sv` now drives the whole `rtl/MCD/MCD.vhd` block — real gate-level
sub-CPU running the verificator sub BIOS, real ASIC, real CDC — and relays every `FF80xx`
access through the actual COMCMD mailbox. This is the bench `docs/CDC_ACCURACY_TODO.md`
asked for, and it no longer gives false passes.

**Sub BIOS protocol, decoded 1:1 from the extracted machine code** (not guessed):
```
0x202 movea.l #$70000,a7 / 0x208 move #$2000,sr      init (IRQ mask 0 => level 5 enabled)
0x20c move.w #0,(FF8026)  while cmd_idx!=0           ack-wait, clears COMSTA[3]
0x21c move.w #0,(FF8020)                             STA_BSY:=0  => READY
0x222 cmpi.w #0,(FF8010) / beq 0x222                 idle, wait for a command
0x22c move.w (FF8010),(FF8020)                       STA_BSY:=cmd  => BUSY (before dispatch!)
cmd1 RD_B 0x286  a0:=(FF8014); (FF8022).b:=(a0).b
cmd2 WR_B 0x292  a0:=(FF8014); (a0).b:=(FF8012).b
cmd3 RD_W 0x29e  a0:=(FF8014); (FF8022):=(a0).w
cmd4 WR_W 0x2aa  a0:=(FF8014); (a0):=(FF8012).w
lvl5 ISR  0x37c  move.w #5,(FF8026); rte              CDC IRQ -> COMSTA[3]=5
lvl6 ISR  0x384  move.w #6,(FF8026); rte
```
So mailbox = cmd_idx FF8010 / cmd_dat FF8012 / cmd_adr FF8014(u32) / sta_bsy FF8020 /
sta_rsp FF8022.

**The DMA-complete handshake is end-to-end real.** CDC drains to word RAM -> DTEI ->
`IFSTAT(DTEI)=0` -> `INT_N` low (CDC.vhd:645) -> ASIC latches `INT_PEND(5)` on the falling
edge (ASIC.vhd:1306) and drives IPL5 if `IEN(5)` (ASIC.vhd:2520) -> the real 68000 takes the
autovectored interrupt -> ISR writes `FF8026=5` -> main polls `A12026`. A DMA machine that
never finishes therefore hangs here exactly as on hardware.

**Three bench defects fixed (no RTL changed):**
1. **`IEN(5)` was never enabled.** The gate-array interrupt mask is `FF8032`, written on the
   LOW byte (`IEN <= S68K_DI(6 downto 1)`, ASIC.vhd:993), so it needs a *word* write via the
   relay. The sub BIOS init never writes it, so the main must. The isolated `tb_cdc.sv` had
   hardcoded `ien5 = 1'b1` and so never exercised this at all.
2. **The relay returned before the sub had executed the command.** The sub sets
   `STA_BSY:=cmd_idx` at 0x22c *before* dispatching, so `BSY!=0` only means "accepted".
   Probes showed state lagging exactly one write, with the DTTRG write never happening —
   indistinguishable from a dead DMA machine, because `EDT=1` merely means `CDC_DTEN_N=1`
   (ASIC.vhd:405-424). `mcd_cmd()` now ends with `wait_bsy0()`.
3. **Main reads were ~10x too fast.** The real main 68000 is 7.67 MHz and cannot issue
   `A12008` reads back-to-back at 53.7 MHz; draining the host FIFO faster than a real CPU
   outruns the CDC fetch and makes DSR read low early (a bench-only `DMA3 ERROR 03`).
   `ext_rd_host()` uses the same 150-CLK spacing as the isolated bench's `EXT_GAP`.

**Results (both agree with hardware and with the isolated bench):**
| CDC build | `test_dma3` result |
|---|---|
| build-36 (HEAD) | `ERROR 01` — flags `82` vs expected `02` (EDT set while idle) = the hardware result |
| `ccb6fdf` variant | `01`,`02` pass, `01-07 OK`, `22`=`47`, `23`=`87` -> **PASS** |

So the `ccb6fdf` EDT-latch does fix DMA3 01/02, and the WRAM DMA (0x22/0x23) completes on it.
**The hardware hang is therefore NOT at 0x22.**

**Where the hang must be:** sub-tests `0x10`-`0x21` — the SUB-destination host reads and the
two cross-reader cases. The isolated bench had to skip every one (`if(1'b0)`) because they
need a real sub-CPU; this bench is the first that can run them. `0x10` (subflags `03`) and
`0x11` (subflags `43`) already PASS on the variant. The 2348-byte drain through the relay is
slow in sim (~11 us of sim per relay round-trip, dominated by the sub executing the handler),
so a full `0x10`-`0x21` pass is roughly a 2-hour ModelSim run. Sub-tests `0x26`/`0x30+`
(buffer wrap) are still not transcribed.

**Do not** reintroduce `e22d454`/`ccb6fdf` on hardware until `0x10`-`0x21` are shown to
complete in this bench.

Run it with:
```
bash sim/cdc/compile_mcd.sh
/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem/vsim -c -quiet work.tb_mcd_cdc -do "run -all; quit -f"
```
To test a variant: `git checkout ccb6fdf -- rtl/MCD/ASIC.vhd`, compile, then
`git checkout HEAD -- rtl/MCD/ASIC.vhd` (the sim runs from the compiled `work` library).

### THE DMA3 HANG IS A PRE-EXISTING PCM-DMA DEADLOCK, NOT THE EDT LATCH

Disassembling the real `testCDC_dma3` out of `mcd-verificator.bin` (ROM `0x12E80`-`0x132F8`)
showed the test does **not** stop at sub-test `0x23`. It goes on to run three more DMAs, each
behind its own unbounded `while (COMSTA[3] != 5)` poll, to destinations neither bench had ever
touched:

| sub-test | ROM | destination | ASIC path |
|---|---|---|---|
| 0x22/0x23 | 0x1310A | word RAM (DD=7) | `WR_DMA_RUN` |
| 0x24/0x25 | 0x1317C | **PRG-RAM (DD=5)**, FF800A=0x4000 | `PR_DMA_RUN` |
| 0x26/0x27 | 0x131EA | **PCM (DD=4)** | `PCM_DMA_RUN` |
| (trailing) | 0x132B8 | word RAM again | `WR_DMA_RUN` |

Running these in the sub-CPU bench:
- `ccb6fdf` variant: `01`-`07` PASS, `10`-`16` PASS, `22/23` PASS, `24/25` PASS (PRG-RAM fine),
  then **`26` HANGS** — and the sub-CPU stops answering the COMCMD relay.
- **baseline build-36 (what ships today) hangs on exactly the same PCM DMA.** Because build-36
  aborts `testCDC_dma3` at sub-test `01` (its EDT inaccuracy) it never *reaches* the PCM DMA, so
  the deadlock stays hidden. Run standalone (`test_pcm_dma()`), build-36 deadlocks identically:
```
[pcm] after poll  PCM_DMA_RUN=1 PCM_S68K_HALT=1 S68K_HALT_N=0
                  DTEN_N=0 DBC=092e sub_A=00020c
```
`DBC` moved 0x092F->0x092E, i.e. it froze after **one byte**, with the sub-CPU halted
(`S68K_HALT_N=0`) and never released, parked at 0x20C in the cmd_rx ack-wait loop.

**So reverting `e22d454`/`ccb6fdf` (build 43) never fixed anything** — it only re-hid this
deadlock behind the earlier `ERROR 01`. The EDT latch is a genuine accuracy *fix*; restoring it
is what lets `testCDC_dma3` get far enough to reach the real bug.

**Where the bug is.** PCM is the only DMA destination that steals a sub-CPU bus cycle
(ASIC.vhd:2367-2412). `DMA_PCM_SEL <= '1' when DD="100" and DS=DS_WRITE` starts it, then:
```
PCMA_DMA_HALT0: wait S68K_AS_N='1'                      -> HALT1
PCMA_DMA_HALT1: wait S68K_AS_N='0'; PCM_S68K_HALT<='1'  -> HALT2
PCMA_DMA_HALT2: wait S68K_AS_N='1' twice; release halt  -> DMA_WRITE -> END
```
`PCM_S68K_HALT` reaches the real gate-level 68000's `HALT_i` (MCD.vhd:249, MC68K.vhd:117/131).
The observed frozen state has `PCM_S68K_HALT=1` stuck. Note `AS_N` is NOT frozen low (measured:
`AS_N=1`, 2 edges seen after the halt) and `CLK_12M_R` free-runs (`EN <= ENABLE`, ASIC.vhd:304;
`CLK_CNT` advances on `CLK50_EN`, ASIC.vhd:308-316) — so the stall is in the HALT0/HALT1/HALT2
handshake's assumptions about the halted CPU's `AS_N`, not a stopped clock. **Pin the exact stuck
state with the `PCMA`/`DS`/`PCM_HALT_WAIT` probe in `test_pcm_dma()` before changing any RTL.**

**Do this next, in order:**
1. Fix the PCM DMA halt handshake so a PCM-destination DMA completes.
   `sim/cdc/tb_mcd_cdc.sv test_pcm_dma()` reproduces it standalone in ~3 minutes on either build.
2. Then RESTORE `ccb6fdf` (`git checkout ccb6fdf -- rtl/MCD/ASIC.vhd`) — it is the correct EDT
   behaviour and fixes DMA3 `01`/`02` and the FLAGS tests.
3. Re-run the full suite on hardware. Expect DMA3 to get past `01` for the first time.

Nothing here needed an RTL change to discover, and none was made; the tree is baseline build-36.

#### CORRECTION to the section above: the PCM deadlock is a SIMULATION artifact

Probing the stuck state directly (`PCMA=3` = `PCMA_DMA_HALT2`, `PCM_HALT_WAIT=x`) shows the real
cause, and it is **not** a hardware defect, so the conclusion above is wrong and is retracted:

`PCM_HALT_WAIT` (ASIC.vhd:295) is declared with no initialiser and is the one signal in that
process missing from the reset branch. `PCMA_DMA_HALT2` does
`PCM_HALT_WAIT <= PCM_HALT_WAIT + 1; if PCM_HALT_WAIT = 1 then <release halt>`, so with `'U'`
the increment stays `'U'`, the comparison is never true, the machine never leaves HALT2 and
never clears `PCM_S68K_HALT` — the sub-CPU stays halted forever. On the FPGA the register powers
up to 0 and the handshake works (which is why PCM DMA works in games), so this deadlock only
ever happens in simulation. Fixed by resetting `PCM_HALT_WAIT` — a no-op on silicon.

Measured evidence that it is not the CPU/clock: `AS_N` is high with 2 edges seen after the halt
(so the CPU is not frozen mid-cycle) and `CLK_12M_R` free-runs (`EN <= ENABLE` ASIC.vhd:304,
`CLK_CNT` on `CLK50_EN` ASIC.vhd:308-316).

**So the hardware DMA3 hang is still NOT reproduced.** What is established:
- build-36 (shipping): `testCDC_dma3` -> `ERROR 01` (flags 82 vs 02). Matches hardware.
- `ccb6fdf`: `01`-`07` PASS, `10`-`16` PASS, `22/23` PASS, `24/25` PASS. Everything transcribed
  and reachable so far passes; `26`+ needs the reset fix above before it means anything.
Still untranscribed: the sub-tests after the trailing WRAM DMA (ROM 0x132F8 onward, which begin
`pea $09B0` — a different PT, i.e. buffer-offset/wrap cases).

**Method note for whoever continues:** four separate "hangs" in this bench have now turned out
to be the bench or an X, not the RTL (poll budget too small; relay returning before the sub had
executed; main reads faster than a real 68000; and this uninitialised register). Probe the actual
internal state before concluding anything about the hardware.

---

## Build 44 on hardware — and CDC INIT turns out to be INTERMITTENT

Build 44 (= build-36 CDC + the `PCM_HALT_WAIT` reset + 1:1 NukedMD, seed 4) was compiled,
deployed and run. Quartus note: `quartus_sta.exe` crashed with an access violation
(`sta_find_duplicates_of_deleted_net_name`) while reading the SDC, *after* the Assembler had
already written the `.rbf`. Re-running `quartus_sta` alone completed in 20 s with 0 errors, so
the crash was transient, not a project fault. Worst-case setup slack **-2.049 ns** on the
107 MHz clock (build 43 was -2.085, build 40 seed4 -1.971) — i.e. unchanged within seed noise,
as expected for a reset-only RTL delta.

**The important result is a methodological one.** Running the verificator on build 44 gave:

| run | CDC INIT | rest |
|---|---|---|
| 1 | `ERROR 03` | CDC tests after INIT skipped |
| 2 | `OK` | FLAGS 05, DMA2 05, DMA3 01, DMA1 OK |

Run 2 is **identical to build 43**, which was re-flashed and re-run through the same MGL and
disc as a control (`CDC INIT OK`, FLAGS 05 / DMA2 05 / DMA3 01 / DMA1 OK). So build 44 is not a
regression — **`CDC INIT` passes or fails run-to-run on the same bitstream**, exactly like the
already-known `IRQ TEST 0A` jitter. That is unsurprising with -2 ns of setup slack: the design
is not timing-clean, so which paths fail varies per configuration.

**Consequences — read this before trusting any hardware result in this file:**
- A single verificator run proves nothing. Repeat it (3+) before calling anything a
  regression or a fix. Several conclusions recorded earlier in this file rest on single runs.
- That includes the original "build 40 hangs at DMA3" observation that started the whole CDC
  investigation. A hang is more decisive than an error code, but it was still one run, and the
  sub-CPU bench has since shown every transcribed DMA3 sub-test passing on `ccb6fdf`.
- Fixing the 107 MHz slack is therefore not just a tidiness issue; it is a prerequisite for
  trustworthy hardware measurements.

Disc note: `CDC INIT` needs a disc with real Mode-1 sectors. No disc gives `ERROR 03`;
`games/MegaCD/JPTEST/blank.cue` gives `ERROR 04`. Use a real image —
`/media/fat/_Console/MegaCD_verif_disc.mgl` (created for this) loads the
`3 Ninjas Kick Back (USA).chd` plus the verificator cart in one go.

## Main_MiSTer changes now live on a fork

The two Linux-side changes are no longer only `.patch` files. See
`tools/main_patches/README.md`: branches `megacd-eject-disc`, `megacd-seek-latency` and the
combined `megacd-nukedmd` on https://github.com/retrorepair/Main_MiSTer, all off upstream
`master` (`f8dc68e`), ready to raise as PRs.

---

## Verificator errors: where each one stands (build 46)

Decoded from the real mcd-verificator binary, reproduced in sim where possible.

| test | was | cause | status |
|---|---|---|---|
| CDC DMA2 | 05 | odd-length DMA byte-drop (`ccb6fdf`) | **fixed**, confirmed on hardware in build 45 |
| CDC DMA3 | 01 -> 50 -> hang | see below | **fixed**, A/B proven in sim |
| CDC FLAGS | 05 -> 12 | FF8004 write cleared EDT but not DSR | fix in build 46, spec-exact |
| CDC REGS | 01 | CDC address register was 4 bits, LC8951 has 5 | fix in build 46, spec-exact |
| IRQ TEST | 0A | sub-CPU INT2 service latency | **root-caused, NOT fixed** |

### The DMA3 hang - solved

`testCDC_dma3` sub-test **0x56** (ROM 0x13D42) sets `A12002 = 0xFF` (PRG-RAM write protect on),
DMAs 0x930 bytes into PRG-RAM at offset 0x9000, then waits on an **unbounded** `COMSTA[3] == 5`
poll at ROM 0x13DB0 - no iteration limit, so a transfer that never finishes stops the suite
dead. That is the "CDC DMA3...." with no result seen on hardware.

The PRG-RAM arbiter gated its DMA writes on the write protect and, when blocked, exited via
`PRS_END` instead of `PRS_DMA_END`. `PR_DMA_RUN` is cleared **only** in `PRS_DMA_END`, so it
stayed asserted and the DMA machine's `DS_WRITE_WAIT` (DD="101") waited on it forever: DBC
stopped counting, DTEI never asserted, the sub-CPU's level-5 interrupt never arrived.
Write protect guards CPU writes, not DMA. Gate removed.

A/B in `sim/cdc/tb_mcd_cdc.sv` (sub-test 0x56):
```
gate present : DBC frozen at 092d from the wp_dma probe to the after_0x56 probe,
               DTEN_N=0, DD=101, 60000-read poll exhausted  -> ERROR 56
gate removed : "56 PRG-RAM DMA ignores write protect  OK", whole suite PASS
```

### IRQ TEST 0A - root-caused, not fixed

Sub-test 0x0A (ROM 0x18434) sets `IEN = 4` (IEN(2), the main->sub INT2), then 256 times:
writes `A12000 = 1` to assert INT2, waits ~6 nops, and requires `A12026 == 2` - i.e. the sub's
level-2 ISR (BIOS 0x334: `move.w #2,(FF8026)` / `addq.w #1,(FF8028)`) must have run.

Measured decomposition in the bench:
```
req -> IPL       0.02 us   gate array latches INT_PEND(2) immediately - NOT the problem
IPL -> ISR       9.3  us   finishing the current instruction + 68000 exception entry
ISR -> COMSTA3   3.3  us   the two-instruction ISR
TOTAL           12.5  us
```
The test's real budget is ~8 us, not the ~3 us quoted earlier in this file: after the write it
executes 6 nops **plus** `movea.l ($196A4),a0` and `move.w ($26,a0),d1`, ~60 cycles at 7.67 MHz.
So we are ~1.5x over, which is consistent with hardware jittering OK/0A rather than always
failing.

It is interrupt-ENTRY latency: the exception frame's stack pushes and the vector fetch all go
to PRG-RAM. That path is already tuned (writes posted with DTACK at issue; reads acknowledged
when the SDRAM accepts, not when data returns) and its comments document the corruption bugs
earlier attempts caused - so there is little safe headroom left there.

**CAVEAT before anyone optimises against this number:** the bench's PRG-RAM is a behavioural
model with an arbitrary 3-cycle latency, not the real SDRAM controller. The *structure* of the
measurement (entry dominates, PRG-RAM bound) is sound; the absolute 12.5 us is not. Measure on
hardware before changing the PRG-RAM path.

## Build 46 on hardware (3 runs) - CDC fixes land, but timing regresses

md5 of the b46 rbf is in releases/MegaCD_TEST_NukedMD_b46_20260907.rbf.

| test | b43/44 | b45 | b46 (3 runs, consistent) |
|---|---|---|---|
| VAR TESTS | OK | OK | **ERROR 02** (new) |
| IRQ TEST | 0A | 0A | 09 |
| REG 8030 | OK | OK | **ERROR 07** (new) |
| CDC REGS | 01 | 01 | 08 (advanced) |
| CDC INIT | OK | OK | OK (still jitters to 03) |
| CDC FLAGS | 05 | 12 | 32 (advanced) |
| CDC DMA2 | 05 | OK | OK |
| CDC DMA3 | 01 | 50 / HANG | 60, **no hang** |
| CDC DMA1 | OK | OK | OK |

**The DMA3 hang is gone** and DMA2 stays fixed; REGS, FLAGS and DMA3 all advanced to sub-tests
that were previously unreachable. So the four CDC fixes are doing their job.

**But two tests that passed now fail, and it looks like timing, not logic.** Setup slack:

| clock | b45 | b46 |
|---|---|---|
| 107 MHz `counter[0]` | -2.049 | -2.149 |
| `counter[1]` | **+0.103** | **-0.218** |
| `pll_hdmi` | **+0.073** | **-0.064** |

b45 had one failing clock, b46 has three. `counter[1]` going negative is the suspicious one -
VAR TESTS and REG 8030 both report a measured COUNT (23608..23732, 1274..1275) rather than a
plain pass/fail, i.e. they are timing measurements, and they moved the moment a second clock
domain started failing. Build 47 (SEED 7) is an attempt to recover those two marginal clocks
without touching logic; -2.1 ns on the 107 MHz clock will not be fixed by a seed.

**Do not attribute VAR 02 / REG 8030 07 to the CDC changes without re-testing on a build whose
`counter[1]` is positive.** If a seed recovers them, they were fitting collateral.

## VAR TESTS 02 and REG 8030 07 are TIMING measurements - decoded, with their ranges

Both print a measured count and accept only a narrow band. Neither compares a register value,
and in both cases the earlier sub-tests (which do check values) pass. So a build that fails
these has a timing problem, not a logic one.

**VAR TESTS 02** (ROM 0x189BC..0x1899FE). Issues sub-CPU RPC command 5 (a 65536-iteration word
read loop at 0x080000, sub ROM 0x1556) and counts main-CPU polls of A12020 until the sub goes
idle:
```
0189f2  addi.l #$FFFFA337,d1   ; count - 23753
0189f8  cmpi.l #$E3,d1         ; 227
0189fe  bhi -> fail, print count, error 02
```
accepted **23753..23980** (0.96% wide). Sub-test 03 is the same against 0xFF8000, same bounds.

**REG 8030 07** (ROM 0x187A6..0x187FA). Sets TIMER (FF8030) = 255, syncs on a level-3 interrupt,
then counts main-CPU polls of A12026 across one whole timer period (256 x 30.72 us = 7.86 ms):
```
0187f0  addi.l #$FFFFFAFA,d0   ; count - 1286
0187f6  moveq #$2,d1           ; bound 2
0187fa  bcs -> fail, print count, error 07
```
accepted **1286..1288 - three values, 0.16% tolerance**. (Sub-test 08 re-writes TIMER mid-period
and accepts 1283..1290, checking that a write does not reload a running counter.  REG 8030 does
NOT use the stop watch; A1200C is covered by "REG X00C" at 0x188AE.)

**Measured on build 46: VAR 23608..23732 (0.09-0.6% low), REG 8030 1274..1275 (~0.9% low).**
Both UNDERSHOOT, i.e. each main-CPU poll iteration takes ~0.9% LONGER than on real hardware -
the poll loop is 46 cycles, so this is a fraction of a wait state per gate-array read. Build 45
passed both; build 46 differs only in a handful of CDC lines plus a fitter run that took
counter[1] from +0.103 to -0.218. A late DTACK on the A12020/A12026 read path inserts a whole
68000 wait state, which is exactly this size of error.

**So these two are not fixable by CDC logic changes.** They need either timing closure on
counter[1] or a genuinely faster main-CPU gate-array read acknowledge. SEED 7 was tried and is
far worse (107 MHz -2.829, counter[1] -1.094), so seed roulette is not the answer either.

## IRQ sub-test 09 is ALSO a narrow timing measurement - the three regressions are one cause

IRQ TEST is ROM 0x18244..0x18686 (entry `pea $19612` = "IRQ TEST...."). Sub-test 09
(ROM 0x18376..0x18410):
```
  relay: FF8028 = 0, FF802A = 0        ; clear the L2 and L3 (timer) counters
  relay: FF8030 = 1                    ; TIMER W, TD=1  -> period (TD+1)*30.72us = 61.44us
  relay: FF8032 = 0x0C                 ; unmask IEN2 | IEN3
  1024x { A12000.b = 1 (IFL2) ; 13 nops }   ; 102 cycles/iter -> ~13.6-13.9 ms
  relay: FF8032 = 0, FF8030 = 0        ; stop
  0183f6  cmpi.w #$0400,A12028   -> must be exactly 1024   (sub-test 08, PASSES)
  018402  cmpi.w #$00DF,A1202A / bls -> fail 09
  01840c  cmpi.w #$00E2,A1202A / bls -> pass
```
`A1202A` is the sub-CPU level-3 (timer) interrupt count, incremented by the L3 handler at sub
0x340 (`move.w #3,FF8026 ; addq.w #1,FF802A ; rte`). Accepted **224..226 - three values**, a
~0.9% band. Note 09 runs BEFORE 0A, so `0A -> 09` is a REGRESSION: the DUT now fails earlier.

Codes 05 and 07 are never produced by this function.

### The three build-46 regressions have one cause

| test | tolerance | build 46 |
|---|---|---|
| VAR TESTS 02 | 23753..23980 (0.96%) | 0.09-0.6% low |
| REG 8030 07 | 1286..1288 (0.16%) | ~0.9% low |
| IRQ 09 | 224..226 (~0.9%) | fails (was passing, failed later at 0A) |

Three independent stopwatch tests, each with ~1% tolerance, all breaking together the moment
the fitter took counter[1] from +0.103 to -0.218. None of them compares a register value; the
value-checking sub-tests that precede each of them still pass. This is one timing regression,
not three logic faults.

**Consequence for planning.** Timing margin is now the gate on the remaining verificator errors,
not CDC accuracy. REG 8030 07 tolerates 0.16% - it will flip on almost any fitter reshuffle
regardless of what the CDC does. Adding more logic to a design already at -2.1 ns on the 107 MHz
clock makes this worse every time. The CDC fixes themselves are sound and are landing (hang
gone, DMA2 fixed, REGS/FLAGS/DMA3 all advancing), so the right split is:
  1. keep the CDC fixes,
  2. treat timing closure as its own piece of work (it also gates IRQ 0A, whose INT2 service
     latency measured 5.94 us on hardware against a ~7-8 us window - i.e. also margin-limited).

## Build 50: CDC DMA3 PASSES (3/3 runs). Telemetry off to make the design fit.

Build 49 failed outright: `Error (11802): Can't fit design in device` at 88% ALM / 94% RAM
blocks. The six CDC fixes tipped an already-full Cyclone V over the edge. `MCD_TELEMETRY` is
now commented out in MegaCD.qsf (it costs a 32x32 ring buffer, a capture FIFO and a stack of
32-bit counters); re-enable it when live HPS-side measurement is needed. Build 50 fits at 84%
ALM, and `pll_hdmi` recovered to +0.163 while counter[1] improved to -0.139 (still negative).

| test | b43/44 (start) | b45 | b46 | **b50 (3 runs)** |
|---|---|---|---|---|
| VAR TESTS | OK | OK | 02 | 02 (timing) |
| IRQ TEST | 0A | 0A | 09 | 09 (timing) |
| REG 8030 | OK | OK | 07 | 07 (timing) |
| CDC REGS | 01 | 01 | 08 | **0B** |
| CDC INIT | OK (jitter) | OK | OK | **OK, stable 3/3** |
| CDC FLAGS | 05 | 12 | 32 | 32 |
| CDC DMA2 | 05 | **OK** | OK | **OK** |
| CDC DMA3 | 01 | 50 / HANG | 60 | **OK** |
| CDC DMA1 | OK | OK | OK | OK |

**CDC DMA3 passes on all three runs** - the host-data-write fix closed sub-test 0x60, the last
thing in its way. DMA2 stays green. CDC INIT no longer jitters. So two of the five original
errors are fixed outright and the CDC DMA path is fully clean (DMA1/DMA2/DMA3/INIT all OK).

Remaining, and now clearly separated by cause:
- **CDC REGS 0B, CDC FLAGS 32** - real logic, specs already decoded (see below).
- **VAR 02, IRQ 09, REG 8030 07** - narrow-band timing measurements; will not respond to CDC
  work. Gated on timing//capacity, not accuracy.

## Build 51 + NTSC: a full pass, and the three "timing" failures explained

**Build 51 produced the first clean sweep this project has seen** - every mcd-verificator test
OK, IRQ TEST included (run 4 of 4 below). The other runs differ only in the two remaining
*intermittent* failures, so the core is now correctness-complete on this ROM and what is left
is margin, not logic.

| run | result |
|---|---|
| 1 | all OK except `IRQ TEST 0A` |
| 2 | `IRQ TEST 0A` + `CDC INIT 03` (the run aborts at CDC INIT) |
| 3 | as run 2 |
| 4 | **everything OK** |

Fixes in build 51 on top of build 50: DBCH reads back 4 bits, FF8006's word read no longer
returns a stale high byte, and an unimplemented CDC register (AR >= 16) reads back 0xFF rather
than 0x00. Those closed `CDC REGS 0B` and `CDC FLAGS 32`.

### VAR 02 / REG 8030 07 / IRQ 09 were never CDC bugs - the console was running PAL

All three are main-clock / sub-clock *ratio* measurements with a software counter on one side
(ROM 0x0189CA, 0x0187A6, 0x018376):

| test | counts | window |
|---|---|---|
| VAR 02 | main polls of A12020 while the sub does 65536 word-RAM reads | 23753..23980 |
| REG 8030 07 | main polls of A12026 across one Timer W period (7.864 ms) | 1286..1288 |
| IRQ 09 | sub level-3 IRQs during a fixed 1024-iteration main loop | 224..226 |

The CD block is a fixed 12.5 MHz in both regions (`mcd_cegen` compensates `IN_CLK`,
`MegaCD.sv:831`), but the main 68000 is VCLK/7 off `clk_sys`: 7.670454 MHz NTSC,
7.600489 MHz PAL - a ratio of 0.990879. That predicts 23648 / 1275.3 / 227.1 against
measurements of 23608..23732 / 1274..1275 / 227..228 - all three, including IRQ 09's opposite
sign, inside the run-to-run jitter. An audit of every divider in `rtl/MCD` found none off by
even 0.01%; the whole discrepancy is the PAL console clock.

Region came from header byte $1F0 during `rom_download`. Upstream that meant the BIOS alone;
here `rom_download` had grown to `bios_download | cart_download` when the cartridge slot was
added, so `mcd-verificator.bin`'s 'W' header overwrote the BIOS's 'U' and forced EU/PAL.
Commit f4d1a6c sniffs `bios_download` only - the video standard is the console's, not the
cartridge's. Confirmed before the fix was written by pressing F2 (the core's force-US hotkey)
on a running build 50: VAR TESTS and REG 8030 turned OK and IRQ moved from 09 to 0A.

### What is left

- **`IRQ TEST 0A`** - intermittent. The sub-CPU has 52 main clocks = 6779 ns (NTSC) from the
  arming write at A12000 to the read of A12026, and must fit a whole level-2 exception in it,
  256 times running. Hardware telemetry measured our INT2 response at 5.94 us mean, so the
  mean passes and the tail does not. Prime suspect: `ASIC.vhd:2576-2591` terminates the sub's
  interrupt-acknowledge cycle with **/VPA**, so the gate-level 68000 runs a 6800-style
  E-clock-synchronised autovector cycle (~10-19 clocks, ~720 ns of phase jitter) instead of the
  4-clock DTACK cycle the MC68000UM's "Interrupt 44(5/3)" assumes. Whether real hardware
  asserts /VPA there is being checked; do not change it without evidence.
- **`CDC INIT 03`** - intermittent, long-standing.
- Both are margin symptoms and the design sits at about -2.1 ns on the 107 MHz clock, so
  timing closure is now the highest-value work.

### Remote-control tooling (new)

`tools/mister/uinput_kbd.py` runs on the MiSTer and synthesises keystrokes through /dev/uinput;
MiSTer's inotify watch on /dev/input picks the device up with no restart. Run it once with
`--daemon` (it holds the device open and reads key names from /tmp/mister_kbd) and drive it with
`--send osd up up enter`; creating the device per keypress races MiSTer's device-open path and
loses keys. `tools/mister/osd.py` holds the OSD selection indices derived from Main's menu.cpp -
note the OSD is composited after the scaler, so it can never appear in a screenshot and must be
driven blind; the bottom four items are reachable with 1-4 UP presses because the selection wraps.
`tools/mister/verif_loop.sh` runs the verificator N times and md5-groups the result screens.

## The four media operations, verified on hardware

Driven blind through the OSD with `tools/mister/uinput_kbd.py`, each identified by what Main
logged. The selection wraps, so counting UP from a freshly-opened menu is immune to how many
optional rows sit above:

| UP presses | item | Main logged |
|---|---|---|
| 1 | Exit | (nothing) |
| 2 | **Eject Disc** (R[38]) | `MCD: eject - tray open, core left running` |
| 3 | **Remove Cartridge & Reset** (R[37]) | `MCD: request to reset`, PLL recalculated |
| 4 | **Reset & Eject CD** (R[0]) | `Eject image from 0 slot`, BIOS re-sent |
| 5 | Pause When OSD is Open | (a toggle, nothing logged) |

Screenshots confirm the effects: with the cartridge MGL loaded the machine boots Alien 3, and
18 s after "Remove Cartridge & Reset" it is sitting on the Mega CD BIOS starfield instead.

**All four work.** What made them look broken was two things that had nothing to do with the
options themselves:

1. **stdout buffering.** MiSTer's log is block-buffered when redirected to a file, so the one
   or two lines an eject or a mount writes sat in libc's buffer, invisible, until unrelated
   output pushed them out - which reads exactly like the keypress never arrived. Fixed in the
   fork with `setvbuf(stdout, NULL, _IOLBF, 0)`. I lost time to this; check it first next time
   a MiSTer action "does nothing".
2. **`Disc Insert: Keep Running` masked `status[0]`**, so while it was on the OSD
   "Reset & Eject CD" really did nothing. That option now lives in Main (see below).

Two real bugs did come out of the investigation, both fixed:

- **A cartridge vanished on every disc change.** `rom_cart_mode` was cleared by a BIOS reload,
  and Main re-sends the BIOS on every image mount. A cartridge is physical; it now clears only
  on the explicit OSD removal.
- **Inserting a different game hot-swapped it into the previous game's BIOS and save.** Main's
  `mcd_set_image()` decides "same game" by directory prefix, which is right for a multi-disc
  game in its own folder and wrong for a flat folder of unrelated titles - there every game
  matches every other, so no reset, no BIOS reload, wrong save. The fork gates that test on
  the core's `status[36]`, so the default restarts on every disc change and "Keep Running" is
  opt-in for multi-disc swapping.

## IRQ 0A: /VPA is correct and must stay

Our sub-CPU interrupt acknowledge is terminated with /VPA (`ASIC.vhd:2576-2591`), which makes
the 68000 run its 6800-style E-synchronised autovector cycle - 10 to 19 clocks instead of the
4 the MC68000UM's "Interrupt 44(5/3)" assumes. That is **what the real hardware does**, on
several independent lines of evidence:

- Sega's own maintenance manual pin list for the Mega CD gate array **315-5548 (MCE2,
  MB634120)** gives pin 126 as an *output* VPA, alongside outputs IPL0/1/2 and inputs FC0/FC1,
  and the part has **no VMA and no E pin** - so its VPA output can only exist to autovector
  the interrupt acknowledge (`docs/MCD_MaintenanceManual_Export_RevA.pdf`, section 7-2).
- Sega's factory checker (610-0276) has the error code **"206 VPA SIGNAL ERROR (LEVEL 2
  INTERRUPT)"** - VPA has no role in a level-2 interrupt unless it terminates the IACK.
- **krikzz's own Mega CD FPGA core** - by the author of mcd-verificator - does the same:
  `cpu_vpa <= !cpu_space` with `cpu_space = !cpu_oe & cpu_fc[1:0] == 2'b11`.
- Genesis Plus GX charges 50-59 clocks E-phase dependent; jgenesis charges a constant 54 and
  passes every verificator test; ares charges +10 to +18.

So passing IRQ 0A does not require a 4-clock IACK, and shortening ours would be a fake.
The budget is 52 main clocks = 6779 ns (NTSC) from the arming write at A12000 to the read of
A12026, against roughly 16 (finish the idle-loop CMPI) + 50..59 (exception) + 12 (the ISR's
write) = 78..87 sub clocks = 6.24..6.96 us. Real hardware is itself marginal here, which is
why the subtest flips between OK and 0A rather than always failing. Our own additions measure
about 1.5 sub clocks, so the remaining work is to find the wait states that tip it, not to
change the acknowledge.

Worth noting from jgenesis: their IRQ 09 turned out to be a **main-CPU** speed problem, fixed
by modelling DRAM refresh as stalling the main CPU while it executes out of Sega CD BIOS ROM.

## CDC INIT 03: the sync-insertion interrupt beats the real sector, permanently

Subtest 03 (test function ROM 0x011FEC, check at 0x0120F0) plays from MSF 00:01:73 and then,
up to 200 times, waits for a CDC decoder interrupt and requires HEAD0..3 to read exactly
`00 02 00 01` - the header of LBA 0. LBA 0 passes **once**, so any decoder interrupt whose
header read misses it or tears across the LBA 0/LBA 1 boundary loses the test outright.

There are two sources of that interrupt, and ours are 27 ns apart in the wrong order:

- the CDC's own frame timer, `FRAME_END+1 = 715909` clocks at 53.693175 MHz = **13.333333 ms**
  exactly 75.000000 Hz (`CDC.vhd:466`), which fires `DEC_FRAME` -> sync insertion; and
- the drive's sector stream, handed over every `166667` ticks of the 12.5 MHz enable
  (`ASIC.vhd:942`) = **13.333360 ms**, i.e. 74.99985 Hz.

`FRAME_CNT` is reset by `SECTOR_END`, so each frame restarts together and the CDC timer expires
26.7 ns *before* the sector arrives, every frame. Sync insertion therefore fires on every normal
frame - and `HEAD0..3` is only latched at the end of the sector burst (`CDC.vhd:439-448`), so
the CPU is woken before the header it is about to read exists. Whether it reads the old header,
a torn one, or the right one depends on HPS jitter. That is the shape of the intermittency.

Sync insertion means "no sync pattern found", so its timeout must be *longer* than a normally
arriving sector, not 27 ns shorter. Making the two rates consistent (or the timeout properly
later) is the fix; it is not yet made, because the two constants are region-selected and the
change wants a bench before a build.

## Build 52 on hardware (6 runs, no F2 needed)

The region fix does its job: `VAR TESTS`, `REG 8030`, `CDC REGS` and `CDC FLAGS` are all OK
straight off a normal load, with no force-US hotkey.

| runs | result |
|---|---|
| 3/6 | everything OK except `IRQ TEST 0A` |
| 3/6 | `IRQ TEST 0A` + `CDC INIT 03` |

Timing improved too: **-1.694 @107 MHz (TNS -664)**, up from -2.141 (TNS -889) in build 51,
and +0.121 @53.7 MHz.

### The default BIOS on this machine is European, and that is now visible

Running the verificator from a disc image in `games/MegaCD/local/` produced PAL numbers again -
VAR 23732 ERROR 02, IRQ 227 ERROR 09, REG 8030 1275 ERROR 07. Not a regression: with no
`cd_bios.rom` beside the image, Main falls back to `HomeDir()/boot.rom`, which here resolves to
`cifs/MegaCD/boot.rom`, and that image has **'E' at $1F0**. `games/MegaCD/boot.rom` is a 'U'.

So the region fix is doing exactly its job - the console's video standard follows the BIOS, and
a European BIOS gives a European machine whose main 68000 runs 0.912% slower. The verificator's
VAR 02 / IRQ 09 / REG 8030 07 windows are calibrated for NTSC and legitimately fail on a PAL
console, as they would on a real European Mega CD.

The `MegaCD_verif_disc.mgl` used for testing points at a game folder that has its own
`usa/cd_bios.rom`, which is why it comes up NTSC. To get NTSC anywhere else, either put a US
BIOS at the fallback path or set Region explicitly in the OSD.

### Build 52 baseline for the two intermittents (24 runs)

| test | failures |
|---|---|
| `IRQ TEST 0A` | 24/24 |
| `CDC INIT 03` | 15/24 (62%) |

Everything else OK in all 14. That is the number the CDC sync-insertion fix has to beat.

### The other five interrupt levels still clear on the level (known, not changed)

`ASIC.vhd` acknowledges INT2 on the edge as of 8c933ee, but levels 1, 3, 4, 5 and 6 still clear
`INT_PEND(n)` for as long as `INT_ACK(n)` is asserted:

| level | source set at | clear at |
|---|---|---|
| 1 subcode | `ASIC.vhd:2341` | `ASIC.vhd:2118` |
| 3 Timer W | `ASIC.vhd:1362` | `ASIC.vhd:1340` (also on IEN=0) |
| 4 CDD | `ASIC.vhd:925` | `ASIC.vhd:908` |
| 5 CDC | `ASIC.vhd:1376` | `ASIC.vhd:1374` (also on the CDC_INT_N rising edge) |
| 6 subcode ready | `ASIC.vhd:1324` | `ASIC.vhd:1303` (also on IEN=0) |

Each carries the same defect: `INT_ACK(n)` is decoded combinationally from the acknowledge bus
cycle and stays high for ~11 CLK edges, so a request raised inside that window is set for one
edge and cleared on the next, and the sub CPU never sees it. Unlike INT2 these are raised by
internal events at 75 Hz to a few kHz rather than by the main CPU at will, so a collision is
rare; and unlike INT2 nothing in the verificator exercises them, so a change here would be
untested. Left alone deliberately. If they are fixed, note that levels 3 and 6 clear on **both**
the acknowledge and `IEN(n) = 0`: only the acknowledge half should become an edge.

## IRQ 0A: closed. Our side is at the hardware floor; the rest is the 68000

Measured, not argued. A dedicated bench (`sim/cdc/irq/`) traces one sub-CPU level-2 exception
bus cycle by bus cycle and sweeps the INT2 arrival across 120 sub-CPU clock offsets:

- end to end **5411.4 / 6190.0 / 7097.3 ns** (min / mean / max) against the 6779 ns deadline,
  **9 of 120 offsets miss (7.5%)**. 256 iterations per run, so a miss anywhere fails.
- Worst case decomposes as **2281.9 ns finishing the interrupted instruction** + **996.6 ns of
  interrupt acknowledge** + the fixed exception body. Both dominant terms are 68000 facts.
- The gate array contributes **nothing measurable**: `/VPA` is asserted 0.0 ns after `/AS` in all
  120 acknowledges, `IPL` rises with `INT_PEND(2)`, and DS->DTACK is **9.3 ns (one CLK) on 480 of
  480 writes and 69 of 69 register reads**. The 83.8-102.5 ns AS->DTACK figure that looked like
  gate-array latency is the 68000's own S2->S4 delay: it asserts `/DS` a full CPU clock later on
  a write than on a read, and the decode is strobe-gated (`ASIC.vhd:840, 1404`), so the gate
  array cannot see a write cycle until S4.
- The `PRG_RDY` guard and the `PRS_END` return path, both suspected, **never fired once** in
  1462 cycles.
- No PRG-RAM read took a wait state in 1236 samples.

Two variants were built in a scratch copy and swept: bypassing the MC68K MCLK output register,
and acknowledging a write from `/AS` plus the decode. Both remove **every** write wait state.
Neither closes the gap - 8/120 and 6/120 misses - and bypassing the output register makes the
worst case *worse* (7172 ns). The reason is visible in which offsets fail: taking 240-320 ns out
upstream just moves the timeline into a different E-clock phase, and the `/VPA` acknowledge hands
it straight back. Acknowledge occupancy ranges 586.8-1313.3 ns across the sweep - a 727 ns
lottery that dwarfs everything the gate array does.

**So there is nothing honest left to take.** `/VPA` is what the hardware does (see the evidence
above), the exception sequence is the 68000's, and both of our candidate savings are inside the
noise of the E-phase it introduces. IRQ 0A is a genuinely marginal test: emulators that pass it
do so by charging a *constant* interrupt cost (jgenesis uses 54 clocks) instead of modelling the
E-clock synchronisation that real silicon has.

One real finding did come out of it, and the comment at `MC68K.vhd:150-162` has been corrected:
the MCLK output register is not free. Its 9.3 ns pushes `/DS` from 2 to 3 MCLK into S4, so the
gate array's next CLK edge lands on the CPU's DTACK sample point whenever that half period is the
short one - **403 of 480 writes take a wait state because of it**. It stays regardless, because
removing it makes 0A worse and the 107 -> 53.7 MHz hazard it exists to fix is real.

Next places to look, if anyone returns to this: the derivation of the 52-main-clock deadline
itself (its bus-ordering assumption is worth +-4 clocks, i.e. +-520 ns, which is the whole
argument), and the main-side A12000 write to `INT_PEND(2)` path, which is outside this bench.

## Build 54 on hardware (22 runs): CDC INIT 03 is fixed

| test | build 52 (24 runs) | build 54 (22 runs) |
|---|---|---|
| `CDC INIT 03` | 15/24 (62%) | **0/22** |
| `IRQ TEST 0A` | 24/24 | 21/22 - one run was a **full pass**, IRQ TEST included |

The sync-insertion guard did what the diagnosis said it would. Build 54 also carries the
cartridge-persistence fix, the Disc Insert restructure and the edge-acknowledged INT2.

Timing regressed in that build though - **-2.339 @107 MHz (TNS -1784)** against build 52's
-1.694 (TNS -664), and 53.7 MHz went to **-0.081** having been +0.121. The 107 MHz domain holds
the NukedMD models and nothing here touches it, so that part is fit noise; the 53.7 MHz figure
is not, and is the 11-bit `WORD_CNT /= 0` compare this build put into DECI -> CDC_INT_N ->
INT_PEND(5). Replaced with a one-bit `SECTOR_ACTIVE` flag (58d12d5) and rebuilding.

### Cartridge persistence and the no-disc case, both confirmed on build 54

Loaded the verificator MGL (disc + the verificator as a cartridge), then selected
"Reset & Eject CD" from the OSD. Afterwards:

- **The verificator cartridge is still running.** Under the old logic `mcd_set_image(0, "")`
  re-sent the BIOS, `bios_download` cleared `rom_cart_mode`, and the machine would have come
  back on the Mega CD BIOS with an empty slot. A cartridge is physical; it stays.
- **`CDC INIT` reports ERROR 03**, which is the correct answer with an empty drive - the header
  of LBA 0 never appears because there is no disc. So the sync-insertion guard did not break the
  no-disc path it has to leave alone.
- The run came back PAL (VAR 23732 / IRQ 227 / REG 8030 1275), because `mcd_set_image(0, "")`
  reloads the fallback `cifs/MegaCD/boot.rom`, which is the 'E' BIOS. Also correct.

## Build 56: best 107 MHz timing yet, and where the failing paths actually are

| clock | build 52 | build 54 | build 56 |
|---|---|---|---|
| 107.4 MHz (`counter[0]`) | -1.694, TNS -664 | -2.339, TNS -1784 | **-1.550, TNS -342** |
| 53.7 MHz (`counter[1]`) | +0.121 | -0.081 | -0.340, TNS -0.340 |

`quartus_sta` with `tools/sta_paths.tcl` finally says where the 107 MHz failures are, and it is
**not** anything writable here: every one of the worst 25 is inside a die-derived model -

    ym7101_rtl|io_address[1]  ->  md_board|VD[4]        (the VDP driving the video data bus)
    m68kcpu:P68K|w23~0_OTERM341DUPLICATE -> P68K|w981[1] (the gate-level sub-CPU)

Those are 1:1 conversions of die netlists and are not ours to restructure, so the 107 MHz slack
is a property of running gate-level models at 107 MHz on a Cyclone V, not a bug to fix. It has
been in this range for every build of this configuration.

The 53.7 MHz failure is a **single** endpoint:

    sdram|dout[11]  ->  ASIC|S68K_PRGRAM_DO[11]     -0.340
    sdram|dout[8]   ->  ASIC|M68K_PRGRAM_DO[8]      +0.254   (next worst - a placement outlier)

i.e. the SDRAM read bus into the ASIC's PRG-RAM data register, missing by a third of a
nanosecond while its sibling bits make it comfortably. Placement, not logic. `SECTOR_ACTIVE`
(58d12d5) was still the right shape for the sync-insertion guard - one flip-flop rather than an
11-bit compare in DECI -> CDC_INT_N -> INT_PEND(5) - but it was not what made 53.7 MHz negative.

### Games still run (build 54, after the CDC decoder-interrupt change)

The sync-insertion guard changes when DECI fires, which is the most game-critical path touched
in this session, so: Cobra Command (FMV playing), Final Fight CD and 3 Ninjas Kick Back all boot
and run. Thunder Storm FX comes up on the JP BIOS "press the start button" screen, which is that
BIOS waiting for input rather than a fault.

## Build 56 on hardware: 47 runs, 46 of them byte-identical

46 runs: everything OK except `IRQ TEST 0A`, all with the same md5 - the first 32 consecutively.
This core has never managed that before; it used to jitter between two and four different result
pages in any given session.  The 47th run was a **full pass**, IRQ TEST included.

`CDC INIT` is 0 failures in 69 runs across builds 54 and 56, against a 62% baseline.
`IRQ TEST 0A` passes about 1 run in 25 (1/22 on build 54, 1/47 here).

That determinism is worth as much as the individual fixes: a core whose diagnostic output is
reproducible is one where the next regression will be obvious.

Note on the Thunder Storm FX check: its disc mounts ("CD mounted, last track = 2") and the JP
BIOS runs and animates, but it sits on "press the start button". That is the BIOS waiting for
input, not a fault - the virtual keyboard is not mapped to a joypad on this machine, so Start
cannot be synthesised. If a future session wants to drive games, the uinput device would have
to present itself as a joystick that MiSTer already knows, or a keyboard map would have to be
written into config/inputs.

### One inference worth recording before anyone reopens IRQ 0A

The bench says 9 of 120 E-clock phases miss (7.5%). Hardware says the test fails in roughly 33
of 34 runs. Those two only reconcile if the effective deadline is **lower** than the nominal
6779 ns - low enough that most of our 5411..7097 ns distribution is over it - or if the real
latency is higher than the bench's.

Both are plausible and both point the same way:

- The 52-main-clock deadline rests on an assumption about where the read and write bus cycles
  sit inside their instructions, worth +-4 clocks = +-520 ns. 48 clocks would put it at 6258 ns,
  and then most phases miss.
- The bench drives the arming write directly on the EXT bus, so it excludes the main 68000 ->
  md_board -> MegaCD.sv buffer path (about 47 ns) and models the sub CPU as sitting in the
  dispatcher's idle loop. In the real test each iteration is preceded by an `mcdRD8(0)` mailbox
  round trip, so the sub may still be in the dispatcher's exit path rather than the spin loop
  when IFL2 arrives, which would make the interrupted-instruction term longer than the 16-28
  clocks measured.

So the gap is probably larger than the 320 ns the bench suggests, not smaller - which makes the
conclusion stronger, not weaker: it is not reachable by shaving the gate array, and the honest
next step is to pin the deadline exactly (single-step the main CPU's 6-NOP window in a bench
that models both CPUs) rather than to optimise against a number with 520 ns of slop in it.

## Handover note: what a combined 32X + MD + MCD core is up against

Worth knowing before that project starts, because it decides the approach rather than being
something to discover halfway in.

This core, on its own, on the DE10-Nano's 5CSEBA6:

| | used | available | |
|---|---|---|---|
| ALMs | 36,260 | 41,910 | 87% |
| **M10K blocks** | **519** | **553** | **94%** |
| block memory bits | 4,109,748 | 5,662,720 | 73% |
| DSP | 56 | 112 | 50% |

**M10K count is the binding constraint, not logic and not memory bits.** 34 blocks free, while
only 73% of the bits are used - the die-derived models are full of small, oddly-shaped memories
that each consume a whole block. That is what killed the telemetry build (build 49,
"Can't fit design in device" at 88% ALM / 94% RAM) even though it needed very little.

A 32X adds two SH-2s and a framebuffer. The framebuffer alone is 256 KB - about 205 M10K blocks
if it lives in block RAM, against 34 free. It has to go in SDRAM, and SDRAM on this board is
already carrying the Mega CD PRG-RAM, word RAM, PCM wave RAM, the BIOS and the cartridge, with a
fixed-priority arbiter (`rtl/sdram.sv:147-201`) whose ordering already shows up in the sub-CPU's
worst-case latency.

So the user's own framing - "even if it means accuracy compromises" - is the right one, and the
compromise that buys the most room is specifically **the die-derived NukedMD models**: they are
what makes this core 87%/94% and what puts every one of the worst 25 timing paths where nothing
can be done about them. A behavioural VDP/68000/Z80 would free both the blocks and the 107 MHz
critical path. Nothing else in this tree is close to that in cost.

## An adversarial review of this session's own changes found two regressions

Worth recording as a method as much as a result: after the fixes were on hardware and passing,
a separate reviewer was asked to attack them rather than confirm them. It found two, one of them
demonstrated in simulation.

**1. Sync insertion could latch off for ever** (`CDC.vhd`). `SECTOR_ACTIVE` is set by any accepted
CD word and was cleared only by the last word of a sector, so a stream that stopped part-way left
it set: CD-DA paused off a 1176-word boundary, or a data burst cut short when the drive stopped.
Sync insertion then never fired again and software waiting on DECI would wait for ever - the
opposite of what the guard is for. Bounded by clearing it on `DEC_FRAME`, so it can suppress at
most one insertion and a stalled stream self-heals. Bench: `DECI falling edges = 0 SYNC INSERTION
IS DEAD` became `= 3 ... still alive`.

**2. An auto-loaded cartridge followed you into the next game** (`MegaCD.sv`). "A cartridge is
physical" is right for the OSD "Insert Cartridge" and wrong for `cart.rom` beside a CD image,
which is part of that game's configuration. Load a game whose folder has one, then a game whose
folder has none, and /CART stayed low and the machine booted the previous game's cartridge at
000000. Now the two are tracked separately.

Also confirmed sound by the review, with evidence: the edge-acknowledged INT2 (60 IFL2 pairs
swept across the acknowledge window - 0 lost, 0 double-taken, exactly one `INT_ACK(2)` pulse per
ISR entry), and the region change. It also corrected one of my numbers: the INT2 acknowledge
window is **31-70 CLK (0.6-1.3 us)**, not the ~11 CLK the commit message claimed, so the race
that fix closes was several times wider than stated.

Left alone, with reasons: DBCH's top nibble now reads 0 rather than the upstream core's private
"transfer finished" flag - that flag was never exposed on real silicon and the verificator
requires 0, so the mask stays, but `DBC(15 downto 12)` is now written and never read and could
go. And `region_req` (`MegaCD.sv`) still has no initialiser, so it powers up JP if a core ever
runs without a BIOS being sent.

## IRQ 0A is now fully explained, and the deadline was wrong by 3 clocks

A gate-level bench of the MAIN 68000 (`sim/main68k/`, the same `m68kcpu` `md_board.v` uses, on an
md_board-shaped bus) measured the window instead of assuming it. Nine instructions reproduce
their MC68000UM timings exactly, and the S-state alignment is verified at MCLK2 resolution.

**The 52-clock bus-cycle interval was exactly right** - end of the arming write cycle to start of
the A12026 read cycle is 4 + 24 + 20 + 4 = 52 clocks = 6779.3 ns, and the +-4 clocks of
uncertainty collapses to zero. **But that is not the deadline the gate array sees:**

- it registers the arming write at **S4** (`ASIC.vhd:615`; `M68K_GA_SEL` needs a data strobe and
  on a write /UDS asserts in S4, two clocks before the cycle ends), and
- it snapshots the answer at **S2** of the read (`M68K_REG_DO <= CS(3)`, `ASIC.vhd:757` - one
  clock after that cycle starts, not at the CPU's data latch in S6/S7).

**Deadline = 55 main clocks = 7170.4 ns**, measured end to end through that port. It is robust:
both endpoints are register edges, so any wait state anywhere only lengthens it.

The second error was in the other direction: **the 120-offset sweep was too short.** Latency does
not repeat at lcm(26 sub-clock spin, 10-clock E period) = 130, because the sub clock is itself a
fractional enable (`ASIC.vhd:312-319`, measured 12.483 MHz), so 37 of 40 offsets differ from
offset+130. Over 256 offsets the distribution is 5411.4 / 6262.4 / **7264.9** ns.

| deadline | misses | per-iteration p | P(a 256-iteration run passes) |
|---|---|---|---|
| 6779 ns (assumed) | 34/256 | 13.3% | 1.4e-16 - could never pass |
| **7170.4 ns (measured)** | **4/256** | **1.56%** | **1.8%, about 1 run in 56** |
| observed on hardware | - | 1.37% | 2.9%, 1 run in 34 |

**Those reconcile.** 1.8% predicted against 1 in 34 observed, with 4 events in 256 offsets - the
model needs no further mechanism, and the earlier 7.5%-versus-33-of-34 tension was simply two
errors pointing opposite ways.

The "the sub is still in the dispatcher exit path" hypothesis is **refuted by measurement**: IFL2
arrives 164.6-193.9 sub clocks after STA_BSY clears, i.e. in the 6th to 8th iteration of the
26-clock idle spin, never the exit path, and the 29.3-clock spread exceeds the loop period so the
phase is uniform - which is exactly what the offset sweep models.

### What would actually close it

The gap is now **~95 ns**, not the ~320 ns I estimated from the wrong deadline. And there is one
untested term left, which is a genuine accuracy deviation rather than a micro-optimisation: the
bench's PRG-RAM never stalls, but on the DE10-Nano PRG-RAM shares one SDRAM with the cartridge
slot the main CPU prefetches from every 4 CPU clocks (`MegaCD.sv:995` cart vs `:1013` PRG-RAM,
priority in `rtl/sdram.sv:147-201`). On a real Mega CD, PRG-RAM is dedicated DRAM inside the CD
unit and the cartridge is on the console bus; they never contend. One SDRAM transaction is 65 ns
and refresh is another 65, so that contention is worth up to ~130 ns of sub-CPU latency - the
right order to matter, and removing it moves us toward the hardware rather than away.

It is also a change to the most timing-critical shared module in the design, and it is zero-sum
in bandwidth: the main CPU would wait instead. Worth doing carefully, with the 256-offset sweep
as the measurement, not casually.

### Which build to use

**Build 58** (`090924c` and later) is the one to run. Build 56 is otherwise the best-tested build
of the night - 47 runs, 46 byte-identical - but it carries the sync-insertion latch described
above, so pausing CD-DA off a sector boundary can stop the decoder interrupt until software
rewrites the CDC. Builds 51-56 in `releases/` are kept for the record, not for use.

## IRQ 0A: closed for good. The SDRAM lever was measured and rejected

The remaining idea was to give PRG-RAM priority over the cartridge and BIOS ports in
`rtl/sdram.sv`, on the grounds that on a real Mega CD those are different memories that never
contend. It was modelled properly - a scratch bench whose PRG-RAM model *is* the `sdram.sv`
arbiter (7 clk_ram per transaction, `RFS_CNT = 766` refresh taken ahead of everything, the fixed
priority chain, level requests with rising-edge capture, non-preemption), validated by
reproducing the published baseline byte for byte with the arbiter disabled - and swept over 256
offsets in six configurations against the 7170.4 ns deadline:

| configuration | max | misses |
|---|---|---|
| always-ready PRG model (published baseline) | 7264.9 | 4/256 |
| arbiter, refresh only | 7339.4 | 5/256 |
| arbiter + cartridge contention | 7339.4 | 9/256 |
| **+ PRG-RAM at the top of the chain** | **7432.6** | **11/256** |

**It makes it worse, and the difference is noise anyway.** The control pair settles it: at a
521 ns cartridge period the change reads 9 -> 11 (worse), at 500 ns it reads 8 -> 5 (better).
Same change, opposite sign, only the cartridge phase differs; pooled 17/512 -> 16/512.

The mechanism does work - it halves the wait-stated PRG reads, 2.46% -> 1.17% - and that is
exactly why the result matters: **the misses are not the SDRAM.** Every miss in all six sweeps
has an interrupt acknowledge of 13 sub clocks or more, and the /VPA IACK ranges 7-16 sub clocks
= 561-1282 ns, a **721 ns spread from E-clock phase alone, 7.6x the ~95 ns gap**. In the
always-ready sweep, where no PRG read takes a wait state at all, 4 offsets still miss by up to
94.5 ns. **An infinitely fast PRG-RAM does not pass this test.**

And the change is not free. The main CPU cannot be wait-stated on a cartridge or BIOS read -
`cart_mem_busy` and `MCD_ROM_BUSY` reach data latches, not DTACK, and the FC1004's own DTACK
fires unconditionally at ~121 ns - so a late SDRAM word is not a stall, it is **the wrong word on
VD**, which is the build-4 black-screen failure mode. Worst-case BIOS latency would go 28 -> 35
clk_ram (261 -> 326 ns) against roughly 186-196 ns of measured free margin, on the one path with
no error signal, in a design already near -2 ns at 107 MHz.

So: **rejected on measurement, not on nerves.** IRQ 0A misses because of the 68000's own
E-synchronised /VPA acknowledge, our floor is the 68000's rather than the SDRAM's, and there is
nothing further to do on our side. Anyone reopening this should read this section first.

Two useful side results: a CDC DMA into PRG-RAM cannot starve the main CPU at any priority (it
shares the one `PRSS` request pair and runs at ~10% of SDRAM bandwidth - one write per ~641 ns),
and the IRQ bench's PRG-RAM model is pessimistic by ~28 ns per uncontended read but it does not
matter, because both figures land inside the same sub-CPU clock.

# ============================================================================
# State of the core at the end of the 2026-09-08 session
# ============================================================================

Read this section alone if you read nothing else.

## mcd-verificator

Everything passes except `IRQ TEST 0A`. Build 56 ran 47 times, 46 byte-identical; the 47th
passed everything. Five failures were closed in this session:

| test | what it actually was |
|---|---|
| `VAR 02`, `REG 8030 07`, `IRQ 09` | not CDC bugs at all - the cartridge header was re-regioning the console to PAL, and all three are main-clock / sub-clock ratio measurements |
| `CDC REGS 0B` | DBCH read back 8 bits instead of 4, and a word read of FF8006 returned a stale high byte |
| `CDC FLAGS 32` | an unimplemented CDC register read back 0x00; two tests jointly pin it to 0xFF (open bus) |
| `CDC INIT 03` | the CDC frame timer expired 27 ns before every sector arrived, so sync insertion fired on every normal frame and woke the sub CPU to read a header that had not been latched. 62% failure -> 0 in 69 runs |

`IRQ TEST 0A` is understood completely and is not ours to fix: the deadline is 55 main clocks
(7170.4 ns, measured with a gate-level main-CPU bench), our response is 5411/6262/7265 ns over
256 offsets, 4 miss, and a 256-iteration run therefore passes 1.8% of the time against 1 in 34
observed. The spread is the 68000's own /VPA-terminated interrupt acknowledge - 721 ns of
E-clock phase, 7.6x the ~95 ns gap - and /VPA is confirmed correct for real hardware from Sega's
gate-array pin list, Sega's factory checker, and krikzz's own Mega CD core. A perfect
zero-latency PRG-RAM still misses. Nothing on our side is in the way.

## Media handling

Three of the four OSD operations verified on hardware by what Main logs.  **"Remove Cartridge &
Reset" does not work** and is the top open item - see the correction and the TMSS split further
down; I reported it working earlier in this session and was wrong. Two real bugs fixed: a cartridge
vanished on every disc change (Main re-sends the BIOS on every mount), and inserting a different
game hot-swapped it into the previous game's BIOS and save file, because `same_game` was a
directory-prefix match and most libraries are one flat folder. An adversarial review then caught
two regressions in those very fixes - a sync-insertion latch that could stop the decoder
interrupt for ever, and an auto-loaded `cart.rom` following you into the next game - both fixed.

## Timing and resources

`-1.550 @107 MHz (TNS -342)` at build 56, the best this configuration has had; one endpoint fails
at 53.7 MHz by 0.34 ns. Every one of the worst 25 paths is inside a die-derived model. SEED 4 is
kept - SEED 6 closes the 53.7 MHz path and costs the 107 MHz clock three times over.

The binding resource is **M10K block count**: 519 of 553 for 73% of the bits. That is what a
combined 32X core has to live inside, and what makes the die-level models the expensive choice.

## Where the leverage was

Almost none of tonight's progress came from staring at RTL. It came from being able to measure:
driving the OSD over SSH with a virtual keyboard, running the diagnostic 100+ times and grouping
the results by md5, getting MiSTer's log to actually flush, building Main from source in a
minute, and putting benches on the two 68000s. Three of the five closed failures were diagnosed
before a line of RTL changed, and the two regressions were caught by asking someone to attack the
work rather than confirm it.

# CORRECTION: "Remove Cartridge & Reset" does NOT work, and I said earlier that it did

I reported this verified. It is not. The screenshot I read as the Mega CD BIOS was **Alien 3's
own Sega licence screen** - a starfield with "ALL RIGHTS RESERVED", which is what the Mega CD
BIOS start-up also looks like at a glance. Waiting longer shows the ALIEN 3 title and then
attract-mode gameplay. The user's original report was right.

It fails on **every** build tested, including build 51 with the pre-session logic, so it is not a
regression from this session's cartridge changes - it is the pre-existing bug that was reported.

## What is established, with evidence

| step | evidence |
|---|---|
| the OSD item selected really is `R[37]` | Main traced: `RTRACE bit=37 ex=0 opt=[37],Rem` for 3 UP presses (2 UP gives bit=38, 4 UP gives bit=0) |
| Main transmits bit 37 correctly | `STRACE set [37:37]=1 -> cur_status[4]=20`, then `=0 -> cur_status[4]=00`. Byte 4 bit 5 is status bit 37, and `user_io_status_set` sends the whole `cur_status` with UIO_SET_STATUS2 |
| `hps_io` delivers it | `sys/hps_io.sv:471-478` writes all 128 bits; word 2 (bytes 4-5) lands in `status[47:32]` |
| the core acts on it | `MCD: request to reset` appears in the log **immediately after** the STRACE pair - the core dropped `MCD_RST_N` and sent CDD 0xFF |
| the machine really does reset | after `R[37]` the cartridge game restarts from its boot sequence (title screen ~15 s later), it does not continue |
| **but the cartridge is still mapped** | it boots the cartridge again, not the Mega CD BIOS |
| the clearing path itself works | on build 51, `R[0]` (which also cleared `rom_cart_mode`, via `host_reset` and the BIOS reload) **does** come up on the Mega CD BIOS - confirmed by screenshot |

So `cart_remove` asserts, `reset` fires from it, and `rom_cart_mode <= 0` is driven by that same
wire in the same process - yet the machine comes back with the cartridge mapped.

## Where to look next

The unexplained step is between `rom_cart_mode` and the address map. `/CART` reaches the FC1004
combinationally - `MegaCD.sv:595` `.ext_cart(~rom_cart_mode)` -> `md_board.v:929` `assign CART =
ext_cart` -> `ym6045.v:676` `assign va22_cart = ~(va22_in ^ CART)` - and `va22_cart` gates both
`CE0` (`ym6045.v:659-660`) and `ROM` (`ym6045.v:678-679`), so a change should take effect at once
with no latching at reset. Candidates, in the order I would try them:

1. Put `rom_cart_mode` on the spare `status_menumask` bit (`MegaCD.sv:231` has `1'b0` at bit 1)
   and print `hdmask` from Main. That answers "does the register actually clear" in one build,
   which is the fork in the road - everything above is consistent with it clearing OR not.
2. If it does clear, the fault is downstream: work out what `CE0`/`ROM` do at address 0 for both
   polarities of `CART`, and check `mcd_cart`'s own decode (`MegaCD.sv:948` `.rom_mode(...)`) and
   whether it still drives the bus.
3. If it does not clear, the fault is the pulse: `cart_remove` is a bare level off `status[37]`
   with no edge detect, sampled in `clk_sys` - check it is not being lost against the reset it
   causes.

`R[0]` "Reset & Eject CD" remains a working way to get back to the Mega CD BIOS, on builds up to
56. Note that on build 58 `R[0]` deliberately no longer clears a manually inserted cartridge, so
**on build 58 there is currently no working way to remove one** - which makes fixing `R[37]` the
top open item, ahead of anything else in this file.

## The sync-insertion latch was seen on hardware, not just in simulation

The user reported Thunder Storm FX **frozen** on the machine. It had been left running on build 56,
which carries the `SECTOR_ACTIVE` latch introduced earlier in this session (f6afa27/58d12d5) and
fixed in build 58 (090924c). That is exactly the failure the latch produces: a CD stream that
stops part-way leaves the flag set, sync insertion never fires again, and anything waiting on
DECI or STAT3(VALST) waits for ever.

So the review's simulation finding was not theoretical - it hung a real game on real hardware
within a couple of hours of the build being written. Worth remembering as an argument for the
adversarial review pass, and as a caution about how much a "small, obviously correct" guard can
cost when it has no timeout.

Build 58 re-check: Thunder Storm FX loaded and left alone for three minutes gives three
screenshots with three different md5s, i.e. the BIOS is alive and animating throughout. Note this
only proves the BIOS is running - the JP BIOS waits on "press the start button" and the virtual
keyboard is not mapped to a joypad, so the game itself was not driven. Testing gameplay needs
either a real pad or a uinput device that MiSTer recognises as a joystick.

## "Remove Cartridge & Reset": root-caused

Instrumenting `rom_cart_mode` and a sticky "saw status[37]" flag onto spare `status_menumask`
bits (10 and 11) split the problem in one build. Main reads the whole mask on every menu draw:

    RTRACE bit=37 ... mask=053c (cartmode=1 removeseen=0)     before the OSD selection
    RTRACE bit=37 ... mask=093c (cartmode=0 removeseen=1)     after it

So `status[37]` arrives and `rom_cart_mode` clears exactly as written. Everything from the OSD
row to the register is fine, and the fault is downstream.

**`md_board` drives VD as a wired-OR** (`md_board.v:778-788`), and `mcd_cart`'s `cart_data_en`
was `cart_oe & (cart_cs | data_en)` - gated on /CE0 alone, with no reference to whether a
cartridge is present. With `rom_mode = 0` the module therefore still drove `cart_data` onto the
bus. From power-up that is invisible: `cart_data` is still zero and ORing zero changes nothing,
which is exactly why an empty slot has always booted correctly and why this bug hid. Once a
cartridge has been loaded, `cart_data` holds real cartridge data and corrupts every read the
Mega CD answers - so the machine resets, reads a corrupted vector and comes back up on the
cartridge.

Fixed by gating the /CE0 term: in ROM mode the cartridge owns the cycle, and without one only the
RAM cartridge's own windows (already `~rom_mode`-gated) may drive.

This also explains why it looked verified earlier in the session: with a cartridge inserted the
machine boots the cartridge either way, and Alien 3's own Sega licence screen looks like the
Mega CD BIOS start-up at a glance.

### The IRQ 0A pass rate is build-dependent

| build | full passes |
|---|---|
| 56 | 1 / 47 (2%) |
| 58 | 0 / 14 |
| 59 | 3 / 13 (23%) |

Same RTL in 58 and 59 apart from the menumask instrumentation, so this is placement, not logic -
which is exactly what the E-phase model predicts, because the sub-CPU clock is an enable derived
from a fractional divider and its alignment to the main CPU's loop shifts with timing. Do not read
a good run as a fix, and do not read a build's rate as a property of the RTL.

### ...and the fix was wrong. What is now ruled out

Build 60 carried the `cart_data_en` gating to hardware and the cartridge still boots after
"Remove Cartridge & Reset". So the wired-OR bus was not the mechanism, and 7123029's root-cause
claim was wrong (reverted in 17bffe5). Ruled out so far, each with evidence:

- **the OSD row / Main**: `RTRACE bit=37 ex=0 opt=[37],Rem`, and 2 UP / 4 UP give 38 / 0.
- **the SPI transfer**: `STRACE set [37:37]=1 -> cur_status[4]=20`, and `hps_io.sv:471-478`
  carries all 128 bits.
- **`rom_cart_mode` itself**: instrumented onto the menumask - `cartmode=1` before, `cartmode=0`
  after, with the sticky `removeseen` flag set.
- **the BIOS not being resident**: the load log shows `boot.rom` sent at index 0.0 before the
  cartridge at index 6.0.
- **`mcd_cart` driving the bus with no cartridge**: gating `cart_data_en` on `rom_mode` changed
  nothing.

So the register clears, the map ought to flip, and it does not.

**The lead I would follow next.** `/CART` reaches the decode through
`ym6045.v:676 assign va22_cart = ~(va22_in ^ CART)`, and `va22_cart` gates `CE0`
(`ym6045.v:659-660`) and `ROM` (`ym6045.v:678-679`). But those terms also carry **`dff26_nq`**
(`w168 = ~(w69 | dff26_nq)`, `w173 = w101 | dff26_nq`, `w208 = dff26_nq ? ...`) - a flip-flop
inside the FC1004. If `dff26` latches something at reset, then a short reset may not re-sample it
while the long reset that accompanies a BIOS reload does. That would explain the one asymmetry
left in the data: `R[0]` (reset **and** BIOS reload) reaches the Mega CD BIOS, `R[37]`
(reset only) does not. Note this is a die-derived netlist, so the answer is what the real
FC1004 does - and on real hardware you cannot swap a cartridge without powering off, which may
be the honest reading: cartridge removal is a power-cycle, and the core's reset pulse is not one.

Test it cheaply before changing anything: hold the machine in reset for the same duration a BIOS
download does after `cart_remove`, and see whether the BIOS then comes up.

### TMSS splits the cartridge-removal bug in two

Zero-build test: clear `O[9]` (TMSS) in `config/MegaCD.CFG` and repeat the removal.

| TMSS | cartridge inserted | after "Remove Cartridge & Reset" |
|---|---|---|
| **on** (the user's setting) | Alien 3 boots | **Alien 3 boots again** |
| **off** | Alien 3 boots | **black screen** |

So there are two faults, not one, and `/CART` is not the broken part - with TMSS off the
cartridge really is gone.

1. **With TMSS on, something re-maps the cartridge after the reset.** `dff26`
   (`ym6045.v:639`) is loaded from `vd8`, clocked by `w97` and reset by `sres_syncv_q`, and it
   gates both `CE0` and `ROM` (`ym6045.v:644-657`). That is the TMSS bank bit: reset maps the
   TMSS boot ROM, then the TMSS code writes it to switch. With `boot2.rom` loaded and TMSS
   enabled, that switch is putting the cartridge back regardless of `/CART`.
2. **With TMSS off, removal works but the Mega CD BIOS does not start** - black screen, where a
   cold start with an empty slot boots the BIOS perfectly well. The difference is that
   `rom_cart_mode` went 1 -> 0 with the machine already initialised, and the reset that
   `cart_remove` produces is much shorter than the one a BIOS reload brings with it. That is
   also the one asymmetry that has held all along: `R[0]` resets **and** reloads the BIOS and
   reaches the Mega CD BIOS; `R[37]` only resets and does not.

On real hardware you cannot change a cartridge without powering off, so "removal is a power
cycle" may simply be the honest model, and the fix for (2) is for `cart_remove` to produce the
same full re-initialisation a BIOS load does rather than a short reset pulse. (1) needs the TMSS
path understood first - do not paper over it by disabling TMSS.

The user's `MegaCD.CFG` has been restored to TMSS enabled.

### The TMSS split, re-run cleanly (one keyboard daemon)

Caveat first: eight keyboard daemons and nine virtual keyboards had accumulated on the MiSTer
over the night (every "restart MiSTer, start a daemon" added one and never killed the last), and
a `--send` line goes to whichever daemon reads the FIFO first - including ones whose device
MiSTer never opened. So key-driven hardware results taken in the last few hours carried a silent
failure mode. The tool is now a pidfile singleton (8c239e0). Re-run with exactly one daemon,
one virtual keyboard, and a reset counted in the log after every keypress:

| run | TMSS | reset seen | after "Remove Cartridge & Reset" |
|---|---|---|---|
| 1 | off | yes | **black screen** (1416-byte PNG, md5 05351dcc) |
| 2 | off | yes | **black screen** (identical md5) |
| 3 | on | yes | **Alien 3 boots again** (md5 776f60fd) |

Reproducible. Both faults stand exactly as described above: with TMSS on, the cartridge is
mapped back after the reset; with TMSS off, the cartridge is gone but the Mega CD BIOS does
not start. The user's `MegaCD.CFG` is restored to TMSS enabled.

### Fault 2 is state, not a transient: further short resets do not recover it

Single daemon, TMSS off, cartridge loaded, then a sequence with a reset counted in the log
after each step:

| step | reset seen | screen |
|---|---|---|
| `R[37]` Remove Cartridge & Reset | yes | black (1416 B, md5 05351dcc) |
| F2 - region hotkey, a second short reset, no BIOS reload | yes | black (1191 B, md5 194493b8) |
| `R[37]` again - the same pulse a second time | yes | black (identical md5) |
| `R[0]` Reset & Eject CD - reset **plus** Main re-sending the BIOS | yes | **Mega CD BIOS** (15103 B) |

So it is not "the transition caught something mid-way": the machine sits in a state that any
number of ~13 ms resets leave alone and that only the BIOS download path clears. Whatever that
path re-establishes - the ~100 ms `loading` hold, the download's own side effects (`region_req`
re-sniffed, `ioctl_wr` traffic, the SDRAM write burst), or something Main does around it - is
the thing `cart_remove` is missing. That is exactly the question the static reset audit and the
sim bench are answering.

### CORRECTION: it is ONE fault, not two. After R[37] the 68000 does not run the BIOS

A temporary Main that logs every CDD command settles it. A live Mega CD BIOS polls the drive
about 1000 times per 10 s; a dead 68000 issues only the one CDD 0xFF the core sends on the reset
pulse itself. Counted in a 10 s window after "Remove Cartridge & Reset":

| case | screen | CDD cmds / 10 s | verdict |
|---|---|---|---|
| plain BIOS boot (sanity) | Mega CD BIOS | **1004** | BIOS alive |
| TMSS **on**, after R[37] | Alien 3 title, frozen | **1** | **68000 dead**, stale cartridge VRAM |
| TMSS **off**, after R[37] | black | **1** | **68000 dead**, blank VRAM |
| after R[0] (reset + BIOS reload) | Mega CD BIOS | **1005** | BIOS alive - recovered |

So the "TMSS on maps the cartridge back" reading was wrong: `a1_t5` is the Alien 3 *title screen
held in VRAM*, not a running cartridge. Both outcomes are the same machine - the 68000 is not
executing after `cart_remove`'s reset - and TMSS only changes the leftover picture (the
cartridge's last frame vs black). This also retires the FC1004 dff26 / CE0-ROM-remapping theory
as the *cause*: nothing is fetching at all, so what 000000 decodes to is moot until the CPU runs.

The single question is now fault 2's, and it applies to both TMSS settings: **why does the
68000 not run after the ~13 ms `cart_remove` reset, when a cold boot with an empty slot does, and
when only the ~100 ms BIOS-download reset recovers it?** That is exactly what the reset-state
audit and the sim bench are chasing.

### ROOT CAUSE (diagnosed): a warm-reset ordering race - the 68000 restarts before the MCD

A full reset-tree audit (recorded in the session log) nails it, and corrects two of my premises:
the reset block is clocked at 107 MHz not clk_sys, so `s_reset` is **0.6-0.9 ms** not 4.3 ms; and
**`cart_remove` never asserts `md_reset`** - only `loading` (cold boot / BIOS download) does.

What `cart_remove` actually delivers:
- `btn_reset`, which holds `MCD.RST_N` low for ~9.2-9.5 ms (`MegaCD.sv:831`), and
- through the FC1004 **warm-reset** pin (`WRES`, `md_board.v:953`) only a single **~17 us**
  68000 RESET+HALT pulse, fired at the next FC1004 sampler edge 0-8.55 ms after the OSD press.

So the main 68000 comes out of its 17 us pulse **while `MCD.RST_N` is still low**. It fetches
SSP/PC at 000000 through `/ROM` -> `EXT_ROM_N`, but the ASIC ROM state machine is held in IDLE
(`ROM_CE_N=1`, `M68K_ROM_DTACK_N=1`, `ASIC.vhd:781-784,831`), nothing drives VD
(`exp_data_en=0`, `MegaCD.sv:761`), the arbiter self-acknowledges the cycle and the CPU latches
the recirculated bus-hold value (`md_board.v:778-788`) - i.e. garbage. It runs garbage and is
lost by the time the MCD wakes 1-9 ms later; the sub-CPU stays held because nobody writes A12000.

Cold boot and R[0] go through `loading` -> FC1004 **system** reset (SRES), which arms the
dff57/58 hold that keeps the 68000 in reset until **~13.7 ms**, while `MCD.RST_N` releases at
~9.5 ms - so the MCD is always up >4 ms before the CPU runs. A further short reset (F1/F2/F3,
the keyboard reset) re-runs the identical race, which is why it looks like unrecoverable state.
TMSS only decides what stale VRAM is left on screen.

**Zero-build prediction that distinguishes this from anything cartridge-related:** warm-resetting
a *running empty-slot BIOS* (no cartridge at all) should also black-screen. Testing that now.

Fix candidates, faithful-hardware first:
1. `MegaCD.sv:553 .ext_vres(1'b0)` -> `.ext_vres(btn_reset)`: holds the main 68000 in RESET+HALT
   (`md_board.v:842-843`) for the whole `btn_reset` window, so it cannot restart before
   `MCD.RST_N` releases; also closes the pre-pulse window where the old game runs on with /CART
   already flipped. Minimal, and testable.
2. Make `cart_remove` a full "power cycle": let it drive `md_reset` (`MegaCD.sv:432`) the way
   `loading` does, giving the exact cold-boot ordered reset (work-RAM sweep, mcd_cart reset, SRES,
   MCD-first release). More clearly correct - a cartridge cannot be hot-removed on real hardware,
   so removal *is* a power cycle - and it also fixes fault-1's stale-VRAM cosmetics for free.

### FULLY DIAGNOSED + FIX BUILDING (build 61)

The definitive hardware run (build 59 with rom_cart_mode on menumask bit 10 + a CDD-logging
Main) resolves it:

| step | RTRACE (from Main) | screen | cdd/10s |
|---|---|---|---|
| BIOS + Alien 3 cart loaded | - | Alien 3 running | 0 (cart, expected) |
| R[37] press #1 | `bit=37 mask=053c cartmode=1 removeseen=0` | Alien 3 frame, frozen | 0 |
| R[37] press #2 | `bit=37 mask=093c cartmode=0 removeseen=1` | same frozen frame (identical md5) | 0 |

So `rom_cart_mode` **does** clear to 0, the BIOS **is** resident - and the CD BIOS still does not
run: the screen holds a frozen Alien 3 gameplay frame and the drive is never polled. That kills
both earlier theories (it is neither "the map failed to switch" nor "the reset was too short to
restart the CPU"): the map is correct and a warm reset restarts the CPU fine when the BIOS is
already up (the empty-slot F3 test).

The distinguishing fact is the **frozen VDP image**. `cart_remove` reaches the FC1004 only through
its warm-reset pin (WRES); the FC1004 **system reset (SRES)**, which is what resets the VDP and
the gate-array decode latches, is never asserted (only `loading` -> `md_reset` -> `.ext_reset`
-> SRES does that). So after `cart_remove`: the VDP keeps rendering the cartridge's last frame,
the decode latches keep cartridge-era state, and the main 68000 - given only the ~17 us WRES
pulse while the MCD is still in its btn_reset window - restarts before the MCD and is lost. An
already-running BIOS survives a warm reset (F3) because nothing has to switch or be re-reset.

**Fix (build 61, 45b664e):** drive `md_reset` on the `cart_remove` edge, exactly as `loading`
does, so removal is the full cold-boot reset - SRES, VDP reset, both 68000s, MCD-up-before-CPU.
Faithful because a cartridge cannot be hot-removed on real hardware: removal is a power cycle.
Verifying on hardware next; if it lands on the Mega CD BIOS, a final build drops the menumask
instrumentation.

### CARTRIDGE FIX CONFIRMED ON HARDWARE (build 61)

Build 61 (45b664e: cart_remove drives md_reset - the full power-cycle reset). BIOS + Alien 3 cart
loaded, then "Remove Cartridge & Reset":

| step | screen | cdd/10s |
|---|---|---|
| BIOS + cart | Alien 3 running | 0 (cart) |
| after R[37] | **Mega CD BIOS "PRESS THE START BUTTON"** | **1005 (BIOS alive, drive polling)** |

Fixed. Before (build 60 and earlier) this left a frozen Alien 3 frame with cdd=0; now it lands
cleanly on the Mega CD BIOS. The full reset (SRES -> VDP + FC1004 reset, MCD-up-before-CPU
ordering) is what was missing. Next: fold in the standalone warm-reset OSD item and drop the
menumask instrumentation for the release build.

## Verificator: the jgenesis #105 comparison, and why "all pass" is already met (faithfully)

Three analyses (verificator ROM region-awareness; PAL/region clocking consistency; DRAM-refresh
design) settle the remaining questions.

**1. The ROM does NO region detection; the timing windows are fixed NTSC immediates.**
mcd-verificator V1.02 never reads the VDP PAL bit, $A10001, or the header region byte. VAR 02
[23753..23980], REG 8030 07 [1286..1288] and IRQ 09 [224..226] are single hardcoded constants.
So on a real PAL Mega CD the main 68000 is 0.912% slower and these read out of window: NTSC VAR
~23824 -> PAL ~23648 (below floor), REG8030 ~1287 -> ~1275, IRQ09 ~225 -> ~227. **They cannot
pass in PAL, on this core or on real PAL hardware** - it is a property of the ROM. "Pass on PAL"
therefore means the functional suite (CDC/word-RAM/exact-match IRQ subtests), which is
region-independent and does pass. IRQ 0A is an exact-match handshake (256x require COMSTAT3==2),
region-independent in tolerance though still timing-sensitive; NTSC is the tight case.

**2. PAL region handling is sound and consistent** between the CD side and the NukedMD MD side
(both key off PAL=region[1]); every CD time-base is region-independent, the main:sub ratio is
region-dependent and correct. The historic "PAL never handled properly" overlap was the
cart-re-regioning bug already fixed (region from BIOS, not cart). Only nits remain
(audio_cond.sv:113 hardcodes NTSC for an MD analog-filter CE - inaudible, upstream-consistent).

**3. jgenesis's refresh lever does NOT apply to this core - it would regress it.**
- REF in ym6045.v is bus-derived (M3-gated to dff70 & (dff44 | mreq)), non-periodic, unrouted,
  and WAIT holds the Z80 not the 68000. There is no die "REF->68000" path to honor; inventing one
  is synthetic. On the real board REF drives the DRAM array, not the CPU.
- Real MD 68000 IS stalled by work-DRAM refresh (~2/128, SpritesMind); it vanished here because
  the 64 KB DRAM became BRAM. jgenesis re-added it as 2/172 (below the documented 2/128) to pass
  VAR/IRQ09/REG8030 - because its behavioural CPU ran too fast.
- **This core already passes VAR/IRQ09/REG8030 in NTSC with no stall**, so its main timing is
  already correct. Adding any meaningful stall breaks them: NTSC VAR ~23824 is only 71 above the
  23753 floor; a 1.16% stall drops it ~276 -> ~23548, below the floor. REG8030's window is only
  0.155% wide. So refresh is both a band-aid and a regression here - rejected.

**4. IRQ 0A residual (~95 ns, NTSC) is the /VPA E-synchronised interrupt-acknowledge jitter**
(13-22 sub-clocks vs 4), which is faithful to real hardware (Sega's gate-array pin list, Sega's
factory checker, krikzz's own core all say /VPA). A clean 12.500 MHz sub clock (vs the current
CEGen fractional enable, mean-exact but jittery) might recover ~10 ns directly and some more via
the E clock, but it is a large, risky clock-domain re-architecture (the ASIC runs the sub on
clk_sys enables) for ~4/256 offsets on one test, with uncertain full payoff.

**Verdict:** the gate-level core is MORE faithful than jgenesis's behavioural model and already
passes everything the ROM can pass in NTSC except the one marginal, hardware-borderline IRQ 0A.
jgenesis's "all pass" was NTSC with a behavioural CPU + a sub-documented refresh rate + a
constant ack delay - band-aids this core neither needs (it passes those tests natively) nor may
use (faithful-only), and which would regress VAR here. The remaining lever for 0A is the
clean-sub-clock re-architecture: faithful in principle, large and risky in practice.

## IRQ 0A: root cause is GLUE LOGIC (the shoehorned sub-CPU exposed it) - fix for a later release

A 256-offset decomposition (sim/cdc/irq, scratch clean/frac/noreg copies) settles it. The deadline
is 7170.4 ns (55 main clocks, re-verified). Sweep of the sub INT2->FF8026 response:

| config | sub clock | worst ns | misses/256 |
|---|---|---|---|
| real core (baseline) | 12.5 jittery (CEGen /4) | 7264.9 | 4 |
| **strobes combinational, buses still registered** | 12.5 jittery | 7171.8 | **1** |
| clean 12.5 MHz alone | 12.5 exact | 7340.0 | 6 (worse!) |
| strobes combinational + clean 12.5 MHz | 12.5 exact | 7160.0 | **0** |

Findings:
- **The one avoidable, UNFAITHFUL latency is the MC68K wrapper's MCLK output register on the
  sub-CPU CONTROL STROBES** (`rtl/MCD/MC68K.vhd` output stage). It delays /AS,/DS by 9.3 ns,
  pushing /DS into S4 = an extra write wait state on every sub-CPU write; the exception has 3
  stack writes + the ISR write. Cost ~93 ns. The real board has no such register. This is exactly
  the "shoehorned Nuked 68000 uncovering glue-logic issues" the owner predicted.
- The sub-clock mean is EXACTLY 12.5 MHz (CEGen Bresenham verified over a full period: 50.000000
  MHz enable, 12.500000 MHz edges). The earlier "12.483 MHz" was a finite-window artifact. No
  deficit to fix. A clean (zero-jitter) 12.5 MHz clock ALONE is *worse* (7340 ns) - the jitter is
  net-neutral noise, not a systematic inflation.
- Every other stage is faithful: IPL delivery 0 ns (combinational), the /VPA autovector IACK is a
  genuine 6800 E-sync of 15-16 sub-clocks (must not change), DTACK/PRG timing has no excess.
- Corrects an earlier wrong note: removing the register does NOT make 0A worse - that was a
  120-offset undersampling artifact (compared true-worst 7172 against a 120-sample max of 7097).
  The real 256-sample baseline is 7264.9, so removal is clearly better.

**The faithful fix (later release):** in `rtl/MCD/MC68K.vhd`, drive the sub-CPU control strobes
(/AS,/UDS,/LDS,/RNW,/FC) to the gate array COMBINATIONALLY while keeping the wide address/data
buses registered at MCLK (they are the 107->53.7 MHz timing-closure hazard; the 5 strobe bits are
not). Recovers ~93 ns, 4->1 miss/256 (per-run pass ~1.8% -> ~37%). Full 0/256 additionally needs
a clean 12.5 MHz sub clock (a dedicated 50/100 MHz PLL output -> clean /4 into ASIC.CLK_CNT,
crossing into the clk_sys gate-array domain) - larger and riskier; 0A is genuinely
hardware-marginal (the faithful real board itself only clears the deadline by ~10 ns).

## Build 65 (2026-09-08): WARM reset done right — builds 63/64 approach REJECTED and reverted

Owner rejected the build-63/64 direction ("a hard reset with a ram retention kludge isn't
acceptable") and was right. Those builds made EVERY reset drive `md_reset` (full FC1004 SRES:
VDP + gate array + both 68000s) and then bolted on a `ram_clear` split so a plain reset would
skip the work-RAM sweep. That is a hard reset pretending to be warm.

### What the reset button actually is (verified in the RTL, not assumed)
- `md_board.v`: `SRES = ~ext_reset` (=`~md_reset`), `WRES = ~reset_button` (=`~btn_reset`).
  The 68000 /RESET pin = `~(ym_RESET_pull | m68k_RESET_pull | ext_vres)`.
- `ym6045_rtl.v` (die-derived FC1004 arbiter): WRES is sampled by `dff69` off the ripple counter
  `dff68→dff71→dff72→dff76→dff63→dff52→dff65→dff67→dff74`. So **WRES gives the main 68000 a FIXED
  warm RESET+HALT pulse (~17 us); holding the button longer does NOT lengthen it** — the width is
  set by the FC1004's own counter, and this is die-accurate (must not touch). SRES instead holds
  the whole chain for as long as it is asserted.
- So a real Mega CD front Reset button = a warm ~17 us 68000 pulse. The 68000 restarts into the
  BIOS, which re-inits the CD side (halts/reloads the sub-CPU via A12000). Work RAM survives
  (real DRAM keeps state across the pulse — X-Men's reset-to-continue depends on it).

### Root cause of the CD-game freeze (the real bug, not "duration")
`MCD.RST_N` was `~(md_reset | btn_reset)`. `btn_reset` is asserted ~9.5 ms (until `cnt==31`, the
time the FC1004 needs to detect the warm pulse). So a warm reset held the ENTIRE CD block for
~9.5 ms while the 68000 got only its ~17 us WRES pulse and restarted almost immediately — into a
CD block whose BIOS-ROM-serving state machine was parked. It fetched garbage → freeze. On real
hardware the BIOS ROM is a separate always-readable chip, so the CPU restarts straight into it.
The `MCD.RST_N ← btn_reset` coupling is srg320's synthetic-model integration choice, NOT a
hardware fact.

### The fix (MegaCD.sv, faithful, minimal)
1. `md_reset` fires on `loading` only (cold boot / BIOS or ROM download / cart-SRAM clear) — the
   only full power-on reset. Reverted the build-63/64 "md_reset on every reset edge".
2. Removed the `ram_clear` reg/split; the work-RAM and Z80-C7 clear sweeps ride `md_reset` again,
   so a warm reset preserves RAM *naturally* (no kludge) and cold boot still clears it.
3. `MCD.RST_N = ~md_reset` (was `~(md_reset | btn_reset)`): a warm reset no longer holds the CD
   block, so its BIOS-ROM path stays live and the restarting 68000's first fetch succeeds. Only
   the full power-on reset hardware-resets the block; the BIOS re-inits it on a warm reset, as HW.

Net: `reset = host_reset(R[0]) | cart_remove(R[37]) | buttons[1] | region_set` → warm `btn_reset`;
`loading` → `md_reset`. RAM preserved on all warm resets; VDP not reset on warm (WRES doesn't SRES).

### Must verify on hardware (build 65)
- Cold boot → Mega CD BIOS with drive polling (md_reset/loading path intact).
- **Warm reset of a running CD game (R[1]) → game RESTARTS, no freeze** (this is the primary fix;
  build 62 froze here). Owner also saw garbled-audio-that-cleared on "Reset & Eject CD" (R[0]).
- Cart removal (R[37]) → Mega CD BIOS (was confirmed via md_reset on b61; now goes via the warm
  path + rom_cart_mode=0 + CD block NOT reset — re-confirm it still lands on the BIOS).
- mcd-verificator still 11/12 NTSC (only IRQ 0A, deferred).

## Build 66 (2026-09-08): warm reset REDONE — hold the 68000 (ext_vres), reset the CD block WITH it

Build 65 verified on hardware: the warm-reset FREEZE is gone (Cobra warm reset -> Mega CD BIOS,
alive and animating), BUT it lands on the BIOS "Put a DISC on the CD tray" screen instead of
re-booting the game.  Build 65 fixed the freeze the WRONG way - by decoupling MCD.RST_N from
btn_reset (CD block NOT reset on a warm reset).  That left the core's CDC stale while Main still
reset its CDD (R[1] -> mcd_reset -> need_reset -> cdd.Reset(), which keeps the disc loaded at
CD_STAT_STOP), so the re-run BIOS could not re-detect the disc.  The owner's model was right: the
Mega CD reset line is SHARED, so the CD block must reset too.

**Correct fix (build 66):**
- `MCD.RST_N` back to `~(md_reset | btn_reset)` - a warm reset resets the CD block again, re-syncing
  the CDC with Main's CDD so the BIOS re-detects the disc and re-boots the game.
- **`md_board .ext_vres = btn_reset`** (was tied 0) - holds the main 68000 in RESET+HALT for the
  WHOLE btn_reset window (~9.5 ms) so it is released TOGETHER with the CD block, not after the
  FC1004's fixed ~17 us WRES pulse.  Without this the 68000 restarts into the still-held block's
  parked BIOS-ROM path -> garbage -> the original freeze.  ext_vres feeds only the 68000 RESET/HALT
  in md_board (verified: md_board.v lines 842-843 only), so the VDP and work RAM are untouched - it
  stays a warm reset.  This models the CD unit driving the expansion reset back to the console 68000
  while the CD subsystem re-inits.
- `md_reset` still fires on `loading` only; RAM/Z80 sweeps still ride `md_reset`; RAM preserved on
  every warm reset (X-Men reset-to-continue).

Net warm-reset behaviour expected on build 66: front Reset / OSD Reset (R[1], keep disc) -> BIOS
re-boots the disc (game restarts); no cart + no disc -> BIOS idle screen; cart in (X-Men) -> cart
restarts with work RAM intact; "Reset & Eject CD" (R[0]) -> no-disc BIOS.  No freeze in any case.

Build note: build 65's first Quartus run hit the intermittent quartus_fit Access Violation; 4 wedged
quartus_* zombies (some days old) blocked taskkill/Stop-Process and had to be killed with CIM
Invoke-CimMethod Terminate.  The b65 timing report's only negative slacks (-2.875 / -0.496) are PLL-
internal divclk nodes (vcoph->vco0ph->divclk, in the async clock-group) - the standard altera_pll
artifact, present in the b62 report too; no fabric path fails.

## CORRECTION (2026-09-08 evening): build 66 IS the fix; the Main "disc unmount" chase was wrong

Owner's definitive statement of the required warm-reset behaviour (Mega CD, disc in tray):
> "reset is pressed, the HARDWARE resets, the HPS keeps the disc loaded. That's it."
> The game CAN start automatically - exactly as a real Mega CD boots the disc still in the tray after
> a reset. (Earlier "game shouldn't start from title" meant it must not RESUME mid-game; a fresh boot
> from the disc via the BIOS is correct.)  Mega CD differs from the MegaDrive here: an MD cart
> restarts its game with work RAM intact (X-Men); a Mega CD goes back through the BIOS.

What was actually wrong, in order:
- **Build 65** (MCD.RST_N decoupled from btn_reset so the CD block is NOT reset on a warm reset) fixed
  the freeze but left the BIOS at "Put a DISC on the CD tray": the CD block never re-synced its CDD
  with the drive after the console reset, so the disc was never re-detected. Wrong lever.
- I then spent ~1 h hunting a Main-side "ISO unmount" that does not exist. The Main log proves it:
  between the Cobra load and the reset there is NO `Eject image` and NO empty-drive reset; Main held
  `cdd.loaded=1` throughout. ("Eject image from 0 slot" is printed by the LOAD - mcd_set_image ejects
  the previous image before mounting - not by the reset.)  The agent's proposed patch (skip the full
  `cdd.Reset()` on the core's 0xFF pulse when a disc is loaded, just set STOP) FROZE the BIOS - it
  broke the CDD command/response handshake - and was reverted. Main is back to the release binary
  (md5 7f4bed06); Main source is clean (git checkout). **No Main change is needed for the warm reset.**
- The core sends one `0xFF` CDD-reset to Main per MCD_RST_N falling edge (MegaCD.sv ~1287), and
  MCD_RST_N/ERES_N is pulsed on every 68000 RESET instruction the BIOS executes (ASIC.vhd ~322-342),
  so the `MCD: request to reset` lines are normal BIOS-init traffic (cold boot produces them too and
  boots fine). The full `cdd.Reset()` they trigger keeps the disc (`loaded`/toc untouched, status=STOP).

**Build 66 (compiling 20:44)** = the correct core fix, unchanged from its first description above:
`MCD.RST_N = ~(md_reset | btn_reset)` (CD block resets WITH the console - shared reset - so the CDD
re-syncs and the disc is re-detected) + `md_board .ext_vres = btn_reset` (68000 held in RESET+HALT for
the whole ~9.5 ms window so it is released together with the block and does not restart into a parked
ROM path - the freeze). `md_reset` = loading only; RAM sweeps ride md_reset; work RAM preserved.
Expected on hardware: warm reset of running Cobra -> brief BIOS boot -> Cobra re-boots fresh from the
disc. No freeze, no "insert disc". Cold boot, cart removal (R[37]) and verificator must still pass.

Still open (Main, AFTER build 66 is verified): owner does not want "Disc Insert" (OSD file browser)
to force a machine reset when sitting at the BIOS - mcd_set_image's `if(!same_game){status[0]
pulse; reload BIOS}` should become a faithful tray-close (mirror of mcd_eject's tray-open) so the
running BIOS detects and boots the inserted disc; a genuine different-game change must still get its
correct BIOS/save/cheats. Do NOT touch Main for the warm reset itself.

## RELEASE 2026-09-08 — build 65 core + Main df2f120f (what is verified, what is not)

**Shipped:** `releases/MegaCD_TEST_NukedMD_b65_20260908.rbf` (= `MegaCD_TEST_NukedMD_20260908.rbf`,
md5 88359aef) + `releases/main_mister/MiSTer` (md5 df2f120f).  Core source = build 65 exactly (see
below).  Owner's call: "if it's only this reset shit stopping it just release it."

**Verified on hardware today (b65 + this Main):** cold boot -> BIOS -> Cobra boots; "Remove Cartridge
& Reset" (Alien 3) -> Mega CD BIOS; no warm-reset freeze; mcd-verificator 11/12 NTSC (only IRQ 0A, the
known hardware-marginal one); disc insert via mcd_set_image no longer pulses status[0]/reloads the
BIOS (tray-close semantics) - EXCEPT when the disc's folder ships its own cd_bios.rom that differs from
the running BIOS (the rr-sega-mega-cd library does: three distinct BIOS md5s), which is a genuine
BIOS swap and still resets, as it must.

**Known issue (documented, not fixed): warm reset ("Reset"/front button) with a disc in the drive.**
Landing on the Mega CD BIOS is correct.  From there the BIOS should see the disc still in the tray and
auto-load it (BIOS 1.10) or show "press start" (2.00).  Instead it shows "Put a DISC on the CD tray";
pressing START twice (the BIOS's own tray open/close) then boots the disc normally.  Root cause is
CORE-side, established by CDD command tracing (Main-side printf, since removed):
- Main's drive state at the BIOS's boot PLAY is identical between the working cold boot and the
  failing warm reset (same lba/index/latency/isData; ReadData() reads by LBA with the GPGX pregap
  guard, so header N carries payload N).  Main keeps the disc mounted (`loaded=1`) throughout; there
  is no eject on the reset itself.
- The BIOS reads the TOC correctly after the reset, aborts its first SEEK (normal spin-up sequence,
  same on cold boot), then - unlike the cold path, which retries TOC->SEEK->wait->PAUSE->PLAY - takes
  a preserved-work-RAM shortcut: PAUSE -> PLAY from 00:01:73 without a completed seek.  On real
  hardware that read succeeds; in this core the data the CDC/gate array serve for that sequence fails
  the BIOS's validation, and after ~1.8 s it issues STOP then TRAY_OPEN (op=D) itself.
- It fails identically whether the CD block is hardware-reset on the warm reset (b66) or preserved
  (b65), so the CD-block reset is not the variable.  Two Main-side "fixes" were tried and reverted:
  presenting OPEN or TOC on the reset (both make the BIOS's init reset the sub-system for ever - its
  init tolerates only STOP, and the core re-issues the drive reset on every 68000 RESET instruction);
  a Main-driven door cycle (the BIOS ignores drive-initiated status changes; its new-disc boot is
  entered only by its OWN TRAY_CLOSE command).
- Kept from that work (both correct and harmless): SeekToLBA only carries a running latency over when
  the drive is really moving (PLAY/SEEK/SCAN), so the first SEEK after a reset takes its full seek
  time; and Reset() stays STOP/10 with the reason documented.
- **Next step (next release):** core telemetry of the sub-CPU bus / CDC register writes during a cold
  boot vs a warm reset (MCD_TELEMETRY was compiled out for fit - check headroom first; the design is
  at 84 % ALMs / 519 M10K), to see which CDC/gate-array register or timing the BIOS's shortcut relies
  on that this model gets wrong.  Compare against Genesis Plus GX cdc.c / scd.c register behaviour.

**Reset topology decision (core = build 65):** the console's reset button does NOT reset the CD block.
Genesis Plus GX genesis.c is explicit - "FRES is only asserted on Power ON"; gen_reset() calls
scd_reset(1) only for a hard reset - so the Mega CD hardware survives a warm reset and the BIOS
re-initialises it through the gate-array registers.  `MCD.RST_N = ~md_reset`, `ext_vres = 1'b0`,
`md_reset` on `loading` only, RAM/Z80 clear sweeps on `md_reset` (work RAM preserved on a warm reset).
Build 66 (CD block re-coupled + ext_vres hold) was built and tested, behaves the same on the warm
reset, and is NOT shipped; its rbf is `scratchpad/b66.rbf` (3dd11b7b) if ever needed.

**Main (retrorepair/Main_MiSTer, megacd-nukedmd):** megacd.cpp mcd_set_image = tray-close (no
status[0] pulse, no BIOS reload; per-game cd_bios.rom/cart.rom still load - and reset - only if the
file exists; "CD BIOS not found" warns only if <home>/boot.rom is missing too); megacdd.cpp SeekToLBA
in-flight rule + Reset() comment.  The OSD "Disc Insert: Reset | Keep Running" label is now slightly
misleading (it decides save/cheat swapping, not a machine reset) - CONF_STR rename for a later core.

**Test-method lessons:** the OSD is invisible to screenshots and blind key navigation can silently
drop keys (five UPs left the cursor on "Insert Disk" once); when a result hinges on WHICH item was
selected, have the owner select it, or verify from the log (an R[0] unloads the disc - `ld=0`,
`Eject image` - an R[1] does not).  `uniq -c | head` on a trace can hide the interesting part behind
hundreds of pre-event polls - anchor on the event line first.
