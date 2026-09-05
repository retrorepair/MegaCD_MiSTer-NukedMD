#!/bin/bash
# usage: compile.sh [bad1|bad2]
#   (none) : compile die model, tmss_rtl.v and the A/B bench
#   bad1   : same, but with a deliberately broken copy of tmss_rtl.v (dff1 slave inverted)
#   bad2   : same, with the ym_sdffs set/clk priority of dff2 swapped (the subtle mistake)
# Proves the comparator fires; the real run uses no argument.
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
R="C:/Users/joelw/Documents/MegaCD_MiSTer_New/MegaCD_MiSTer-master/rtl"
cd "$(dirname "$0")"
set -e
rm -rf work
$M/vlib.exe work >/dev/null
RTL="$R/nuked-md/tmss_rtl.v"
case "$1" in
	bad1)
		perl -pe 's/^(\t\t\tdff1_l2 <= )dff1_l1;/$1~dff1_l1;/' "$R/nuked-md/tmss_rtl.v" > tmss_rtl_bad.v
		RTL=tmss_rtl_bad.v ;;
	bad2)
		perl -0pe 's/if \(~w10\)\n\t\t\tdff2_l1 <= dff1_q;\n\t\telse if \(~SRES\)\n\t\t\tdff2_l1 <= 1'"'"'h1;/if (~SRES)\n\t\t\tdff2_l1 <= 1'"'"'h1;\n\t\telse if (~w10)\n\t\t\tdff2_l1 <= dff1_q;/' "$R/nuked-md/tmss_rtl.v" > tmss_rtl_bad.v
		RTL=tmss_rtl_bad.v ;;
esac
if [ -n "$1" ]; then
	echo "--- mutant $1:"; diff "$R/nuked-md/tmss_rtl.v" tmss_rtl_bad.v || true
fi
echo "--- die + rtl + bench"
$M/vlog.exe -quiet -work work -sv -permissive -suppress 2244,2583,13314 "$R/nuked-md/ym_lib.v" "$R/nuked-md/tmss.v" "$RTL" tb_tmss.sv
echo "--- compile OK"
