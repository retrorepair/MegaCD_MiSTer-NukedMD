#!/usr/bin/env bash
# compile.sh [rtl|opt]   -- compile die model + converted DUT + bench.
# Default target rtl (Stage 1).  'opt' compiles ym3438_opt.v and defines OPT.
set -e
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
export PATH="$MS:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
RTLDIR="$HERE/../../rtl/nuked-md"
cd "$HERE"

TARGET="${1:-rtl}"
DEF=""
DUTFILE="$RTLDIR/ym3438_rtl.v"
if [ "$TARGET" = "opt" ]; then DEF="+define+OPT"; DUTFILE="$RTLDIR/ym3438_opt.v"; fi

rm -rf work
vlib work >/dev/null

# ModelSim rejects ym3438_io.v's module-scope forward net reference (debug_data
# read at line ~210, declared at ~223; vlog-2730, not suppressible).  We compile a
# copy with ONLY those four wire declarations moved above their first use -- a pure
# declaration reorder, zero logic change.  The ORIGINAL source is left untouched.
export PATH="/c/Program Files/Git/usr/bin:$MS"
mkdir -p gen
perl -0777 -pe '
  my @d;
  s/^\t(wire \[\d+:0\] debug_data\w*;)\r?\n/push @d,$1; ""/mge;
  my $ins = join("", map {"\t$_\r\n"} @d);
  s/(\r?\n\treg \[7:0\] data_o_r;)/"\r\n\t\/\/ (decls moved up for ModelSim decl-before-use; logic unchanged)\r\n".$ins.$1/e;
' "$RTLDIR/ym3438_io.v" > gen/ym3438_io.v

# die model: the ym_lib cells + all ym3438 die sources (io from the patched copy)
DIE="$RTLDIR/ym_lib.v \
$RTLDIR/ym3438_prescaler.v $RTLDIR/ym3438_fsm.v gen/ym3438_io.v \
$RTLDIR/ym3438_regs.v $RTLDIR/ym3438_lfo.v $RTLDIR/ym3438_detune.v \
$RTLDIR/ym3438_pg.v $RTLDIR/ym3438_eg.v $RTLDIR/ym3438_op.v \
$RTLDIR/ym3438_ch.v $RTLDIR/ym3438.v"

# flags match the reference benches (sim/tmss etc.): -permissive turns the die
# sources' module-scope forward net references into warnings.
VFLAGS="-sv -permissive -quiet -suppress 2244,2583"
vlog $VFLAGS $DIE
vlog $VFLAGS "$DUTFILE"
SROUTF=""
if [ "$TARGET" = "opt" ]; then SROUTF="srout_compare.svh"; fi
vlog $VFLAGS $DEF storage_compare.svh $SROUTF tb_ym3438.sv
echo "compile OK ($TARGET)"
