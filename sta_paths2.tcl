project_open MegaCD
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 15 -detail summary -to_clock [get_clocks {*counter[1].output_counter|divclk}] -file output_files/worst_53m.txt
report_timing -setup -npaths 25 -detail summary -to_clock [get_clocks {*counter[0].output_counter|divclk}] -to [remove_from_collection [get_registers *] [get_registers {emu:emu|m68k_data[*]}]] -file output_files/worst_107m_nocheat.txt
project_close
