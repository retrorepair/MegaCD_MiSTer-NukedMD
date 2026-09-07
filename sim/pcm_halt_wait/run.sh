#!/usr/bin/env bash
# Minimal repro for the PCM DMA deadlock caused by PCM_HALT_WAIT never being reset.
# Needs only ASIC_PKG.vhd, ASIC.vhd and CDC.vhd -- no vendor IP, no BIOS, no CD image.
#
#   ./run.sh            run against rtl/MCD/ASIC.vhd exactly as it is in your tree
#   ./run.sh nofix      force the bug: strip the PCM_HALT_WAIT reset if present
#   ./run.sh patched    force the fix: add the PCM_HALT_WAIT reset if absent
#
# On an unmodified upstream tree, ./run.sh reproduces the deadlock and
# ./run.sh patched passes -- that pair is the before/after for the patch.
#
# Set MS to your ModelSim/Questa binary directory if it is not the default.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
MS="${MS:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}"
RTL="$HERE/../../rtl/MCD"

rm -rf work obj; mkdir -p obj
"$MS/vlib" work

ASIC_SRC="$RTL/ASIC.vhd"
case "$1" in
	nofix)
		grep -v "PCM_HALT_WAIT <= (others => '0');" "$RTL/ASIC.vhd" > obj/ASIC_nofix.vhd
		ASIC_SRC="$HERE/obj/ASIC_nofix.vhd"
		echo "== ASIC.vhd with any PCM_HALT_WAIT reset REMOVED (upstream behaviour) =="
		;;
	patched)
		if grep -q "PCM_HALT_WAIT <= (others => '0');" "$RTL/ASIC.vhd"; then
			cp "$RTL/ASIC.vhd" obj/ASIC_patched.vhd
		else
			awk '{print; if ($0 ~ /^\t*PCM_S68K_HALT <= .0.;$/) print "\t\t\tPCM_HALT_WAIT <= (others => '"'"'0'"'"');"}' \
				"$RTL/ASIC.vhd" > obj/ASIC_patched.vhd
		fi
		ASIC_SRC="$HERE/obj/ASIC_patched.vhd"
		echo "== ASIC.vhd WITH the PCM_HALT_WAIT reset =="
		;;
	*)
		echo "== ASIC.vhd as-is =="
		;;
esac

"$MS/vcom" -2008 -quiet -work work "$RTL/ASIC_PKG.vhd"
"$MS/vcom" -2008 -quiet -work work "$ASIC_SRC"
"$MS/vcom" -2008 -quiet -work work "$RTL/CDC.vhd"
"$MS/vlog" -sv  -quiet -work work tb_pcm_halt_wait.sv

"$MS/vsim" -c -quiet work.tb_pcm_halt_wait -do "run -all; quit -f" | grep -vE '^# (Loading|\*\* Note)'
