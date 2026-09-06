# Theory & roadmap: one core for Mega Drive + Mega CD + 32X (DE10-Nano)

THEORY ONLY — a separate core from this one. Nothing here is to be implemented against this repo.
Written 2026-09-07. Resource numbers are this project's measured MD+MCD figures plus reasoned 32X
estimates; treat the 32X numbers as order-of-magnitude until a real S32X fit is measured on the device.

## 1. Why this is hard, in one line
Real hardware runs all three at once — the CD32X stack (Genesis + Sega CD + 32X, physically
stacked) is a genuine configuration and a handful of games use it — so a faithful combined core
must instantiate all three simultaneously. The DE10-Nano's Cyclone V SE (41,910 ALMs, 553 M10K,
112 DSP) is the ceiling, and MD+MCD alone already fills ~86% ALM / 94% M10K. There is little room
left, so 32X (two SH-2 + a framebuffer VDP) does not drop in without either heavy optimisation or
a bigger device.

## 2. What the three systems share (the leverage)
The Mega Drive base is common to all three and is instantiated ONCE:
- 68000 main CPU, VDP (ym7101) + PSG, Z80, FM (ym3438), the FC1004 arbiter/I-O, work/VRAM.

Mega CD ADDS (this project's MCD block): a second 68000 (sub-CPU), the ASIC (gate array: CDC,
word-RAM control, PCM DMA, CDD), RF5C164 PCM, CD-DA, 2x128 KB word RAM, the CD drive model (HPS).

32X ADDS: two Hitachi SH-2 (SH7604 @ ~23 MHz), the 32X VDP (a line/frame-buffer blitter with its
own 256 KB framebuffer + palette), 256 KB SDRAM for SH-2 code/data, a PWM sound unit, and the
MD<->32X bus/interrupt glue that overlays the MD VDP output.

So the combined machine = ONE MD base + MCD block + 32X block, with the 32X VDP compositing on top
of (and the MCD feeding graphics/audio into) the shared MD path.

## 3. The resource wall (measured MD+MCD + estimated 32X)
Current MD+MCD (this repo, build ~38, telemetry off):

| Block | ALMs | M10K | DSP |
|---|---|---|---|
| MD base (68000 + VDP/PSG + Z80 + FM + glue) | ~11,000 | ~90 | ~18 |
| MCD block (sub-68000 + ASIC + PCM + CDC + CDDA) | ~8,000 | ~293 | ~7 |
| MiSTer framework (scaler, HPS I/O, audio) | ~7,000 | ~59 | ~33 |
| **MD+MCD total** | **~36,000 / 41,910 (86%)** | **519 / 553 (94%)** | **56 / 112** |

32X block (estimate): two SH-2 die-accurate ~ 8,000-12,000 ALMs; 32X VDP + blitter ~ 3,000-5,000;
framebuffer/SH-RAM if kept in M10K ~ +200 blocks (there aren't 200 spare). Net 32X ~ 11,000-17,000
ALMs and hundreds of M10K it does not have.

=> MD+MCD+32X ~ 47,000-53,000 ALMs vs 41,910, and M10K already at 94%. **Does not fit as-is.**

The M10K wall is as hard as the ALM wall: the combined machine's big RAMs (2x128 KB word RAM,
64 KB VRAM, 256 KB 32X framebuffer, 256 KB SH-2 SDRAM, plus CDC/PCM/Z80/BRAM) exceed 553 M10K by
far unless most of them live in off-chip SDRAM/DDR3.

## 4. Optimisation levers (each trades accuracy or effort for fit)
Ordered by payoff / lowest accuracy cost first:

1. **Push big RAMs to SDRAM/DDR3, not M10K.** This project already puts PCM RAM in SDRAM. The 32X
   framebuffer (256 KB) and SH-2 work RAM (256 KB) and word RAM (256 KB) are the M10K hogs; moving
   them to the board's SDRAM (with the latency-tolerant port pattern already used for PCM/PRG-RAM)
   is the single biggest M10K win and is accuracy-neutral if the access timing is modelled. The
   DE10-Nano has one 32-bit SDRAM (needs the SDRAM module) plus the 1 GB DDR3 shared with the HPS.
   Arbitrating word RAM + framebuffer + SH-2 RAM + PCM + PRG-RAM on the available memory ports is
   the central engineering problem and probably the make-or-break of the whole idea.
2. **Behavioural SH-2 instead of die-accurate.** A cycle-approximate SH-2 (j-core-derived or a
   custom pipelined core) is far smaller than a die/gate model. 32X timing is more forgiving than
   Saturn; a good behavioural SH-2 pair could be ~6,000-8,000 ALMs total. This is the biggest ALM
   lever, at the cost of this project's die-accurate ethos for the SH-2s only (the MD/MCD stay
   die-accurate). NOTE: srg320's S32X uses an SH7604 IP — measuring that core's fit on the
   DE10-Nano is the first data point to get before committing.
