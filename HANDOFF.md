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
