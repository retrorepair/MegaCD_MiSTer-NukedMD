#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
echo "=== FM full validation $(date +%H:%M:%S) ==="
echo "--- compile rtl (1:1) ---"; bash compile.sh rtl > compile_rtl.log 2>&1 && echo "compiled" || { echo "COMPILE FAIL"; tail -5 compile_rtl.log; exit 1; }
for s in 1 2; do echo "--- rtl seed $s x1e6 ---"; bash run.sh $s 1000000 > /dev/null 2>&1 || true; tail -1 "run_s${s}.log" | sed 's/^# //'; done
echo "--- compile opt (collapsed) ---"; bash compile.sh opt > compile_opt.log 2>&1 && echo "compiled" || { echo "COMPILE FAIL"; tail -5 compile_opt.log; exit 1; }
for s in 1 2; do echo "--- opt seed $s x1e6 +OPT ---"; bash run.sh $s 1000000 +OPT > /dev/null 2>&1 || true; tail -1 "run_s${s}_opt.log" | sed 's/^# //'; done
echo "=== done $(date +%H:%M:%S) ==="
echo "== summary (PASS/mismatch lines) =="
grep -h -iE '=== (PASS|FAIL)|mismatch' run_s1.log run_s2.log run_s1_opt.log run_s2_opt.log 2>/dev/null | grep -iE 'PASS|FAIL|[1-9].*mismatch' | tail -8
