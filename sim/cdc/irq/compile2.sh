#!/usr/bin/env bash
# Compile the INSTRUMENTED INT2 bench (tb_mcd_irq2.sv) into its own library "work2",
# so it never touches sim/cdc/work or sim/cdc/irq/work.
#
# usage: compile2.sh [rtl_mcd_dir]
#   rtl_mcd_dir defaults to ../../../rtl/MCD (the real, untouched RTL).
#   Pass rtl_try to build from the scratch copy in sim/cdc/irq/rtl_try.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
R="$HERE/../../../rtl"
M="${1:-$R/MCD}"
LIB="${2:-work2}"
cp -f "$R/nuked-md/68k_ucode.txt" "$R/nuked-md/68k_ncode.txt" . 2>/dev/null || true
rm -rf "$LIB"; "$MS/vlib" "$LIB"
"$MS/vcom" -2008 -quiet -work "$LIB" ../bram_beh.vhd
"$MS/vcom" -2008 -quiet -work "$LIB" "$R/CEGen.vhd"
"$MS/vcom" -2008 -quiet -work "$LIB" "$M/ASIC_PKG.vhd"
"$MS/vcom" -2008 -quiet -work "$LIB" "$M/ASIC.vhd"
"$MS/vcom" -2008 -quiet -work "$LIB" "$M/CDC.vhd"
"$MS/vcom" -2008 -quiet -work "$LIB" "$M/PCM.vhd"
"$MS/vcom" -2008 -quiet -work "$LIB" "$M/CDDA.vhd"
"$MS/vlog" -quiet -work "$LIB" "$R/nuked-md/68k.v"
"$MS/vcom" -2008 -quiet -work "$LIB" "$M/MC68K.vhd"
"$MS/vlog" -sv -quiet -work "$LIB" "$R/pcm_mem.sv"
"$MS/vlog" -sv -quiet -work "$LIB" ../codes_stub.sv
"$MS/vcom" -2008 -quiet -work "$LIB" "$M/MCD.vhd"
"$MS/vlog" -sv -work "$LIB" tb_mcd_irq2.sv
echo "compile OK  (rtl=$M  lib=$LIB)"
