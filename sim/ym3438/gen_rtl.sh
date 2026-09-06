#!/usr/bin/env bash
# gen_rtl.sh -- produce rtl/nuked-md/ym3438_rtl.v (STAGE 1, strict 1:1).
# See ym3438_rtl_head.vh for what the conversion does and does not do.
set -e
export PATH="/c/Program Files/Git/usr/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../rtl/nuked-md"
OUT="$SRC/ym3438_rtl.v"

# every module/primitive TYPE that must gain the _rtl suffix.  \b word boundaries
# make the set order-independent (ym_sr_bit never matches inside ym_sr_bit_array,
# ym3438 never inside ym3438_fsm, X_rtl never re-matched by \bX\b).
TYPES="ym3438 ym3438_prescaler ym3438_fsm ym3438_io ym3438_reg_ctrl \
ym3438_op_register ym3438_ch_register ym3438_reg_wr_ctrl ym3438_reg_data \
ym3438_lfo ym3438_detune ym3438_pg ym3438_eg ym3438_op ym3438_ch \
ym_sr_bit ym_sr_bit_array ym_cnt_bit ym_cnt_bit_load ym_dbg_read ym_dbg_read_eg \
ym_dlatch_1 ym_dlatch_2 ym_edge_detect ym_rs_trig ym_rs_trig_sync ym_slatch"

FILES="ym3438_prescaler.v ym3438_fsm.v ym3438_io.v ym3438_regs.v ym3438_lfo.v \
ym3438_detune.v ym3438_pg.v ym3438_eg.v ym3438_op.v ym3438_ch.v ym3438.v"

# build the perl program: one s/\bTYPE\b/TYPE_rtl/g per type
PERL=""
for t in $TYPES; do PERL="$PERL s/\\b${t}\\b/${t}_rtl/g;"; done

# declaration reorder applied ONLY to ym3438_io.v: move the four debug_data* wire
# declarations above their first (procedural) use so the result compiles under
# ModelSim/strict decl-before-use.  Pure reorder, zero logic change.
REORDER='
  my @d;
  s/^\t(wire \[\d+:0\] debug_data\w*;)\r?\n/push @d,$1; ""/mge;
  my $ins = join("", map {"\t$_\r\n"} @d);
  s/(\r?\n\treg \[7:0\] data_o_r;)/"\r\n\t\/\/ (decls moved up for decl-before-use; logic unchanged)\r\n".$ins.$1/e;
'

cat "$HERE/ym3438_rtl_head.vh" > "$OUT"
for f in $FILES; do
    printf '\n// ==== from %s ====\n' "$f" >> "$OUT"
    if [ "$f" = "ym3438_io.v" ]; then
        perl -0777 -pe "$REORDER" "$SRC/$f" | perl -pe "$PERL" >> "$OUT"
    else
        perl -pe "$PERL" "$SRC/$f" >> "$OUT"
    fi
done
echo "wrote $OUT"
grep -c '^module' "$OUT" | sed 's/^/modules: /'
