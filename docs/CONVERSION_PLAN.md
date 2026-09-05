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
