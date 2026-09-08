#!/usr/bin/env bash
# usage: run2.sh <prglat> [noff] [en50] [lib] [fineoff]
#   fineoff = offset for which a per-CLK edge log is printed (-1 = none)
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
LAT="${1:-3}"; NOFF="${2:-13}"; EN50="${3:-1}"; LIB="${4:-work2}"; FINE="${5:--1}"
"$MS/vsim" -c -quiet -do "set NumericStdNoWarnings 1; set StdArithNoWarnings 1; run -all; quit -f" \
   +prglat=$LAT +noff=$NOFF +en50=$EN50 +fine=$FINE "$LIB.tb_mcd_irq2"
