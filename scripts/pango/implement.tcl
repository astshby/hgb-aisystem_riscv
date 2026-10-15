# Offline implementation of an already compiled/synthesized candidate project.
# Set HGB_PDS_PROJECT to the existing project, then use pds_shell -file.
# No bitstream generation, JTAG connection, or device configuration commands.
if {![info exists ::env(HGB_PDS_PROJECT)] || ![file isfile $::env(HGB_PDS_PROJECT)]} {
    error "HGB_PDS_PROJECT must name the compiled/synthesized candidate .pds"
}
open_project $::env(HGB_PDS_PROJECT)
set hgb_threads 1
if {[info exists ::env(HGB_PDS_THREADS)]} { set hgb_threads $::env(HGB_PDS_THREADS) }
if {![string is integer -strict $hgb_threads] || $hgb_threads < 0} {
    error "HGB_PDS_THREADS must be a nonnegative integer (0 means automatic)"
}
set_option max_threads $hgb_threads
dev_map -force_to_run
place
route
route_optimize
report_timing
