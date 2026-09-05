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
| 16 | 37,288 (89%) | 519 | | | sub-CPU clock level from the gate array phase counter |
| 17 | 37,309 (89%) | 519 | | | Mega CD at 12.5 MHz (50 MHz enable), timer divider 384, CDC 75 Hz decoder frame |
| 18 | 37,082 (88%) | 519 | -2.37 | -0.91 | direct sub-CPU bus outputs (DTACK window parity with FX68K) |
| 20 | 37,136 (89%) | 519 | | | PRG-RAM read DTACK at SDRAM acceptance: VAR test passes |
| 22 | 37,453 (89%) | 519 | -2.52 | -0.27 | posted PRG-RAM writes + DTACK release fix (read-after-write hazard remained) |
| 24 | 37,580 (90%) | 519 | | | ENABLE back to 1 (CDDA/PCM/CD strobes no longer dropped), 50 MHz enable only on the sub-CPU clock counter, idle-port guard |
| 25 | 37,676 (90%) | 519 | -2.97 | -0.74 | reset multicycle constraints, cartridge mapper on registered inputs |
| 27 | 37,540 (90%) | 519 | -6.15 | -4.29 | seed 1 of the Keep Running / telemetry sources: a poor placement of the same netlist |
| 28 | 37,543 (90%) | 519 | -1.84 | -0.32 | seed 2 of the same sources (seed 3: -2.65 / -0.77) |
| 29 | 37,556 (90%) | 519 | -2.24 | -0.87 | PCM output capture ring, old sub-CPU wrapper (baseline) |
| 30 | 37,653 (90%) | 519 | -1.91 | +0.13 | sub-CPU outputs registered at MCLK (53.7 MHz domain clean), seed 2 (seed 3: -2.45 / -0.43) |
| 31 | 37,843 (90%) | 519 | -2.03 | +0.23 | work RAM write register stage; TNS  -360 ns (was -703); region-independent Mega CD clock; seed 2 (seed 3: -2.19 / -0.68) |
| 32 | 37,846 (90%) | 519 | -1.85 | -0.41 | FF804C font colour byte write (COLOR CALC 05), Keep Running arms 3 s after the first BIOS load; PLACEMENT_EFFORT_MULTIPLIER 4 + ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM gave a bit-identical fit (no effect) |
| 33 | 37,698 (90%) | 519 | -1.84 | -0.09 | build 32 + hang telemetry (CDD command/status counters, last sub-CPU register address); deployed (md5 fc280716) |

The spread between seeds of one netlist is up to 4.3 ns at 107 MHz (build 27 vs 28), so every
candidate is fitted with two or three seeds and the best one is deployed.

## Bring-up numbers from the hardware telemetry

- Main CPU expansion reads: gate array /DTACK 75-84 ns after /AS, data on the bus at 84-93 ns,
  arbiter auto-DTACK at 121 ns, /ASEL at 112 ns (simulation); worst SDRAM-backed read latency
  seen on hardware 29 x 9.3 ns = 270 ns against a fixed 68000 cycle of ~520 ns; late reads: 0.
- Interface register stages (build 14) add 18.6 ns each way.
- Sub-CPU PRG-RAM accesses: ~1.8 M/s while the BIOS idles; cartridge /CE0 reads ~1.3 M/s in
  Alien 3.

## mcd-verificator (krikzz, V1.02, run as a cartridge)

Expected ranges from the test source (jgenesis issue 105). On real hardware (SpritesMind thread
3166, Mask of Destiny) a Sega CD 2 and a Wondermega M1 fail CDC REGS 01 and CDC FLAGS 40: only
the CDX / Multi-Mega / X'Eye CDC (LC8913, 5-bit register index) passes them, so CDC REGS 01 is
the correct Model 1/2 behaviour. The CDC INIT step needs a mounted disc. The VAR, IRQ 09 and
REG 8030 windows were calibrated on a 60 Hz console; a 50 Hz console (real European Model 1,
GPGX issue 408) fails them by the 0.9% clock ratio, and so does this core in PAL since the
Mega CD clock became region independent (build 30).

| Test | Expected | Upstream MegaCD | Build 12 (FX68K sub) | Build 17 | Build 18 | Build 20 | Build 30 NTSC | Build 30 PAL | Build 31 NTSC |
|---|---|---|---|---|---|---|---|---|---|
| COLOR CALC | OK | ERR 05 | ERR 05 | ERR 05 | ERR 05 | ERR 05 | ERR 05 (fix in build 32) | ERR 05 | ERR 05 |
| VAR TESTS (sub-CPU memory loop) | 23753-23980 | 22744 | 22381 | 27906 | 26742 | OK | OK | 23609 (ERR 02) | OK |
| IRQ TEST (128 back-to-back INT2) | 128 handled, 224-226 | 223 (ERR 09) | OK | 106 (ERR 06) | 122 (ERR 06) | ERR 0A (128/128 and 224-226 pass) | ERR 0A | 228 (ERR 09) | ERR 0A |
| REG 8030 (timer vs sub-CPU) | 1286-1288 | 1299 (ERR 07) | OK | OK | OK | OK | OK | 1275 (ERR 07) | OK |
| REG X000/X002/2006/X00C, PROG/WORD RAM, WRAM PMOD | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| CDC REGS | OK on CDX-class CDC only | ERR 01 | ERR 01 | ERR 01 | ERR 01 | ERR 01 | ERR 01 | ERR 01 | ERR 01 |

Builds 12 and earlier ran the Mega CD block at 13.42 MHz (see HANDOFF); from build 17 it runs
at 12.5 MHz, which is why the VAR count rose before the sub-CPU bus path was corrected.
