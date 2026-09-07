# 107 MHz timing on the NukedMD core — analysis and why there is no SDC "fix"

Written 2026-09-07 (multi-agent analysis + adversarial verification, all facts re-checked in-repo).

## The problem
The NukedMD die models run at MCLK = **107.386 MHz = 2× the real MegaDrive master 53.693175 MHz**
(rtl/pll/pll_0002.v). Worst setup slack sits at **−1.97 to −2.51 ns on the 107 MHz clock** (PLL
counter[0], period 9.313 ns); the 53.69 MHz clock (counter[1]) is nearly closed (~−0.1 to −0.5).
Only the 107 MHz domain fails, and it has on every build.

Nearly all of the worst ~40 paths share **one source**: `ym7101_rtl:vdp|io_address[1]` (and `[0]`),
the VDP's captured CPU/Z80 I-O bus address, fanning out through a large address-decode + read-data
mux to **`md_board|VD[7]`** (8 paths, the CPU/bus data register) and **`sdram|data[N]`** (32 paths,
the SDRAM write-data register). Data delay is **~10.8–11.0 ns** against the 9.313 ns period — this is
combinational **depth**, not merely fanout. A few more paths launch from `md_board|_M3`.

## Why NO set_multicycle_path / set_false_path on the binding path is faithful
The tempting fix — "a 68000 bus cycle is many master clocks, so relax io_address→data to N cycles" —
is **UNSAFE** and was rejected after adversarial verification:

- **`io_address`** (ym7101_rtl.v ~11341) re-registers **every** 107 MHz edge with **no clock enable**
  (`io_address <= io_address_t`, where `io_address_t = pull ? val : io_address` is a load/hold).
- **`VD`** (md_board.v ~782) also free-runs **every** edge with **no enable** and is consumed
  **combinationally every cycle** (`m68k_bus_do = VD`, `ram_68k_data = VD`, `cart_data_wr = VD`).
- NukedMD runs the die at 2× the master **precisely so each edge is a genuine sub-master-cycle
  sample**; adjacent edges legitimately carry different states. The phase edges align to internally
  divided clocks (VCLK/EDCLK) that are **not declared to Quartus**, so there is **no SDC-visible /N
  grid** to scope a multicycle to. Both launch and capture free-run → the path is genuinely single-
  107 MHz-cycle in the model.
- A wrong SDC exception here is a **silent silicon failure that simulation cannot catch** (sim
  ignores SDC). Faithfulness forbids it.

The `io_address→sdram_data` variant is more defensible (the CPU holds io_address across an access)
but still UNSAFE: the DMA/read/arbitration corners are unproven, the sdram capture-enable (wr0/rd0)
is itself combinational from the same free-running io_address (no register separates data from
strobe), the sdram `data` reg is a shared 5-port register loaded on read *and* write requests, and
it would not touch the binding VD path anyway (worst slack stays ~−2.5 ns). Redirecting the
exception to the genuinely handshake-gated captures (the 68000's DTACK-gated read latch; the SDRAM
request accept) does not help either — those sit **behind** intervening register stages (VD, and an
extra m68k_data reg), and a timing path contains no register between its endpoints, so such an
exception constrains a different segment and gives zero relief to the failing cones.

The **only** provably-safe exception is on **`_M3`**, a boot constant (`M3` tied to `1'b1`,
MegaCD.sv:592; `_M3 <= M3`, no reset/enable → one power-on 0→1 transition, pinned to 1 forever).
Cutting its paths is faithful but **non-binding** (~0 ns on the worst path); it is report cleanup.
Applied in MegaCD.sdc as `set_false_path -from {*md_board*|_M3}` (a `-setup 3 -hold 2` multicycle,
matching the md_reset/sys_reset house style already in the file, is equally faithful).

## What IS safe: correctness-preserving fitter/synthesis levers (Quartus guarantees equivalence)
Applied 2026-09-07 (MegaCD.qsf), keeping SEED locked so gains are attributable:
- **MAX_FANOUT 16 on `io_address[0]`/`[1]`** — forces the fitter to duplicate the 1-source→~40-
  endpoint register and place each copy by its slice of the decode cone (shortens the worst first
  hop). Register duplication (identical D, same clock, no CE) is functionally equivalent.
- **Removed `PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA`** — an area-biased pass competing with the
  speed combo pass in a speed build.
- **ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM + PLACEMENT_EFFORT_MULTIPLIER 4 + ROUTER_EFFORT_
  MULTIPLIER 4** — more placer/router effort biased to critical-connection delay.
- Already on: PHYSICAL_SYNTHESIS_REGISTER_RETIMING, OPTIMIZATION_TECHNIQUE SPEED, MUX_RESTRUCTURE,
  ROUTER_REGISTER_DUPLICATION, FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION, etc. (retiming cannot
  reduce this path's depth because io_address and VD are self-holding — feedback blocks retiming.)
- Then a **SEED sweep** (functional-equivalence guaranteed): the single most reliable lever; per-
  seed worst-slack variance here is ~0.4–1.2 ns (we have seen −1.97 to −2.51 for the same netlist).
- Not yet tried (each a separate compile, verify Lite 17.0.2 honors it via the Fitter *Ignored
  Assignments* report): OPTIMIZATION_MODE "SUPERIOR PERFORMANCE WITH MAXIMUM PLACEMENT EFFORT"; a
  **floating, auto-size, soft** LogicLock region over vdp + VD + sdram|data (medium regression risk —
  keep only if worst slack improves and counter[1] does not go negative).

Honest expectation: these do **not** add linearly; realistic stacked recovery ≈ **1–1.8 ns** — a
**partial** close from ~−2.0/−2.5 ns, not a full one.

## The fundamental limit (a human decision, never an SDC trick)
Closing ~11 ns of combinational **depth** into a 9.313 ns period fundamentally needs either **reduced
logic depth (RTL pipelining — a behaviour change, out of scope for a faithful die model)** or a
**lower clock** (architectural). Since no valid SDC exception exists, if the fitter levers fall short
the remaining choice is an RTL/clock decision for the maintainer. Note the core has always run at
negative 107 MHz slack and works with occasional marginal-timing audio artefacts; the levers above
reduce, but do not eliminate, that marginality.
