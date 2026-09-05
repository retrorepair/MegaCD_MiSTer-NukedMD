#!/bin/bash
# usage: run.sh [SEED [NRAND]]
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
SEED=${1:-1}
NRAND=${2:-250000}
$M/vsim.exe -c -t 1ps -suppress 3009,3722,8386,8822,3017 +SEED=$SEED +NRAND=$NRAND work.tb_tmss -do "run -all; quit -f" 2>&1 | grep -a -v "^# \*\* Warning\|^#    Time: \|^# Loading\|^# //\|^# vsim\|^# Start time\|^# End time\|^# Errors"
