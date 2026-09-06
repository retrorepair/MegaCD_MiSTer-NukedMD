#!/usr/bin/env bash
# run.sh [SEED] [NCYC] [extra vsim plusargs...]   -- run the A/B bench.
# Parallel-safe: transcript/wlf are tagged by SEED (+ OPT plusarg) so two seeds
# can run concurrently against the one compiled work library.
# e.g.  ./run.sh 1 1000000            (full storage compare, seed 1, 1e6 cycles)
#       ./run.sh 2 200000 +NOSTORE    (outputs only)
#       ./run.sh 1 1000000 +OPT       (Stage-2 opt DUT; needs compile.sh opt)
set -e
MS="/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem"
export PATH="$MS:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
SEED="${1:-1}"; NCYC="${2:-200000}"; shift 2 2>/dev/null || true
TAG="s${SEED}"
for a in "$@"; do [ "$a" = "+OPT" ] && TAG="${TAG}_opt"; done
vsim -c -quiet -suppress 3009 -l "run_${TAG}.log" -wlf "run_${TAG}.wlf" \
     tb_ym3438 +SEED=$SEED +NCYC=$NCYC "$@" \
     -do "run -all; quit -f" 2>&1
