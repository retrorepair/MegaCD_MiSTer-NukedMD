# PCM DMA deadlock in `rtl/MCD/ASIC.vhd` — `PCM_HALT_WAIT` is never reset

A CDC→PCM DMA (`DD = "100"`) deadlocks in simulation: the PCM bus-steal handshake
never completes, so the sub-CPU is left permanently halted.

**This does not affect real hardware** — on the FPGA the register powers up to 0 and
the handshake works, which is why PCM DMA is fine in games. It makes the design
unsimulatable, and it relies on power-up state rather than reset.

## Cause

`PCM_HALT_WAIT` is declared with no initialiser and is the only signal in its process
missing from the reset branch:

```vhdl
signal PCM_HALT_WAIT : unsigned(1 downto 0);          -- no initialiser
...
if RST_N = '0' then
    S68K_PCM_DTACK_N <= '1';
    PCMA             <= PCMA_IDLE;
    PCM_DMA_ADDR     <= (others => '0');
    PCM_DMA_DO       <= (others => '0');
    PCM_DMA_WR       <= '0';
    PCM_DMA_RUN      <= '0';
    PCM_S68K_HALT    <= '0';
    -- PCM_HALT_WAIT is not reset
```

It is then used as a 2-cycle delay counter in the PCM DMA bus-steal handshake:

```vhdl
when PCMA_DMA_HALT2 =>
    if S68K_AS_N = '1' and CLK_12M_R = '1' then
        PCM_HALT_WAIT <= PCM_HALT_WAIT + 1;
        if PCM_HALT_WAIT = 1 then        -- never true while it is 'U'
            PCM_HALT_WAIT <= "00";
            PCM_S68K_HALT <= '0';        -- ... so the sub-CPU is never released
            PCM_DMA_WR    <= '1';
            PCMA          <= PCMA_DMA_WRITE;
        end if;
    end if;
```

`'U' + 1` is `'U'`, so `PCM_HALT_WAIT = 1` is never true: `PCMA` can never leave
`PCMA_DMA_HALT2`, `PCM_S68K_HALT` stays asserted and the sub-CPU stays halted
forever. `PCMA_DMA_WRITE` uses the same counter and has the same problem.

The simulator flags it directly — the run emits hundreds of
`NUMERIC_STD."=": metavalue detected, returning FALSE` warnings from
`/tb_pcm_halt_wait/asic`.

## Reproducing

Needs only `ASIC_PKG.vhd`, `ASIC.vhd` and `CDC.vhd` — no vendor IP, no BIOS, no CD image.
Runs in about a second.

```
cd sim/pcm_halt_wait
./run.sh            # rtl/MCD/ASIC.vhd exactly as it is in your tree
./run.sh patched    # same, with the one-line fix applied to a temporary copy
./run.sh nofix      # force the bug even on an already-fixed tree
```

The bench programmes a 64-byte CDC→PCM transfer (`FF8004 = 0x04`, `DBC`/`DAC` via the
CDC registers, then DTTRG) and issues harmless sub-CPU register reads so `S68K_AS_N`
keeps toggling, which is what the bus-steal handshake needs. It counts the bytes the
DMA actually writes to PCM.

### Before

```
PCM_HALT_WAIT after reset = xx   (xx/UU => bug present)
(for reference PCM_DMA_RUN=0 PCM_S68K_HALT=0 PCMA=0 - all reset correctly)
transfer of 64 bytes triggered (DD=4 PCM)
---------------------------------------------------------
PCM bytes written : 9 of 64
PCMA              : 3   (3 = PCMA_DMA_HALT2)
PCM_HALT_WAIT     : xx
PCM_S68K_HALT     : 1   (1 = sub-CPU still halted)
S68K_HALT_N       : 0
RESULT: *** DEADLOCK ***
Errors: 0, Warnings: 465
```

### After

```
PCM_HALT_WAIT after reset = 00
transfer of 64 bytes triggered (DD=4 PCM)
---------------------------------------------------------
PCM bytes written : 64 of 64
PCMA              : 4
PCM_HALT_WAIT     : 00
PCM_S68K_HALT     : 0
RESULT: PASS - the PCM DMA completed.
Errors: 0, Warnings: 0
```

## Fix

`0001-asic-reset-pcm-halt-wait.patch` — reset it like every other signal in the process.
Verified to apply cleanly to an unmodified upstream `rtl/MCD/ASIC.vhd`.

```diff
 			PCM_DMA_WR <= '0';
 			PCM_DMA_RUN <= '0';
 			PCM_S68K_HALT <= '0';
+			PCM_HALT_WAIT <= (others => '0');
 		elsif rising_edge(CLK) then
```

No behavioural change on silicon: the register already powers up to 0 there.
