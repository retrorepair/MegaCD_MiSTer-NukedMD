#!/bin/bash
# usage: run.sh [SEED [NRAND]]
#   NRAND = number of constrained-random port/register accesses after the framed phase (default 200)
# The run contains: power-on reset, H32 register programming + VRAM/CRAM/VSRAM fills + 2 frames,
# a VRAM-fill DMA and a 68k->VRAM DMA, H40 programming + 2 frames, then the random phase + 1 frame.
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
SEED=${1:-1}
NRAND=${2:-200}
$M/vsim.exe -c -t 1ps -suppress 3009,3722,8386,8822,3017 +SEED=$SEED +NRAND=$NRAND work.tb_ym7101 \
	-do "run -all; quit -f" 2>&1 | grep -a -v "^# \*\* Warning\|^#    Time: \|^# Loading\|^# //\|^# vsim\|^# Start time\|^# End time\|^# Errors"
