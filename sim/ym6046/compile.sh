#!/bin/bash
# usage: compile.sh [bad1|bad2|bad3]
#   (none) : compile die model, ym6046_rtl.v and the A/B bench
#   bad1   : same, but with a deliberately broken copy of ym6046_rtl.v (tx_bit slave inverted, controller port)
#   bad2   : same, with the ym_sdffs set/clk priority of rx_input_bit swapped (the subtle mistake for rule D)
#   bad3   : same, with the ym_sdffsr l2 set/reset priority of tx_state1 swapped (the subtle mistake for rule E:
#            differs only while write_tx_data and reset are both low, i.e. SRES inside a TxData write)
# Proves the comparator fires; the real run uses no argument. The mutant copy ym6046_rtl_bad.v is
# a build artefact of this directory only; run compile.sh without an argument afterwards.
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
R="C:/Users/joelw/Documents/MegaCD_MiSTer_New/MegaCD_MiSTer-master/rtl"
cd "$(dirname "$0")"
set -e
rm -rf work
$M/vlib.exe work >/dev/null
RTL="$R/nuked-md/ym6046_rtl.v"
case "$1" in
	bad1)
		perl -pe 's/^(\t\t\ttx_bit_l2 <= )tx_bit_l1;/$1~tx_bit_l1;/' "$R/nuked-md/ym6046_rtl.v" > ym6046_rtl_bad.v
		RTL=ym6046_rtl_bad.v ;;
	bad2)
		perl -0pe 's/if \(~uart_clk1\)\n\t\t\trx_input_bit_l1 <= port_i\[5\];\n\t\telse if \(~s_control_q\[2\]\)\n\t\t\trx_input_bit_l1 <= 1'"'"'h1;/if (~s_control_q[2])\n\t\t\trx_input_bit_l1 <= 1'"'"'h1;\n\t\telse if (~uart_clk1)\n\t\t\trx_input_bit_l1 <= port_i[5];/' "$R/nuked-md/ym6046_rtl.v" > ym6046_rtl_bad.v
		RTL=ym6046_rtl_bad.v ;;
	bad3)
		perl -0pe 's/if \(~write_tx_data\)\n\t\t\ttx_state1_l2 <= 1'"'"'h1;\n\t\telse if \(~reset\)\n\t\t\ttx_state1_l2 <= 1'"'"'h0;/if (~reset)\n\t\t\ttx_state1_l2 <= 1'"'"'h0;\n\t\telse if (~write_tx_data)\n\t\t\ttx_state1_l2 <= 1'"'"'h1;/' "$R/nuked-md/ym6046_rtl.v" > ym6046_rtl_bad.v
		RTL=ym6046_rtl_bad.v ;;
	"") rm -f ym6046_rtl_bad.v ;;
	*) echo "unknown mutant $1"; exit 1 ;;
esac
if [ -n "$1" ]; then
	echo "--- mutant $1:"; diff "$R/nuked-md/ym6046_rtl.v" ym6046_rtl_bad.v || true
	if cmp -s "$R/nuked-md/ym6046_rtl.v" ym6046_rtl_bad.v; then echo "mutant pattern did not apply"; exit 1; fi
fi
echo "--- die + rtl + bench"
$M/vlog.exe -quiet -work work -sv -permissive -suppress 2244,2583,13314 "$R/nuked-md/ym_lib.v" "$R/nuked-md/ym6046.v" "$RTL" tb_ym6046.sv
echo "--- compile OK"
