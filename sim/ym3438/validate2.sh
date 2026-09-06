#!/usr/bin/env bash
cd "$(dirname "$0")"
NC=200000
echo "=== FM validation start $(date +%H:%M:%S), $NC cycles/seed ==="
echo "--- compile rtl ---"; bash compile.sh rtl > compile_rtl.log 2>&1 && echo "  rtl compiled" || { echo "  RTL COMPILE FAIL"; tail -6 compile_rtl.log; exit 1; }
echo "--- rtl seed1 + seed2 (full storage) concurrently ---"
bash run.sh 1 $NC > /dev/null 2>&1 &
bash run.sh 2 $NC > /dev/null 2>&1 &
wait
echo "  rtl s1: $(grep -iE '=== (PASS|FAIL)|[1-9][0-9]* mismatch' run_s1.log | tail -1 | sed 's/^# //')"
echo "  rtl s2: $(grep -iE '=== (PASS|FAIL)|[1-9][0-9]* mismatch' run_s2.log | tail -1 | sed 's/^# //')"
echo "--- compile opt ---"; bash compile.sh opt > compile_opt.log 2>&1 && echo "  opt compiled" || { echo "  OPT COMPILE FAIL"; tail -6 compile_opt.log; exit 1; }
echo "--- opt seed1 + seed2 (+OPT, output-exact) concurrently ---"
bash run.sh 1 $NC +OPT > /dev/null 2>&1 &
bash run.sh 2 $NC +OPT > /dev/null 2>&1 &
wait
echo "  opt s1: $(grep -iE '=== (PASS|FAIL)|[1-9][0-9]* mismatch' run_s1_opt.log | tail -1 | sed 's/^# //')"
echo "  opt s2: $(grep -iE '=== (PASS|FAIL)|[1-9][0-9]* mismatch' run_s2_opt.log | tail -1 | sed 's/^# //')"
echo "=== FM validation done $(date +%H:%M:%S) ==="
