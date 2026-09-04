project_open MegaCD
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 10 -detail summary -to [get_registers {emu:emu|MCD:MCD|ASIC:ASIC|M68K_ROM_DO[*]}] -file output_files/p_romdo.txt
report_timing -setup -npaths 10 -detail summary -to [get_registers {emu:emu|MCD:MCD|ASIC:ASIC|ROMS.*}] -file output_files/p_roms.txt
report_timing -setup -npaths 10 -detail summary -from [get_registers {emu:emu|MCD:MCD|ASIC:ASIC|*}] -to [get_registers {emu:emu|md_board:md_board|VD[*]}] -file output_files/p_vd.txt
report_timing -setup -npaths 10 -detail summary -from [get_registers {emu:emu|sdram:sdram|*}] -file output_files/p_sdram.txt
report_timing -hold -npaths 10 -detail summary -to [get_registers {emu:emu|MCD:MCD|ASIC:ASIC|M68K_ROM_DO[*]}] -file output_files/p_romdo_hold.txt
project_close
