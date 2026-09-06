#!/bin/bash
# usage: run.sh [SEED [NRAND [REALUART]]]
#   SEED     random seed (default 1)
#   NRAND    MCLK cycles of the constrained-random phase (default 300000)
#   REALUART 1 = include the real-speed 4800 bps loopback frame in the directed phase (default 1)
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
SEED=${1:-1}
NRAND=${2:-300000}
REALUART=${3:-1}
$M/vsim.exe -c -t 1ps -suppress 3009,3722,8386,8822,3017 +SEED=$SEED +NRAND=$NRAND +REALUART=$REALUART work.tb_ym6046 -do "run -all; quit -f" 2>&1 | grep -a -v "^# \*\* Warning\|^#    Time: \|^# Loading\|^# //\|^# vsim\|^# Start time\|^# End time\|^# Errors"
