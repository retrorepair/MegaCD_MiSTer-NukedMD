# NukedMD die-level models → RTL, one module at a time

Why: the die-level models (netlists of latch primitives from `ym_lib.v`, evaluated on a 107 MHz
sampling clock, two samples per 53.7 MHz master clock) are about half the core, force the
107 MHz domain, and hold every failing timing path of every fit (VDP address decode → bus mux,
-1.8 to -2.2 ns at the slow corner, structural, not congestion). RTL modules run at the master
clock, use a fraction of the registers, and can be read. The accuracy the die models bought
(cycle-exact bus behaviour, verified by the mcd-verificator) must survive each step, so every
module is replaced behind an equivalence bench before it is committed.

## Inventory (fitter "by entity", test build; lines from the source files)

| Module | File(s) | Lines | ALMs | Registers | Notes |
|---|---|---|---|---|---|
| ym7101 VDP (+PSG) | ym7101.v | 7,367 | 5,034 | 10,158 | the hard one; all failing paths live here |
| m68kcpu ×2 (main, Mega CD sub) | 68k.v (+ucode/nanocode ROMs, 14 M10K each) | 6,299 | 3,500 + 4,000 | 2,340 + 2,360 | die model gives the verified bus timing |
| vram | vram.v | 115 | 2,524 | 2,115 | DRAM (serial access) model for the VDP; 56 M10K |
| z80cpu | z80.v | 4,091 | 1,067 | 1,200 | |
| ym3438 FM | ym3438*.v (11 files) | ~4,500 | 994 | 6,590 | registers = FM pipeline shift registers |
| ym6046 I/O | ym6046.v | 544 | 300 | 553 | pads, controller ports |
| ym6045 arbiter | ym6045.v | 879 | 114 | 201 | bus arbiter, refresh |
| tmss | tmss.v | 139 | 22 | 41 | |
| md_board | md_board.v | 947 | glue | | already modified once (expansion connector) |
| fc1004 | fc1004.v | 681 | wrapper | | instantiates VDP, arbiter, I/O, FM, TMSS |

Mega CD side (VHDL, already RTL): gate array 1,750 ALMs, PCM 505, CDC 197, sub-CPU cheat
engine 1,147, main cheat engine 1,131; framework ~7,200.

## Method for every module (no exceptions)

1. **Interface freeze.** The RTL module keeps the die model's port list and its cycle
   behaviour at those ports (what the rest of the board sees), not its internal structure.
   Where the die model changes an output on the second 107 MHz sample of a master clock, the
   RTL module registers it at the master clock edge that produces the same value by the time
   any consumer samples it; each such case is written down.
2. **Equivalence bench (ModelSim, scratchpad `sim_*`, pattern of `sim_sub`).** Both versions
   are driven by the same recorded stimulus (bus traces from the MiSTer telemetry or from a
   board-level simulation) and every output is compared per master clock; the bench fails on
   the first difference and prints the cycle. Stimulus must cover the verificator's tests for
   that chip and at least one game's boot.
3. **Hardware gates before commit:** mcd-verificator identical or better (NTSC: VAR OK,
   REG 8030 OK, IRQ 0A, COLOR CALC OK from build 35), 240p test suite for the VDP, the JP BIOS
   menu 15 minutes with music, three games (one PAL). Timing and ALM numbers into STATS.md.
4. One module per pull; the die model stays in the tree behind a define until two modules
   later, so any regression can be bisected in one build.

## Order (lowest risk and most learning first)

1. **tmss** (139 lines): trivial; establishes the bench harness and the interface-freeze
   discipline. Half a day.
2. **ym6045 arbiter** (879 lines): small, but it drives RAS/CAS/DTACK/refresh timing that the
   verificator's VAR test and the sub-CPU handshakes depend on; the bench must reproduce the
   68000 bus cycles exactly. Two to three days. This is also where the refresh-stall behaviour
   jgenesis needed (2 of 172 mclk) is visible and documentable.
3. **ym6046 I/O** (544 lines): controller ports, Z80 bus request/reset, version register.
   One to two days.
4. **z80cpu** (4,091 lines, 1,067 ALMs): a behavioural cycle-accurate Z80 already exists in
   the MiSTer ecosystem (T80 with cycle timing); the bench compares against the die model on
   the sound-driver workloads. Two to four days, mostly validation.
5. **ym3438 FM** (994 ALMs, 6,590 registers): the biggest register saving. Candidate: jt12
   (behavioural YM2612/YM3438, used by other MiSTer cores) behind the same port list, with the
   die model's register-write timing and the "FM chip" OSD selection preserved. Validation is
   audio-level (bit-exact per sample against the die model on recorded register streams).
   One to two weeks.
6. **vram + ym7101 VDP** (7,558 ALMs, 12,273 registers): only after 1-5, with the 107 MHz
   domain then holding just the VDP and the CPUs. This is a new VDP implementation validated
   against the die model, not an edit; several weeks. Decide then whether the payoff (timing
   headroom, readability) justifies it, or whether the die-model VDP stays as the one
   remaining netlist.
7. **m68kcpu** stays as the die model for both CPUs. The verificator's timing tests pass
   because of it; a behavioural replacement would have to prove the same bus timing first.
   Revisit only if the sizes after 1-6 still do not fit the release shape with headroom.

## What each step is expected to give

Steps 1-5 remove roughly 2,500 ALMs and 8,500 registers and take the FM, Z80 and I/O out of
the 107 MHz sampling domain (they move to 53.7 MHz), which shortens the fitter's job on the
VDP paths as a side effect. They do not touch the paths that fail today; step 6 does.

## Not part of this plan

- Changing the Mega CD side (already RTL) or Main.
- Any accuracy change without a hardware measurement or a documented reference (jgenesis,
  GPGX, SpritesMind) behind it, as in HANDOFF.md.
