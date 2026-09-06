#!/usr/bin/env bash
# opt_build.sh -- compile die + ym3438_opt + bench into an ISOLATED work library
# (scratch dir) so it never touches the main sim/ym3438/work used by other runs.
# Prints the scratch dir path on its last line.
set -e
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
export PATH="/c/Program Files/Git/usr/bin:$MS"
HERE="$(cd "$(dirname "$0")" && pwd)"
RTLDIR="$HERE/../../rtl/nuked-md"
SCR="/c/Users/joelw/AppData/Local/Temp/claude/C--Users-joelw-Documents-MegaCD-MiSTer-New/2ec3372d-bd5a-402d-ac38-21cf2da5ce03/scratchpad/optval"
mkdir -p "$SCR"; cd "$SCR"
rm -rf work; vlib work >/dev/null

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
    "$RTLDIR/ym3438_op.v" "$RTLDIR/ym3438_ch.v" "$RTLDIR/ym3438.v"
vlog $VF "$RTLDIR/ym3438_opt.v"
vlog $VF +define+OPT "$HERE/${SC:-storage_compare.svh}" "$HERE/tb_ym3438.sv"
echo "opt compile OK"
echo "$SCR"
