# Report the worst failing setup paths. Run after a build:
#   quartus_sta -t tools/sta_paths.tcl
project_open MegaCD
create_timing_netlist -model slow
read_sdc
update_timing_netlist
foreach_in_collection p [get_timing_paths -setup -npaths 25 -detail summary] {
	set slack [get_path_info $p -slack]
	if {$slack >= 0} { continue }
	puts [format "%8.3f  %-70s -> %s" $slack \
		[get_node_info -name [get_path_info $p -from]] \
		[get_node_info -name [get_path_info $p -to]]]
}
delete_timing_netlist
project_close
