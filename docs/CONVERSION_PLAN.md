# NukedMD die-level models → synthesis-friendly Verilog, 1:1, one module at a time

## What "1:1" means here

Nothing of nukedmd's logic is replaced. Every gate equation and every storage element of the
die models is kept; only their *representation* changes, from "latches sampled twice per
master clock on a 107 MHz clock, with the chips' internal clocks carried as data" to
"flip-flops on the 53.7 MHz master clock with one enable per internal clock phase". The
result computes the same values at the same master-clock edges, so it can be proven
equivalent module by module by simulation, and it synthesises like ordinary RTL: one clock
domain, no oversampling, half the registers, no combinational paths between latch phases
spanning the 107 MHz period (the source of every failing path in every fit so far).

## How the die models are written today (from ym_lib.v, 68k.v, z80.v)

| Form | Today | 1:1 replacement |
|---|---|---|
| `ym_dlatch_1/2`, `ym_slatch` (transparent latch: `mem <= c1 ? inp : mem` every MCLK) | latch emulated at 2× the master clock | `always @(posedge clk) if (c1_en) mem <= inp;` where `c1_en` is the master-clock enable of that clock phase; outputs read `mem` (closed latch value); where the die reads a latch *while it is open*, the consumer takes `inp` in that phase, written explicitly |
| `ym_sdff` (master-slave pair: `l1 <= val` while clk low, `l2 <= l1` while high) | two registers, two samples | one DFF: `if (clk_rise_en) q <= val;` |
| `ym_rs_trig`, `ym_rs_trig_sync`, `z80_rs_trig_*` (set/reset latches) | evaluated every MCLK | set/reset flip-flop at the master clock; set and reset are logic signals of the same clocks, so a one-master-clock resolution reproduces the die model exactly |
| `ym_sr_bit`, `ym_cnt_bit*`, `ym_delaychain` (shift/counter cells built from the above) | composite | same composition on the converted primitives; counters become `q <= q + 1` under the same enable |
| 68k.v / z80.v inline latches (`always @(posedge MCLK) if (c1) l1 <= ...`, 99 and 44 blocks) | same idea, hand-written | the same block with `c1_en` replacing `c1`, at the master clock |
| The chips' internal clock generators (`mclk_and1`, `dclk`, `hclk1`, CPU `clk1/clk2`, FM `clk1/clk2`) | logic nets sampled at 107 MHz | the same divider logic, but its outputs become *enables* (one master-clock pulse on each edge of the internal clock) that gate the flip-flops above |

A latch whose data input changes while it is open and whose output is consumed in the same
phase is the one construct that needs a human decision (feed-through vs. captured value); the
transformer flags these and they are resolved with the equivalence bench, never guessed.

## Tooling

A transformer script (Python, kept in `tools/`) does the regular part: instance-by-instance
replacement of the ym_lib primitives, inline latch blocks and rs triggers, and generation of
the enable signals from each module's clock generator nets. Its output is committed as
readable Verilog (named signals kept from the netlist, comments carried over), not
regenerated on every build. Irregular constructs are listed by the script and converted by
hand with the bench watching.

## Proof, for every module, before it is committed

1. **A/B equivalence bench** (ModelSim; the `sim_sub` bench is the template): die model and
   converted module instantiated side by side, same stimulus, every output and every named
   storage element compared at every master clock edge; the bench stops at the first
   difference and prints the cycle and the net. Stimulus: recorded bus traces from the MiSTer
   telemetry and board-level simulation covering the verificator's tests for that chip and a
   game boot.
2. **Hardware gates**: mcd-verificator identical or better (build 35 baseline), the 240p test
   suite for anything touching the VDP, the JP BIOS menu 15 minutes with music, three games
   including one PAL. Numbers into STATS.md.
3. The die model stays in the tree behind a define for two further modules so a regression
   bisects in one build.

## Order

| Step | Module | Lines | Primitives | ALMs today | Why here |
|---|---|---|---|---|---|
| 1 | tmss | 139 | 6 | 22 | proves the transformer and the bench on something trivial |
| 2 | ym6046 I/O | 544 | 40 | 300 | small, self-contained, controller ports easy to stimulate |
| 3 | ym6045 arbiter | 879 | 57 | 114 | small but timing-critical (RAS/CAS/DTACK/refresh): the bench must show 68000 bus cycles identical; also documents the refresh behaviour jgenesis needed |
| 4 | ym3438 FM | ~4,500 (11 files) | 191 | 994 ALMs, 6,590 regs | biggest register saving; audio compared sample-exact against the die model |
| 5 | z80cpu | 4,091 | 44 blocks + 183 | 1,067 | inline-latch style, second CPU-type conversion before the 68000 |
| 6 | vram + ym7101 VDP | 115 + 7,367 | 815 | 7,558 ALMs, 12,273 regs | the failing paths; largest and most irregular clocking (dclk/hclk/mclk families); after 1-5 the tooling is mature |
| 7 | m68kcpu (×2) | 6,299 | 99 blocks | ~7,500 | last: its bus timing is what the verificator verifies; the same conversion, proven with the existing sub-CPU bench (DTACK windows 4/8/12) plus the verificator |

