#!/usr/bin/env bash
RF="/c/Users/joelw/AppData/Local/Temp/claude/C--Users-joelw-Documents-MegaCD-MiSTer-New/2ec3372d-bd5a-402d-ac38-21cf2da5ce03/scratchpad/rtlfast"; H="C:/Users/joelw/Documents/MegaCD_MiSTer_New/MegaCD_MiSTer-master/sim/ym3438"
a=0;b=0
while [ $a -eq 0 ] || [ $b -eq 0 ]; do
  grep -qE "cycles, 0 mismatches|STOP at first mismatch" "$RF/fast_s1.log" 2>/dev/null && a=1
  grep -qE "cycles, 0 mismatches|STOP at first mismatch" "$RF/fast_s2.log" 2>/dev/null && b=1
  sleep 30
done
echo "FAST DONE"
cd "$H"; bash run.sh 3 200000 > full_s3b.out 2>&1
echo "=== FAST SEED1 (1M outputs) ==="; grep -E "PASS:|MISMATCH @|STOP at" "$RF/fast_s1.log" | tail -2
echo "=== FAST SEED2 (1M outputs) ==="; grep -E "PASS:|MISMATCH @|STOP at" "$RF/fast_s2.log" | tail -2
echo "=== FULL-STORAGE 200k ==="; grep -E "PASS:|MISMATCH @|STOP at" "$H/run_s3.log" 2>/dev/null | tail -2
