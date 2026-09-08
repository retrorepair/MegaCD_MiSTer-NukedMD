# Sub-CPU interrupt-latency bench

Measures one MegaCD sub-CPU level-2 exception bus cycle by bus cycle, and sweeps the INT2
arrival across sub-CPU clock offsets so the whole E-clock phase space is covered. Built to
answer whether mcd-verificator's `IRQ TEST 0A` failure is our latency or the 68000's.

    ./compile.sh          # tb_mcd_irq.sv  -> work
    ./run.sh <prglat> <n_offsets> <en50>
    ./compile2.sh         # tb_mcd_irq2.sv -> work2, adds per-cycle DS/DTACK instrumentation
    ./run2.sh ...

It instantiates the real `rtl/MCD` (ASIC + CDC + PCM + the gate-level Nuked 68000) with the
verificator's own sub monitor in PRG-RAM (`prg_bios.hex`, from `../make_prg_bios.py`), drives
the arming write directly on the EXT bus, and times from `INT_PEND(2)` rising to the CLK edge
that loads `CS(3) := 2` - the instant COMSTA3 becomes visible to the main CPU.

What it established (see HANDOFF.md for the full write-up):

- end to end 5411.4 / 6190.0 / 7097.3 ns min/mean/max against a 6779 ns deadline; 9 of 120
  offsets miss;
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
