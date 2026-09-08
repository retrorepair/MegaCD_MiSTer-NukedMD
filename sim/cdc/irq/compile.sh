#!/usr/bin/env bash
# Compile the INT2-latency measurement bench in its OWN work library (this dir),
# so it never touches sim/cdc/work.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
R="$HERE/../../../rtl"
cp -f "$R/nuked-md/68k_ucode.txt" "$R/nuked-md/68k_ncode.txt" . 2>/dev/null || true
rm -rf work; "$MS/vlib" work
"$MS/vcom" -2008 -quiet -work work ../bram_beh.vhd
"$MS/vcom" -2008 -quiet -work work "$R/CEGen.vhd"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/ASIC_PKG.vhd"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/ASIC.vhd"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/CDC.vhd"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/PCM.vhd"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/CDDA.vhd"
"$MS/vlog" -quiet -work work "$R/nuked-md/68k.v"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/MC68K.vhd"
"$MS/vlog" -sv -quiet -work work "$R/pcm_mem.sv"
"$MS/vlog" -sv -quiet -work work ../codes_stub.sv
"$MS/vcom" -2008 -quiet -work work "$R/MCD/MCD.vhd"
"$MS/vlog" -sv -work work tb_mcd_irq.sv
echo "compile OK"
