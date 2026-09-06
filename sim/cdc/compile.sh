#!/usr/bin/env bash
# Compile the CDC/DMA bench (ASIC + CDC + behavioural RAM models) in ModelSim ASE.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
RTL="$HERE/../../rtl/MCD"

rm -rf work
"$MS/vlib" work
# VHDL DUTs (package first). -2008 handles the RTL style.
"$MS/vcom" -2008 -quiet -work work "$RTL/ASIC_PKG.vhd"
"$MS/vcom" -2008 -quiet -work work "$RTL/ASIC.vhd"
"$MS/vcom" -2008 -quiet -work work "$RTL/CDC.vhd"
# SystemVerilog testbench (+ behavioural RAM models)
"$MS/vlog" -sv -quiet -work work "$HERE/tb_cdc.sv"
echo "compile OK"
