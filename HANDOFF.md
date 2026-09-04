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
