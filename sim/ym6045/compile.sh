#!/bin/bash
# usage: compile.sh [bad1|bad2]
#   (none) : compile the die model (ym6045.v), ym6045_rtl.v and the A/B bench
#   bad1   : same, but with a deliberately broken copy of ym6045_rtl.v (dff23 slave inverted:
#            the refresh-stall flag)
#   bad2   : same, with the ym_sdffs set/clk priority of dff47 (the refresh REF flip-flop; its set
#            w164 is active whenever the Z80 owns its bus, so the two priorities differ on every
#            refresh request) swapped -- the subtle mistake a hand conversion would make. Only the
#            master dff47_l1 differs (the slave is forced by set either way): this proves the bench
#            catches internal-only differences. (dff33 was considered first: its priority swap can
#            only differ when w283 = 0 during SRES, which needs FC = 0 with M3 = 0 -- a mutant the
#            stimulus can never fire.)
# Proves the comparator fires; the real run uses no argument.
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
R="C:/Users/joelw/Documents/MegaCD_MiSTer_New/MegaCD_MiSTer-master/rtl"
cd "$(dirname "$0")"
set -e
rm -rf work
$M/vlib.exe work >/dev/null
RTL="$R/nuked-md/ym6045_rtl.v"
case "$1" in
	bad1)
		perl -pe 's/^(\t\t\tdff23_l2 <= )dff23_l1;/$1~dff23_l1;/' "$R/nuked-md/ym6045_rtl.v" > ym6045_rtl_bad.v
		RTL=ym6045_rtl_bad.v ;;
	bad2)
		perl -0pe 's/if \(VCLK\)\n\t\t\tdff47_l1 <= w273;\n\t\telse if \(~w164\)\n\t\t\tdff47_l1 <= 1'"'"'h1;/if (~w164)\n\t\t\tdff47_l1 <= 1'"'"'h1;\n\t\telse if (VCLK)\n\t\t\tdff47_l1 <= w273;/' "$R/nuked-md/ym6045_rtl.v" > ym6045_rtl_bad.v
		RTL=ym6045_rtl_bad.v ;;
esac
if [ -n "$1" ]; then
	echo "--- mutant $1:"; diff "$R/nuked-md/ym6045_rtl.v" ym6045_rtl_bad.v || true
	if cmp -s "$R/nuked-md/ym6045_rtl.v" ym6045_rtl_bad.v; then echo "MUTANT NOT APPLIED"; exit 1; fi
fi
echo "--- die + rtl + bench"
$M/vlog.exe -quiet -work work -sv -permissive -suppress 2244,2583,13314 "$R/nuked-md/ym_lib.v" "$R/nuked-md/ym6045.v" "$RTL" tb_ym6045.sv
echo "--- compile OK"
