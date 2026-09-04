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