Steps 1-5 remove roughly 2,500 ALMs and 8,500 registers and take the FM, Z80 and I/O out of
the 107 MHz domain; step 6 is where the timing headroom comes from; after step 7 the 107 MHz
domain disappears (it exists only for the die models) and the whole core runs at 53.7 MHz.

## Effort (honest, one person, with the bench discipline)

Transformer: about a week. tmss 1 day; I/O 2 days; arbiter 3-4 days; FM 1-2 weeks; Z80 1-2
weeks; VDP 4-6 weeks; 68000 3-4 weeks. Each step is independently useful and shippable.

## Not part of this plan

- Behavioural replacements of any chip. The point is to keep nukedmd's logic exactly.
- Changes to the Mega CD side (already RTL) or Main.
- Any accuracy change without a measurement or a documented reference behind it.

## Precision note on the clock domains (added after scoping the pilot)

The 107 MHz sampling clock exists because the die models represent both phases of the chips'
internal clocks as data. For chips whose internal clocks are slower than the 53.69 MHz master
clock (68000 at MCLK/7, Z80 at MCLK/15, FM at MCLK/7/6, arbiter and I/O strobes) the converted
modules run cleanly at the master clock with enables, and their paths get the full 18.6 ns.
The VDP is different: parts of it clock on both phases of MCLK itself (its pixel/serial logic),
so a phase-to-phase path there has a 9.3 ns budget on the real chip as well. Converting it
1:1 still removes the sampling mux level and the latch pairs from those paths (today's
failures are 6-level paths where the chip has 2-3 gate levels), but those flip-flops keep
clocking on both MCLK edges; the claim "no 107 MHz domain" therefore means "no oversampling",
not "no half-period paths in the VDP". The pilot (tmss) stays on the sampling clock so that
equivalence is exact; the board-wide move to master-clock enables is its own step after all
modules are enable-based, proven at board level with the same A/B method.

## Measured after steps 1-3 (2026-09-06): where the space saving actually is

Like-for-like fit (telemetry off, same seed), die models vs converted tmss+ym6046+ym6045:
ALMs 35,726 -> 35,955 (+229), registers 52,052 -> 52,140 (+88), slack -1.62 -> -2.74 @107
(seed-noise). **These three modules are space-neutral converted, by design.** The reason,
measured not assumed:
- A die latch `mem <= c1?inp:mem` is already ONE register; `if(c1_en) mem<=inp` is also one.
  The mux->clock-enable frees a LUT, not a register, and Quartus was already packing it.
- The register saving that the plan called "half" comes ONLY from collapsing a master-slave
  pair (`ym_sdff` = l1+l2 = 2 regs/bit) into a single edge-triggered flip-flop (1 reg). That
  is valid ONLY where the pair's clock is a genuine internal clock phase. In tmss/ym6046/
  ym6045 the clocks are bus-derived logic nets, so the agents correctly kept two registers
  each -> no saving.
So the space prize is NOT in the glue chips. It is in the pipelined chips whose master-slave
stages run on real internal clock phases and are register-heavy:
- ym3438 FM: 6,590 registers (mostly ym_sr_bit_array / sdff pipelines on the FM sample clock)
- ym7101 VDP: 10,158 registers (pixel/serial pipelines on dclk/hclk phases)
- the two 68000s and the Z80: their microcode-sequencer master-slave stages
Converting those with the single-DFF collapse on their genuine phases is where ALMs and
registers actually drop, AND it removes them from the 107 MHz sampling clock (the timing win).

Revised guidance: keep the glue-chip conversions (they proved the method and the bench harness
and are correct), but do NOT ship them (STAGE1 stays off) until they move to the master clock
too. Prioritise FM and VDP for the space goal; measure each with the single-DFF collapse and
the A/B bench, and only keep the collapse where the bench proves it exact.

## Measured register saving by chip (2026-09-06 pm) — the prize is master-slave-style chips only

Standalone Quartus A&S, Total registers, die vs 1:1 vs collapsed:
| Chip | die | 1:1 (rtl) | collapsed (opt) | saving |
|---|---|---|---|---|
| ym3438 FM | 6,513 | 6,513 | **1,537** | **-4,976 (-76%)** (pending full-bench sign-off) |
| z80cpu | 877 | 877 | 877 | 0 |

Confirmed rule: the collapse only pays where the die model builds storage from the TWO-register
master-slave primitives (ym_sdff / ym_sr_bit / ym7101_dff). The FM is built that way -> 76% cut.
The Z80 uses single-register inline `always @(posedge MCLK) if(cx) l<=...` latches (already one
register each) -> nothing to collapse. By the same style, the two 68000s (inline-latch) are
expected to be ~neutral; the VDP (ym7101_dff master-slave pipelines, 10,158 registers) is
expected to collapse like the FM and is the remaining big prize.

