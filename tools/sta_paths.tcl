# Report the worst failing setup paths, grouped, for the 107 MHz clk_ram domain.
#   quartus_sta -t tools/sta_paths.tcl MegaCD
project_open MegaCD
create_timing_netlist -model slow
read_sdc
update_timing_netlist
puts "=== summary ==="
report_clock_fmax_summary -panel_name fmax
foreach_in_collection p [get_timing_paths -setup -npaths 40 -detail summary] {
	set slack [get_path_info $p -slack]
	if {$slack >= 0} { continue }
	puts [format "%8.3f  %s  ->  %s" $slack \
		[get_node_info -name [get_path_info $p -from]] \
		[get_node_info -name [get_path_info $p -to]]]
}
delete_timing_netlist
project_close
