# Resource and timing statistics

Device: Cyclone V 5CSEBA6U23I7 (DE10-Nano). Quartus Prime 17.0.2 Lite, fitter effort
"AGGRESSIVE PERFORMANCE". Device totals and the entity table are from build 14 (2026-09-04, commit 616d700); the
timing table is from build 15 (commit 32b7afa: 36,965 ALMs, 54,281 registers, 519 M10K). Cyclone V has no "LEs": its logic unit is the ALM (Adaptive Logic Module, two
combinational ALUTs plus four registers); the equivalent-LE view is the ALUT and register
counts.

## Device totals (build 14)

| Resource | Used | Available | |
|---|---|---|---|
| ALMs (logic utilization) | 36,992 | 41,910 | 88% |
| Combinational ALUTs (logic) | 53,200 | | |
| ALUTs used as memory (MLAB) | 512 | | TMSS ROM |
| Dedicated logic registers | 54,201 | | |
| LABs partially or fully used | 4,160 | 4,191 | 99% |
| M10K block RAM | 519 | 553 | 94% |
| Block memory bits | 4,109,748 | 5,662,720 | 73% |
| DSP blocks | 56 | 112 | 50% |
| PLLs | 3 | 6 | |
| Pins | 145 | 314 | |

ALUT breakdown: 690 seven-input, 16,267 six-input, 8,128 five-input, 10,292 four-input,
17,823 three-input-or-smaller functions.

## Where the logic goes (ALMs, build 14 fitter "by entity", totals include children)

| Block | ALMs | Registers | M10K | DSP |
|---|---|---|---|---|
| **emu (the core, everything below)** | **29,783** | **43,495** | **460** | **23** |
| md_board (NukedMD board model) | 13,718 | 23,319 | 70 | 0 |
| &nbsp;&nbsp;fc1004 (VDP + arbiter + I/O + FM + TMSS) | 6,470 | 17,543 | 0 | 0 |
| &nbsp;&nbsp;&nbsp;&nbsp;ym7101 VDP (incl. PSG) | 5,034 | 10,158 | 0 | 0 |
| &nbsp;&nbsp;&nbsp;&nbsp;ym3438 FM | 994 | 6,590 | 0 | 0 |
| &nbsp;&nbsp;&nbsp;&nbsp;ym6046 I/O | 300 | 553 | 0 | 0 |
| &nbsp;&nbsp;&nbsp;&nbsp;ym6045 arbiter | 114 | 201 | 0 | 0 |
| &nbsp;&nbsp;&nbsp;&nbsp;tmss | 22 | 41 | 0 | 0 |
| &nbsp;&nbsp;m68kcpu (Nuked 68000, main) | 3,492 | 2,339 | 14 | 0 |
| &nbsp;&nbsp;vram (64 KB VRAM model, 8 banks) | 2,524 | 2,115 | 56 | 0 |
| &nbsp;&nbsp;z80cpu (Nuked Z80) | 1,067 | 1,200 | 0 | 0 |
| MCD (Mega CD block) | 7,856 | 8,384 | 293 | 5 |
| &nbsp;&nbsp;m68kcpu (Nuked 68000, sub-CPU) | 3,890 | 2,358 | 14 | 0 |
| &nbsp;&nbsp;ASIC (gate array) | 1,745 | 2,493 | 0 | 0 |
| &nbsp;&nbsp;CODES gg (sub-CPU cheat engine) | 1,141 | 1,984 | 0 | 0 |
| &nbsp;&nbsp;PCM (RF5C164) | 509 | 819 | 0 | 3 |
| &nbsp;&nbsp;CDC | 173 | 253 | 0 | 0 |
| &nbsp;&nbsp;pcm_mem (PCM RAM in SDRAM) | 140 | 287 | 0 | 0 |
| &nbsp;&nbsp;CD_DAC (CDDA) | 99 | 175 | 7 | 2 |
| mcd_debug (DDR3 telemetry, test builds only) | 1,246 | 2,551 | 0 | 0 |
| CODES codes_68k (main-CPU cheat engine) | 1,146 | 1,983 | 0 | 0 |
| hps_io | 896 | 1,292 | 0 | 0 |
| mcd_cart (cartridge slot + mappers) | 579 | 625 | 0 | 0 |
| md_io (pads, multitap, keyboard, lightgun) | 527 | 651 | 1 | 0 |
| audio_cond (FM/PSG mix and filters) | 481 | 699 | 0 | 18 |
| sdram (5-port controller) | 199 | 242 | 0 | 0 |
| video_cond | 184 | 408 | 0 | 0 |
| MiSTer framework (ascal scaler etc., outside emu) | ~7,200 | ~10,700 | 59 | 33 |

The two Nuked 68000 instances differ in ALMs only through placement and register
duplication; they are the same netlist.

## Block RAM map (build 14)

