# Script: impl.tcl
# Description: Runs implementation and emits reports and a bitstream.
set project_path [lindex $argv 0]
open_project $project_path
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
open_run impl_1
report_utilization -file utilization_impl.rpt
report_timing_summary -file timing_impl.rpt
