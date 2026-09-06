#!/usr/bin/env bash
# opt_gen.sh -- produce rtl/nuked-md/ym3438_opt.v (STAGE 2).
# Starts from the die sources and, relative to ym3438_rtl.v, additionally:
#   * threads a per-module  reg c2_prev / wire c2r = c2 & ~c2_prev  and appends
#     .c2r(c2r) to every .c2(c2) instantiation;
#   * renames the collapsible master-slave cells to their _opt (single-FF) form;
#   * keeps the prescaler on two-register ym_sr_bit_kept so c1/c2 stay identical.
#
# !!! WARNING -- THIS PRODUCES THE NAIVE ALL-COLLAPSE STARTING POINT ONLY.
# Every ym_sr_bit_opt/ym_sr_bit_array_opt/... it emits defaults to KEEP=0 (single
# FF), which is NOT output-exact to the die: cells whose bit_in is combinational and
# phase-varying (nIC/IC reset, async CPU-bus strobes, TEST_i -- free-running counters
# and rotating register rings) must be KEPT two-register (KEEP=1).  That per-cell
# classification is maintained BY HAND in rtl/nuked-md/ym3438_opt.v (see its header),
# which is the authoritative, bench-validated, Quartus-fitted artifact.  Running this
# script OVERWRITES that file with the non-exact version -- if you regenerate, you
# MUST re-apply the KEEP=1 classification (the ym3438_opt.v header lists every kept
# cell and why).  The A/B bench (sim/ym3438, +OPT, both seeds, 200000 cycles, plus
# the +SROUT cell-level diagnostic) is the check that the classification is complete.
set -e
export PATH="/c/Program Files/Git/usr/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../rtl/nuked-md"
OUT="$SRC/ym3438_opt.v"

TYPES="ym3438 ym3438_prescaler ym3438_fsm ym3438_io ym3438_reg_ctrl \
ym3438_op_register ym3438_ch_register ym3438_reg_wr_ctrl ym3438_reg_data \
ym3438_lfo ym3438_detune ym3438_pg ym3438_eg ym3438_op ym3438_ch \
ym_sr_bit ym_sr_bit_array ym_cnt_bit ym_cnt_bit_load ym_dbg_read ym_dbg_read_eg \
ym_dlatch_1 ym_dlatch_2 ym_edge_detect ym_rs_trig ym_rs_trig_sync ym_slatch"
RENAME=""
for t in $TYPES; do RENAME="$RENAME s/\\b${t}\\b/${t}_opt/g;"; done

# c2r generator block inserted into each datapath module
GEN='\n\t\/\/ STAGE 2: shared rising-edge-of-c2 capture pulse for collapsed cells\n\treg c2_prev = 1'"'"'h0;\n\twire c2r = c2 & ~c2_prev;\n\talways \@(posedge MCLK) c2_prev <= c2;\n'

# add .c2r(c2r) ONLY to instantiations of the collapsed primitive cells (matched
# from the cell type name up to its own .c2(c2), staying inside the instance via
# [^;]).  Sub-module and prescaler instantiations keep a plain .c2(c2).
APPEND=""
for t in ym_sr_bit ym_sr_bit_array ym_cnt_bit ym_cnt_bit_load ym_dbg_read ym_dbg_read_eg ym_dlatch_2; do
    APPEND="$APPEND s/(\\b${t}\\b[^;]*?\\.c2\\(c2\\))/\$1,\\n\\t\\t.c2r(c2r)/g;"
done

REORDER='
  my @d;
  s/^\t(wire \[\d+:0\] debug_data\w*;)\r?\n/push @d,$1; ""/mge;
  my $ins = join("", map {"\t$_\r\n"} @d);
  s/(\r?\n\treg \[7:0\] data_o_r;)/"\r\n\t".$ins.$1/e;
'
# insert c2r generator after every module header ");" (files with >=1 datapath module)
INSERT_ALL='s/(\bmodule\b[^;]*\);\r?\n)/$1 . "'"$GEN"'"/ge;'
# top ym3438: insert after "wire c1, c2;" instead (c2 is an internal wire there)
INSERT_TOP='s/(\r?\n\twire c1, c2;\r?\n)/$1 . "'"$GEN"'"/e;'

cat "$HERE/ym3438_opt_head.vh" > "$OUT"

# prescaler: keep two-register cells (ym_sr_bit_kept), rename module only, no c2r
printf '\n// ==== from ym3438_prescaler.v (kept two-register) ====\n' >> "$OUT"
perl -pe 's/\bym_sr_bit\b/ym_sr_bit_kept/g; s/\bym3438_prescaler\b/ym3438_prescaler_opt/g;' \
     "$SRC/ym3438_prescaler.v" >> "$OUT"

# other datapath modules (multi-module files): append c2r, insert generator, rename
for f in ym3438_fsm.v ym3438_io.v ym3438_regs.v ym3438_lfo.v ym3438_detune.v \
         ym3438_pg.v ym3438_eg.v ym3438_op.v ym3438_ch.v ; do
    printf '\n// ==== from %s ====\n' "$f" >> "$OUT"
    if [ "$f" = "ym3438_io.v" ]; then
        perl -0777 -pe "$REORDER" "$SRC/$f" | perl -0777 -pe "$APPEND $INSERT_ALL" | perl -pe "$RENAME" >> "$OUT"
    else
        perl -0777 -pe "$APPEND $INSERT_ALL" "$SRC/$f" | perl -pe "$RENAME" >> "$OUT"
    fi
done

# top: insert generator after the internal "wire c1, c2;"
printf '\n// ==== from ym3438.v (top) ====\n' >> "$OUT"
perl -0777 -pe "$APPEND $INSERT_TOP" "$SRC/ym3438.v" | perl -pe "$RENAME" >> "$OUT"

echo "wrote $OUT"
grep -c '^module' "$OUT" | sed 's/^/modules: /'