Status of the RTL (all UNCOMMITTED until their A/B bench passes in full):
- ym3438_rtl.v (1:1) + ym3438_opt.v (collapsed): directed bench 0 mismatches; FULL 2-seed 1e6
  validation running. Commit both when clean.
- z80_rtl.v (1:1) validated? bench infra in sim/z80 but no result log yet; z80_opt.v is
  space-neutral (drop it, keep only the 1:1 if wanted). z80_opt_bad.v mutant left in tree -> remove.
- ym7101_rtl.v (1:1 only, Stage 1): bench reached ~35k cycles clean when the agent was cut off;
  needs the full run to sign off, THEN a Stage-2 collapse (ym7101_opt.v) for the real VDP saving.

## FM validation result (2026-09-06 19:50) — 1:1 PROVEN, collapse BROKEN, needs debug
- ym3438_rtl.v (1:1): PASS both seeds, 200,018/200,019 MCLK cycles, FULL storage compare
  (1,999 cells x2/cyc), 0 mismatches. Exact. Committed.
- ym3438_opt.v (collapse): FAIL. Output diverges at cyc=178: MOR_2612 die=001 dut=3c0 (both
  seeds identical). The master-slave -> single-DFF collapse changed behaviour on at least one
  cell feeding the YM2612-mode right output. NOT committed. The 76% register cut (6513->1537) is
  the POTENTIAL saving; it is not valid until every collapsed cell is proven output-exact.
  Debug: diff opt vs rtl to see what collapsed near the ch/op accumulator path; the safe rule
  is to KEEP as two registers any cell whose `val` can change during the phase-low window (only
  cells whose val is a registered slave output of the previous stage are safely collapsible).
  The VDP collapse (in progress) may share this failure mode; hold it to the same output-exact bar.

## Full measured register picture (2026-09-06 20:10) — space prize is concentrated in the FM

Standalone Quartus A&S, Total registers, die / 1:1 / collapsed(opt):
| Chip | die | 1:1 | opt | opt saving | opt validated? |
|---|---|---|---|---|---|
| ym3438 FM   | 6,513 | 6,513 | **3,930** | **-39.7%** (-2,583 FF) | YES — both seeds output-exact, 0 mismatches |
| ym7101 VDP  | 9,970 | 9,970 |  8,892 | ~11% | NO — opt bench exited early; likely same collapse bug |
| z80cpu      |   877 |   877 |    877 |  0% | 1:1 not yet bench-signed-off |
| tmss+ioc+arb| (neutral, glue chips, already committed 1:1) | | | 0% | 1:1 proven |

Key finding: the collapse only pays where a chip's storage is master-slave pairs on a GENUINE
sub-MCLK internal phase AND the pair's input is phase-stable. The FM datapath is that (big win,
once the per-cell collapse rule is correct). The VDP is mostly TWO-phase MCLK pixel/serial logic
that cannot collapse -> only ~11%. The Z80 / 68000s use single-register inline latches -> 0%.
So the realistic core-wide register saving from this whole effort is dominated by the FM: order
~4-5k registers if the FM collapse is fixed to keep only the safely-collapsible cells (final
number pending the fix), plus ~1k from the VDP if its collapse is validated, out of ~52k total.
The 1:1 conversions remain valuable for readability and for moving modules off the 107 MHz
sampling clock later, but they are not themselves a space win.

## Definitive result (2026-09-06 20:45) — the FM is the ONLY real space saving

| Chip | 1:1 proven? | collapse validated? | shippable register saving |
|---|---|---|---|
| ym3438 FM | yes | YES (both seeds output-exact) | **6,513 -> 3,930  (-2,583, -39.7%)** |
| ym7101 VDP | yes (222k cyc, 0 mism, both seeds) | NO — not bit-exact possible | 0 |
| z80cpu | (1:1 not committed) | n/a (nothing to collapse) | 0 |
| tmss / ym6046 / ym6045 | yes (committed) | n/a | 0 |

Why the VDP collapse is impossible (agent-verified): its storage is (a) two-phase pixel/serial
master-slaves that fail the same dead-time way as the FM's phase-varying cells, AND (b)
`ym7101_dff` cells whose die output FEEDS THROUGH the open master latch (`outp = rst?0:(clk?l1:l2)`)
- an edge flip-flop presents that one MCLK late and drops the combinational reset, desyncing the
dot-clock generator at cycle 1. Unlike the FM, there is no large subset of safe shift chains to
collapse, so the net VDP saving is 0. ym7101_opt.v was deleted (non-shippable).

BOTTOM LINE for the space goal: the whole conversion frees ~2,583 registers, all from the FM
(NUKED_RTL_FM), which helps ALM headroom but does not touch the timing bottleneck (VDP both-phase
paths). The 1:1 conversions (tmss/ioc/arb/FM/VDP committed) are correct and readable but
space-neutral; their value is readability and a future move off the 107 MHz sampling clock.
