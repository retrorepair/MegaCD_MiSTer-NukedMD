#!/bin/bash
# compile_opt.sh -- STAGE 2 output-exact A/B bench: die model ym7101 vs the collapsed ym7101_opt.
# Regenerates ym7101_opt.v (opt_transform.pl), the die/opt output includes, and compiles into a
# SEPARATE work_opt library (so it never disturbs the Stage-1 work/ or the concurrent ym3438 run).
# Env OPT_SR / OPT_DFF (0/1) select which collapse classes are applied (passed to opt_transform.pl).
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
R="C:/Users/joelw/Documents/MegaCD_MiSTer_New/MegaCD_MiSTer-master/rtl"
cd "$(dirname "$0")"
ROOT="C:/Users/joelw/Documents/MegaCD_MiSTer_New/MegaCD_MiSTer-master"
set -e
# 1) regenerate ym7101_opt.v from the die model with the requested collapse classes
( cd "$ROOT" && perl sim/ym7101/opt_transform.pl )
# 2) regenerate ports_gen.svh (for its output list) then derive the opt DUT instance
( cd "$ROOT" && perl sim/ym7101/gen_ports.pl )
sed 's/ym7101_rtl u_rtl (/ym7101_opt u_rtl (/' ports_gen.svh > ports_opt.svh
rm -rf work_opt
$M/vlib.exe work_opt >/dev/null
echo "--- die + opt + vram + bench (+OPT_BENCH)"
$M/vlog.exe -quiet -work work_opt -sv -permissive +define+OPT_BENCH -suppress 2244,2583,13314 \
	"$R/nuked-md/ym_lib.v" "$R/nuked-md/ym7101.v" "$R/nuked-md/ym7101_opt.v" vram_model.v tb_ym7101.sv
echo "--- opt compile OK"
