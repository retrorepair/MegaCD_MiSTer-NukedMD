#!/usr/bin/env bash
# usage: run.sh <prglat> [noff] [en50]     en50: 1 = CLK domain (fixed, default), 0 = MCLK (legacy)
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
LAT="${1:-3}"; NOFF="${2:-13}"; EN50="${3:-1}"
"$MS/vsim" -c -quiet -do "set NumericStdNoWarnings 1; set StdArithNoWarnings 1; run -all; quit -f" \
   +prglat=$LAT +noff=$NOFF +en50=$EN50 work.tb_mcd_irq
