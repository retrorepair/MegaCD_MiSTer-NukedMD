set fp [open "sigs_die.txt" w]
foreach s [lsort [find signals -r /tb_ym3438/die/*]] { puts $fp $s }
close $fp
set fp2 [open "sigs_dut.txt" w]
foreach s [lsort [find signals -r /tb_ym3438/dut/*]] { puts $fp2 $s }
close $fp2
quit -f
