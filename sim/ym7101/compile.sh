#!/bin/bash
# usage: compile.sh [bad1|bad2]
#   (none) : compile the die model (ym7101.v), ym7101_rtl.v, the VRAM model and the A/B bench
#   bad1   : same, with a deliberately broken copy of ym7101_rtl.v -- a pixel/serial-pipeline slave
#            inverted (sr1 second latch: the H-timing shift feeding the pixel pipeline)
#   bad2   : same, with a register-write latch corrupted -- the stored RS1 (H32/H40 width select,
#            reg 0x0C bit, sl_rs1) inverted, so the converted VDP uses the wrong horizontal mode
# Proves the comparator fires; the real run uses no argument.
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
R="C:/Users/joelw/Documents/MegaCD_MiSTer_New/MegaCD_MiSTer-master/rtl"
cd "$(dirname "$0")"
ROOT="C:/Users/joelw/Documents/MegaCD_MiSTer_New/MegaCD_MiSTer-master"
set -e
# regenerate the port/storage compare includes from the (checked-in) RTL + manifest (run at repo root)
( cd "$ROOT" && perl sim/ym7101/gen_ports.pl && perl sim/ym7101/gen_compare.pl )
rm -rf work
$M/vlib.exe work >/dev/null
RTL="$R/nuked-md/ym7101_rtl.v"
case "$1" in
	bad1)
		perl -0pe 's/(if \(hclk2\) sr1_v2 <= )sr1_v1;/${1}~sr1_v1;/' "$R/nuked-md/ym7101_rtl.v" > ym7101_rtl_bad.v
		RTL=ym7101_rtl_bad.v ;;
	bad2)
		perl -0pe 's/(if \(w215\) sl_rs1_mem <= )reg_data_l2\[0\];/${1}~reg_data_l2[0];/' "$R/nuked-md/ym7101_rtl.v" > ym7101_rtl_bad.v
		RTL=ym7101_rtl_bad.v ;;
esac
if [ -n "$1" ]; then
	echo "--- mutant $1:"; diff "$R/nuked-md/ym7101_rtl.v" ym7101_rtl_bad.v || true
	if cmp -s "$R/nuked-md/ym7101_rtl.v" ym7101_rtl_bad.v; then echo "MUTANT NOT APPLIED"; exit 1; fi
fi
echo "--- die + rtl + vram + bench"
$M/vlog.exe -quiet -work work -sv -permissive -suppress 2244,2583,13314 \
	"$R/nuked-md/ym_lib.v" "$R/nuked-md/ym7101.v" "$RTL" vram_model.v tb_ym7101.sv
echo "--- compile OK"
