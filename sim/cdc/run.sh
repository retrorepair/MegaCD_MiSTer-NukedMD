#!/usr/bin/env bash
# Run the CDC/DMA bench batch (prints verificator-style PASS/ERROR nn lines).
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
"$MS/vsim" -c -quiet -do "set NumericStdNoWarnings 1; set StdArithNoWarnings 1; run -all; quit -f" work.tb_cdc
