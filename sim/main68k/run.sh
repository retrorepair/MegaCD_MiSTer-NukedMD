#!/usr/bin/env bash
# usage: run.sh [prog] [iters]   prog 0 = verificator 0A loop, 1 = cross-check blocks
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
PROG="${1:-0}"; ITERS="${2:-3}"
"$MS/vsim" -c -quiet -do "set NumericStdNoWarnings 1; set StdArithNoWarnings 1; run -all; quit -f" \
   +prog=$PROG +iters=$ITERS work.tb_m68k_timing