| Memory | Size | Mode | M10K |
|---|---|---|---|
| Mega CD word RAM (2 banks) | 256 KB | single port x16 | 256 |
| VRAM (8 banks, row writes) | 64 KB | single port 256x256 (x40 blocks) | 56 |
| 68000 work RAM | 64 KB | true dual port x16 | 64 |
| CDC buffer | 16 KB | true dual port | 16 |
| Nuked 68000 microcode, main | 85 kbit | ROM | 14 |
| Nuked 68000 microcode, sub | 85 kbit | ROM | 14 |
| Z80 RAM | 8 KB | true dual port | 8 |
| Mega CD backup RAM (+ cart EEPROMs) | 8 KB | true dual port | 8 |
| CDDA FIFO | 40 kbit | simple dual port | 7 |
| Scaler line buffers and other framework RAM | | | 59 |
| Saturn keyboard table | | | 1 |
| TMSS boot ROM | 2 KB | MLAB | 0 (512 MLAB cells) |
| PCM wave RAM | 64 KB | in SDRAM | 0 |
| BIOS ROM, PRG-RAM, cartridge ROM/SRAM | | in SDRAM | 0 |

Total 519 of 553. Build 12 and earlier used all 553: the shared RAM wrapper carried an
In-System Memory Content Editor hook (`ENABLE_RUNTIME_MOD=YES`) that forced every single-port
RAM into bidirectional mode (max 16 bits per block), costing 13 blocks per VRAM bank instead
of 7; removing it also deleted the JTAG hub logic.

## Timing (slow 1100 mV 85 C corner, build 15)

| Clock | Period | Worst setup slack | TNS | Equivalent Fmax | Hold |
|---|---|---|---|---|---|
| 107.386 MHz (MCLK2: board model, both 68000s, SDRAM, cartridge) | 9.31 ns | -2.03 ns | -2153 ns | 88.1 MHz | +0.25 ns |
| 53.693 MHz (Mega CD block, audio, video) | 18.62 ns | -0.42 ns | -0.5 ns | 52.5 MHz | +0.25 ns |

In build 15 the 53.7 MHz domain is essentially clean (worst -0.42 ns, TNS -0.5 ns; the last
paths were the cartridge save strobe into the save logic, registered afterwards). Build 14 had
reported -2.47 ns there, all inside the PSG IIR filter, which is a false path: every register in
that module updates only on a 7.056 MHz enable, so those paths really have seven clocks; the SDC
now carries a multicycle constraint for it.

The 107 MHz worst paths (build 15) are all inside the NukedMD VDP (ym7101): its internal clock
gate (mclk_and1) into the sl_hit latches and the cnt_sa_low counters (-2.03), then the VDP DMA
address and the reset fan-out into the VD bus mux (-1.95). These exist in the MegaDrive core too
and depend on placement density; this core fills 99% of the LABs.

Slack history:

| Build | ALMs | M10K | Setup @107 | Setup @53.7 | Note |
|---|---|---|---|---|---|
| 1 | 35,663 (85%) | 553 | -3.38 | -1.75 | first fit, black screen |
| 5 | 36,886 (88%) | 553 | -2.90 | -1.40 | /RAS2 refresh fix, BIOS boots |
| 6 | | 553 | -2.59 | -1.70 | cheat engine data path fix |
| 7 | | 553 | -1.75 | | /RAS2 window decode |
| 10 | 36,398 (87%) | 553 | -2.03 | -0.93 | VDP DMA select, cartridge slot |
| 11 | 36,060 (86%) | 553 | -2.68 | -1.90 | cartridge SRAM clear fix |
| 12 | 37,158 (89%) | 553 | -2.68 | -1.90 | TMSS (MLAB ROM) |
| 13 | 36,502 (87%) | 519 | -1.92 | -2.32 | Nuked 68000 sub-CPU, RAM hook removed |
| 14 | 36,992 (88%) | 519 | -2.22 | -2.47* | registered MCD interface (*false PSG paths) |
| 15 | 36,965 (88%) | 519 | -2.03 | -0.42 | registered sub-CPU outputs, PSG multicycle; 53.7 MHz TNS -0.5 ns |

## Bring-up numbers from the hardware telemetry

- Main CPU expansion reads: gate array /DTACK 75-84 ns after /AS, data on the bus at 84-93 ns,
  arbiter auto-DTACK at 121 ns, /ASEL at 112 ns (simulation); worst SDRAM-backed read latency
  seen on hardware 29 x 9.3 ns = 270 ns against a fixed 68000 cycle of ~520 ns; late reads: 0.
- Interface register stages (build 14) add 18.6 ns each way.
- Sub-CPU PRG-RAM accesses: ~1.8 M/s while the BIOS idles; cartridge /CE0 reads ~1.3 M/s in
  Alien 3.