3. **Smaller MD/MCD 68000s.** Reverting the two Nuked 68000s (die-accurate, ~3.5-3.9k ALMs each) to
   FX68K (~2k each) frees ~3-4k ALMs but loses the accuracy this project just proved. Only if
   desperate. (The FM collapse this project shipped frees ~170 ALMs — negligible at this scale.)
4. **Share the VDP scan-out / mixer.** The MD VDP and 32X VDP composite into one output; a single
   line buffer + priority mux instead of two full pipelines saves logic. The 32X VDP is a blitter
   over a framebuffer, so it needn't duplicate the MD VDP's sprite/scroll engine.
5. **Behavioural FM (jt12) instead of Nuked ym3438.** ~1k ALMs, 6.5k registers back; accuracy cost.
6. **Clock/area trade:** run the SH-2s from a higher-frequency PLL and time-multiplex shared logic;
   the current core already runs a 107 MHz sampling domain, so multi-rate is established.

Even with 1+2+4, fit on the Cyclone V SE is MARGINAL, not comfortable. Expect to be at 98%+.

## 5. The honest fork in the road
- **Path A — stock DE10-Nano, all-three-at-once, heavily optimised.** Feasible only with behavioural
  SH-2 + framebuffer/word-RAM in SDRAM + shared VDP mixer. Risk: does not fit, or fits with no
  headroom and unstable timing (this project already fights tight slack at 107 MHz with MD+MCD
  alone). A realistic first milestone is MD+32X (behavioural SH-2), which is essentially the existing
  S32X core; adding MCD on top is where it likely breaks the budget.
- **Path B — bigger FPGA (a future MiSTer platform / a larger Cyclone V or successor).** Removes the
  wall; the architecture below ports directly. This is the clean answer if faithful all-three is the
  goal.
- **Path C — mode-selected, not simultaneous.** Load MD+MCD OR MD+32X per game (partial-reconfig or
  separate .rbf), sharing the MD base source. Fits today, but a true CD32X game cannot run. Only
  acceptable if simultaneous CD32X is dropped as a goal.

## 6. Suggested architecture for the combined core (any path)
```
                +-------------------- shared MD base (one instance) --------------------+
   HPS/HDMI --- | 68000  VDP+PSG  Z80  FM   FC1004 arbiter   work/VRAM                  |
                +----+------------------+---------------------+-----------------------+--+
                     | expansion bus    | video/audio          | cart/bus
             +-------v-------+   +-------v---------+   +--------v---------+
             |  MCD block    |   |  video mixer     |   |  32X block       |
             | sub-68000     |   | MD + 32X + MCD   |   | 2x SH-2          |
             | ASIC/CDC/PCM  |   | priority + DAC   |   | 32X VDP+blitter  |
             | word RAM(SDR) |   +------------------+   | PWM, SH-RAM(SDR) |
             +---------------+                          +------------------+
     one SDRAM/DDR3 arbiter serves: word RAM, PCM RAM, PRG-RAM, 32X framebuffer, SH-2 RAM
```
The memory arbiter is the keystone; the video mixer (MD layers under 32X framebuffer priority, MCD
graphics via word RAM into the MD VDP) is the second hard part.

## 7. Phased roadmap (for a NEW core, not this repo)
0. Measure: fit srg320/MiSTer S32X on the DE10-Nano; record its ALM/M10K/DSP. Fit this MD+MCD.
   These two numbers decide whether Path A is even arguable. (Do this before any code.)
1. Factor the shared MD base into a reusable block (this repo's md board is 90% there).
2. Bring up MD+32X on that base (behavioural SH-2 first for the budget), framebuffer in SDRAM.
   Validate against 32X test ROMs / the 240p suite.
3. Attempt MD+MCD+32X: add the MCD block, unify the memory arbiter, unify the video mixer. Fit.
   If it overflows, apply section 4 levers in order until it fits or Path A is abandoned for B/C.
4. Accuracy pass: verificator (MCD), 32X test ROMs, real-game matrix incl. the CD32X titles
   (Corpse Killer, Slam City, Fahrenheit, Night Trap 32X, Supreme Warrior).
5. Only then optimise timing/area for headroom.

## 8. Verdict
A faithful, simultaneous MD+MCD+32X on the stock DE10-Nano is at the edge of possible and probably
requires a behavioural SH-2 and moving every large RAM to SDRAM; even then headroom is near zero and
timing closure (already tight here) gets harder. The clean path is a larger FPGA (Path B). The
pragmatic near-term win is a shared-MD-base core that does MD+MCD and MD+32X as selectable modes
(Path C), with simultaneous CD32X deferred to bigger silicon. First action before any of it: get
the two fit numbers in step 0 — everything else is theory until those exist.

Sources consulted: MiSTer forum threads on a merged Genesis/CD/32X core and on 32X; srg320/32X and
MiSTer-devel/S32X_MiSTer (SH7604 IP, 32X VDP); Saturn-core "chock-full FPGA" optimisation notes;
DE10-Nano Cyclone V SE capacity (41,910 ALMs / 553 M10K / 112 DSP).
