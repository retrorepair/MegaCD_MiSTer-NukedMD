#!/usr/bin/env bash
# run_mutant.sh <name> <perl-mutation>   -- sanity-check that the A/B bench DETECTS
# a deliberate single-point corruption of the DUT.  The mutated copy of
# ym3438_rtl.v is built in the scratchpad (OUTSIDE the repo tree) and the work lib
# is thrown away afterwards, so nothing is left in the tree.
#
# Prints "MUTANT CAUGHT" if the bench reports a mismatch (expected), else
# "MUTANT ESCAPED" (a bench weakness).
set -e
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
export PATH="/c/Program Files/Git/usr/bin:$MS"
HERE="$(cd "$(dirname "$0")" && pwd)"
RTLDIR="$HERE/../../rtl/nuked-md"
SCR="/c/Users/joelw/AppData/Local/Temp/claude/C--Users-joelw-Documents-MegaCD-MiSTer-New/2ec3372d-bd5a-402d-ac38-21cf2da5ce03/scratchpad"
NAME="$1"; MUT="$2"
WORK="$SCR/mut_${NAME}"
mkdir -p "$WORK"; cd "$WORK"
rm -rf work; vlib work >/dev/null

# mutated DUT (module name stays ym3438_rtl so the bench binds it as dut)
perl -0777 -pe "$MUT" "$RTLDIR/ym3438_rtl.v" > mut.v
if diff -q "$RTLDIR/ym3438_rtl.v" mut.v >/dev/null; then
    echo "!! mutation '$NAME' changed nothing -- fix the pattern"; exit 3
fi

# patched die io (decl reorder), same as compile.sh
perl -0777 -pe '
  my @d;
  s/^\t(wire \[\d+:0\] debug_data\w*;)\r?\n/push @d,$1; ""/mge;
  my $ins = join("", map {"\t$_\r\n"} @d);
  s/(\r?\n\treg \[7:0\] data_o_r;)/"\r\n\t".$ins.$1/e;
' "$RTLDIR/ym3438_io.v" > io_patched.v

VF="-sv -permissive -quiet -suppress 2244,2583"
vlog $VF "$RTLDIR/ym_lib.v" "$RTLDIR/ym3438_prescaler.v" "$RTLDIR/ym3438_fsm.v" \
    io_patched.v "$RTLDIR/ym3438_regs.v" "$RTLDIR/ym3438_lfo.v" \
    "$RTLDIR/ym3438_detune.v" "$RTLDIR/ym3438_pg.v" "$RTLDIR/ym3438_eg.v" \
    "$RTLDIR/ym3438_op.v" "$RTLDIR/ym3438_ch.v" "$RTLDIR/ym3438.v" >/dev/null
vlog $VF mut.v >/dev/null
vlog $VF "$HERE/storage_compare.svh" "$HERE/tb_ym3438.sv" >/dev/null

LOG=$(vsim -c -quiet tb_ym3438 +SEED=7 +NCYC=60000 -do "run -all; quit -f" 2>&1)
echo "$LOG" | grep -iE "MISMATCH|PASS:|first mismatch|\[[0-9]+\]" | head -6
if echo "$LOG" | grep -qi "MISMATCH"; then
    echo "MUTANT CAUGHT ($NAME)"
else
    echo "MUTANT ESCAPED ($NAME)  <-- bench did not detect corruption"
fi
cd "$HERE"; rm -rf "$WORK"
