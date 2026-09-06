#!/bin/bash
# usage: compile.sh [bad1|bad2]
#   (none) : regenerate the compare list + ROM, compile the die model, z80_rtl.v and the A/B bench
#   bad1   : same, but with a deliberately broken copy of z80_rtl.v -- one inline latch
#            (dl1: captured value inverted)
#   bad2   : same, with one rs-trigger's set/reset swapped (the refresh latch rsrfsh) -- a
#            priority/wiring mistake
# Proves the comparator fires; the real run uses no argument. The broken copy is a scratch
# file (z80_rtl_bad.v) that is never left referenced by the tree.
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
R="C:/Users/joelw/Documents/MegaCD_MiSTer_New/MegaCD_MiSTer-master/rtl"
cd "$(dirname "$0")"
set -e
# regenerate the storage compare list from the die model, assemble the directed program
perl gen_cmp.pl "$R/nuked-md/z80.v" z80_cmp.svh
perl asm_z80.pl z80_prog.asm z80_rom.hex 8192
rm -rf work z80_rtl_bad.v
$M/vlib.exe work >/dev/null
RTL="$R/nuked-md/z80_rtl.v"
case "$1" in
	bad1)   # one inline latch broken (dl1 captured value inverted)
		perl -pe 's{^(\t\t\tdl1_outp <= )w69;}{${1}~w69;}' "$R/nuked-md/z80_rtl.v" > z80_rtl_bad.v
		RTL=z80_rtl_bad.v ;;
	bad2)   # one rs-trigger set/reset swapped (refresh latch rsrfsh)
		perl -pe 's{\Qwire rsrfsh_qn = ~((clk & ~w129) | rsrfsh_nq);\E}{wire rsrfsh_qn = ~((clk & w129) | rsrfsh_nq);};
		         s{\Qrsrfsh_nq <= ~((clk & w129) | rsrfsh_qn);\E}{rsrfsh_nq <= ~((clk & ~w129) | rsrfsh_qn);}' \
			"$R/nuked-md/z80_rtl.v" > z80_rtl_bad.v
		RTL=z80_rtl_bad.v ;;
esac
if [ -n "$1" ]; then
	echo "--- mutant $1:"; diff "$R/nuked-md/z80_rtl.v" z80_rtl_bad.v 2>/dev/null || true
fi
echo "--- die + rtl + bench"
$M/vlog.exe -quiet -work work -sv -permissive -suppress 2244,2583,13314 "$R/nuked-md/z80.v" "$RTL" tb_z80.sv
echo "--- compile OK"
