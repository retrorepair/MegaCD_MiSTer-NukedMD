#!/usr/bin/env bash
# Build the main-CPU (Mega Drive 68000) bus-cycle timing bench in its own library.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
R="$HERE/../../rtl"
cp -f "$R/nuked-md/68k_ucode.txt" "$R/nuked-md/68k_ncode.txt" .
rm -rf work; "$MS/vlib" work
"$MS/vlog" -quiet -work work "$R/nuked-md/68k.v"
"$MS/vlog" -sv -work work tb_m68k_timing.sv
echo "compile OK"
