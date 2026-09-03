project_open MegaCD
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 40 -detail summary -file output_files/worst_paths.txt
report_timing -setup -npaths 3 -detail full_path -file output_files/worst_paths_full.txt
project_close
