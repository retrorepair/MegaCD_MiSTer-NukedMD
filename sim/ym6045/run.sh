#!/bin/bash
# usage: run.sh [SEED [NRAND]]
#   NRAND = MCLK cycles of constrained-random traffic (default 300000); the run also contains the
#   power-on timer (~0.9M cycles), the directed phase and a reset-button phase, ~3.4M cycles total.
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
SEED=${1:-1}
NRAND=${2:-300000}
$M/vsim.exe -c -t 1ps -suppress 3009,3722,8386,8822,3017 +SEED=$SEED +NRAND=$NRAND work.tb_ym6045 -do "run -all; quit -f" 2>&1 | grep -a -v "^# \*\* Warning\|^#    Time: \|^# Loading\|^# //\|^# vsim\|^# Start time\|^# End time\|^# Errors"
