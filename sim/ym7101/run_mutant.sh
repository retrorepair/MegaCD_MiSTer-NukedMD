#!/bin/bash
# run_mutant.sh bad1|bad2  -- prove the A/B comparator fires.  Builds a mutated copy of
# ym7101_rtl.v into a SEPARATE work_mut library (never touches work/ or the concurrent runs) and
# runs seed 1; the comparator MUST report a MISMATCH/FAIL.  Cleans the mutated copy afterwards.
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
R="C:/Users/joelw/Documents/MegaCD_MiSTer_New/MegaCD_MiSTer-master/rtl"
cd "$(dirname "$0")"
ROOT="C:/Users/joelw/Documents/MegaCD_MiSTer_New/MegaCD_MiSTer-master"
set -e
( cd "$ROOT" && perl sim/ym7101/gen_ports.pl && perl sim/ym7101/gen_compare.pl ) >/dev/null 2>&1
case "$1" in
  bad1) perl -0pe 's/(if \(hclk2\) sr1_v2 <= )sr1_v1;/${1}~sr1_v1;/' "$R/nuked-md/ym7101_rtl.v" > ym7101_rtl_bad.v ;;
  bad2) perl -0pe 's/(if \(w215\) sl_rs1_mem <= )reg_data_l2\[0\];/${1}~reg_data_l2[0];/' "$R/nuked-md/ym7101_rtl.v" > ym7101_rtl_bad.v ;;
  *) echo "usage: run_mutant.sh bad1|bad2"; exit 1 ;;
esac
if cmp -s "$R/nuked-md/ym7101_rtl.v" ym7101_rtl_bad.v; then echo "MUTANT $1 NOT APPLIED"; exit 1; fi
rm -rf work_mut; $M/vlib.exe work_mut >/dev/null
$M/vlog.exe -quiet -work work_mut -sv -permissive -suppress 2244,2583,13314 \
	"$R/nuked-md/ym_lib.v" "$R/nuked-md/ym7101.v" ym7101_rtl_bad.v vram_model.v tb_ym7101.sv >/dev/null 2>&1
echo "--- mutant $1 compiled, running (expect FAIL) ---"
$M/vsim.exe -c -t 1ps -suppress 3009,3722,8386,8822,3017 +SEED=1 +NRAND=50 +FCYC=40000 work_mut.tb_ym7101 \
	-do "run -all; quit -f" 2>&1 | grep -aE "MISMATCH|FAIL|PASS" | head -8
rm -f ym7101_rtl_bad.v
echo "--- mutant $1 done (bad.v removed) ---"
