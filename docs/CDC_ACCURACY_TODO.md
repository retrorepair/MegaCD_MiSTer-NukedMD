# Remaining CDC verificator failures (build 36) — root causes and fixes

Build 36 runs the verificator to completion. Three CDC tests still fail; error codes mapped to
the verificator source (scratchpad/verificator/test_cdc_new.c) and the RTL (rtl/MCD/ASIC.vhd
DMA/EDT/DSR machine, rtl/MCD/CDC.vhd transfer machine). Not blockers; batch into one build.

## 1. CDC DMA3 error 01 AND CDC FLAGS error 05 — same cause: EDT must be a LATCHED flag
- DMA3 err01 (test line 579): after `cdcDmaSetup(CDC_DST_MAIN,...)` but BEFORE DTTRG, reading
  A12004 high byte must be 0x02 (EDT=0, DSR=0, DD=2). Our core returns EDT=1.
- FLAGS err05 (test ~line 1064): comment "only reg $FF8004 can reset EDT flag". After a
  transfer sets EDT, writing IFCTRL=0 and CDC RST does NOT clear it (err03/04 expect EDT still
  set); only a write to FF8004 clears it (err05 expects EDT=0 after that write).
- Cause: in ASIC.vhd the DMA machine `DS_IDLE` forces `EDT <= '1'` whenever `CDC_DTEN_N = '1'`
  (i.e. whenever the CDC is not actively transferring). So EDT is a live reflection of "not
  transferring", not a latched end-of-transfer flag.
- Fix: make EDT a latch. Set EDT='1' only at the moment a transfer completes (the DS machine's
  end state, when the last word has been moved / DTEN drops). Clear EDT='0' ONLY on
  `DMA_ADDR_SET` (a write to FF8004 DD or FF800A). Remove the unconditional `EDT <= '1'` in
  DS_IDLE. Re-verify CDC INIT / DMA1 still pass and games still boot (the DS machine feeds the
  gate-array DMA to word/PRG/PCM RAM, so this must not change transfer behaviour, only the flag).

## 2. CDC DMA2 error 05 — odd DMA length rounds down, off-by-one at one boundary
- Test: DMA to word RAM with DBC = (SECTOR-2)-1 = 2349 (odd) transfers 2348 bytes -> PASS
  (err04 not hit). DBC = (SECTOR-2)+1 = 2351 (odd) must transfer 2350 bytes -> our core gets a
  different count -> err05. Both odd lengths should transfer (len rounded down to even).
- Cause: CDC.vhd TS_SEND decrements `DBC(11 downto 0)` per word and terminates on
  `DBC(11 downto 0) = x"000"`; the word/byte boundary handling drops the last byte for 2349 but
  not for 2351 — an off-by-one in the terminal-count / last-word condition for word-vs-PRG-vs-PCM
  destinations (jgenesis issue 105 "DMA2 04: odd length skips last byte for PRG/word RAM, not
  PCM"). Fix: for word RAM and PRG RAM destinations, force the transferred length even (ignore
  the last odd byte) uniformly; leave PCM RAM byte-granular. Verify against test values 2348 and
  2350 for both odd inputs.

## Test procedure
Region auto, Keep Running armed, `/media/fat/_Console/MegaCD_verificator_disc.mgl` (verificator
cart + Final Fight CD mounted after boot). Read the CDC FLAGS / DMA2 / DMA3 lines. Reference for
the exact hardware behaviour: Genesis Plus GX issue 408 (ekeeke's per-test commits) and
jgenesis issue 105. Do NOT regress: CDC INIT OK, CDC DMA1 OK, CDC REGS 01 (correct, CDX-only).

## Deeper analysis (2026-09-06 20:35) — needs a CDC simulation bench to iterate

Traced the RTL for all three; static analysis is not enough and hardware builds (45 min each)
are too slow to iterate. RECOMMEND building a ModelSim testbench for CDC.vhd + the ASIC DMA
machine (like the conversion benches) that replays the verificator's exact DMA2/DMA3/FLAGS
register sequences and checks EDT/DSR/DBC/word-RAM against the expected values — then fixes can
be iterated in seconds instead of a 45-minute build each.

Findings to seed that bench:
- EDT (DMA3 01 / FLAGS 05): ASIC DS_IDLE sets `EDT<='1'` unconditionally while CDC_DTEN_N='1'
  (idle). Hardware: EDT is a LATCH — DMA3 wants EDT=0 after setup (before DTTRG), EDT set when
  ONE word remains (0xC2), DSR clears when all read (0x82), and FLAGS wants EDT cleared ONLY by
  a FF8004 write (DMA_ADDR_SET), not by IFCTRL=0 or CDC RST. This is the jgenesis "EDT set when
  one word left" + host-data DSR/EDT semantics (GPGX issue 408 FLAGS 22, DMA3 04). Requires a
  proper EDT/DSR state tied to the host-data read count, not the DTEN level.
- Odd length (DMA2 05): CDC TS_SEND decrements DBC(11:0) per host-read byte, ends at 0; the
  ASIC reads 2 bytes/word (DS_CDC_READ toggles DMA_BYTE) and drops a partial last word when
  DTEN deasserts mid-word. By that logic BOTH odd inputs (2349, 2351) should round down
  identically, yet hardware/our-core differ: 2349->2348 passes, 2351->2350 fails. The
  discrepancy is not visible statically (likely a DBC-vs-word boundary or a DTEN/DMA_BYTE race
  at the exact 2350/2351 boundary). The sim bench replaying both lengths will expose it.

Priority: build the CDC sim bench first, then EDT/DSR (fixes 2 of 3), then odd-length. Do NOT
change the DMA machine blind — it feeds every game's CDC data path; a regression breaks all CD
loading. Reference the exact behaviour from GPGX (ekeeke's per-test commits, issue 408) and
jgenesis (issue 105) rather than guessing.
