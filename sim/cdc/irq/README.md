# Sub-CPU interrupt-latency bench

Measures one MegaCD sub-CPU level-2 exception bus cycle by bus cycle, and sweeps the INT2
arrival across sub-CPU clock offsets. Built to answer whether mcd-verificator's `IRQ TEST 0A`
failure is our latency or the 68000's. The sweep is a *sample* of the phase space, not a
complete traversal of it - see the note on sweep length below.

    ./compile.sh          # tb_mcd_irq.sv  -> work
    ./run.sh <prglat> <n_offsets> <en50>
    ./compile2.sh         # tb_mcd_irq2.sv -> work2, adds per-cycle DS/DTACK instrumentation
    ./run2.sh ...

It instantiates the real `rtl/MCD` (ASIC + CDC + PCM + the gate-level Nuked 68000) with the
verificator's own sub monitor in PRG-RAM (`prg_bios.hex`, from `../make_prg_bios.py`), drives
the arming write directly on the EXT bus, and times from `INT_PEND(2)` rising to the CLK edge
that loads `CS(3) := 2` - the instant COMSTA3 becomes visible to the main CPU.

**The deadline is 7170.4 ns, not 6779 ns** (measured in `../../main68k`, 2026-09-08). 6779 ns
is the gap between the arming write's bus cycle and the sample's bus cycle - which is exactly
52 main-CPU clocks, no uncertainty - but it is not the interval that matters. The gate array
sets `INT_PEND(2)` at S4 of the write (its data strobes assert a clock before the cycle ends,
ASIC.vhd:561/615) and snapshots `M68K_REG_DO <= CS(3)` at S2 of the read (ASIC.vhd:757), one
clock after that cycle starts, not at the CPU's data latch in S6/S7. That is 55 main clocks
= 7170.4 ns. `DEADLINE_NS` in tb_mcd_irq2.sv now carries the measured figure.

**The sweep must be longer than 120.** The idle spin the sub is in (`cmpi.w #0,$8010 / beq`,
sub $0222) is 26 sub clocks and the 68000's E clock is 10, but the sub clock is itself EN50/4
with EN50 a fractional 50/53.693 MHz enable (ASIC.vhd:312-319), so the latency does *not*
repeat at lcm(26,10)=130 - 37 of 40 offsets differ from offset+130. The 120-offset sweep was a
sample of a much larger space and simply missed the tail: offsets 125, 127, 204 and 205 all
exceed the real deadline (7246-7265 ns). Sweep 256 or more. (The summary arrays were
`[0:255]`, so a sweep longer than 256 used to print garbage past that; now `[0:1023]`.)

What it established (see HANDOFF.md for the full write-up):

- end to end 5411.4 / 6190.0 / 7097.3 ns min/mean/max over offsets 0-119 (log_base_cs3.txt);
  over 0-255 (log_sweep400.txt, only the first 256 offsets are valid in that run)
  5411.4 / 6262.4 / 7264.9 ns, and 4 of 256 offsets miss the real 7170.4 ns deadline.
  p = 1.56% per iteration, so (1-p)^256 = 1.8% of 256-iteration runs pass - 1 in 56, against
  roughly 1 in 34 observed on the DE10-Nano. The old 6779 ns figure gave 34/256 = 13.3% and a
  pass probability of 1e-16, i.e. it predicted the test could never pass;
- the interrupt acknowledge is /VPA-terminated and occupies 13-22 sub-CPU clocks purely by
  E-clock phase, against 4 for a DTACK cycle;
- the gate array contributes nothing measurable: /VPA at 0.0 ns after /AS, DS->DTACK one CLK on
  480/480 writes and 69/69 register reads, no read wait states in 1236 samples, and the PRG_RDY
  guard and PRS_END return path never fired in 1462 cycles.

**Note on the 50 MHz enable.** It must be generated in the CLK (53.7 MHz) domain, because that
is where the ASIC samples it. Generating it on MCLK loses half the pulses and runs the sub CPU
at 6.28 MHz - which is what the older `../tb_mcd_cdc.sv` did, so any interrupt latency measured
through that bench before 2026-09-08 is about twice too long.

Logs, `work*` libraries and the `rtl_try/` scratch copies are gitignored.
