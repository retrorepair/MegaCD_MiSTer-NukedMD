#!/usr/bin/env bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
R="$HERE/../../rtl"
cp -f "$R/nuked-md/68k_ucode.txt" "$R/nuked-md/68k_ncode.txt" . 2>/dev/null
rm -rf work; "$MS/vlib" work
# behavioural RAM stand-ins (replace altera_mf bram.vhd) + CEGen + ASIC package first
"$MS/vcom" -2008 -quiet -work work bram_beh.vhd
"$MS/vcom" -2008 -quiet -work work "$R/CEGen.vhd"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/ASIC_PKG.vhd"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/ASIC.vhd"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/CDC.vhd"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/PCM.vhd"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/CDDA.vhd"
# gate-level Nuked 68000 (Verilog) + its VHDL wrapper
"$MS/vlog" -quiet -work work "$R/nuked-md/68k.v"
"$MS/vcom" -2008 -quiet -work work "$R/MCD/MC68K.vhd"
# SV helpers used by MCD
"$MS/vlog" -sv -quiet -work work "$R/pcm_mem.sv"
"$MS/vlog" -sv -quiet -work work codes_stub.sv
# MCD top + bench
"$MS/vcom" -2008 -quiet -work work "$R/MCD/MCD.vhd"
"$MS/vlog" -sv -work work tb_mcd_boot.sv
echo "compile OK"
