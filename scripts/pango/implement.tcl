# Offline implementation of an already compiled/synthesized candidate project.
# Set HGB_PDS_PROJECT to the existing project, then use pds_shell -file.
# No bitstream generation, JTAG connection, or device configuration commands.
if {![info exists ::env(HGB_PDS_PROJECT)] || ![file isfile $::env(HGB_PDS_PROJECT)]} {
    error "HGB_PDS_PROJECT must name the compiled/synthesized candidate .pds"
}
open_project $::env(HGB_PDS_PROJECT)
set hgb_threads 8
if {[info exists ::env(HGB_PDS_THREADS)]} { set hgb_threads $::env(HGB_PDS_THREADS) }
if {![string is integer -strict $hgb_threads] || $hgb_threads < 0} {
    error "HGB_PDS_THREADS must be a nonnegative integer (0 means automatic)"
}
set_option max_threads $hgb_threads
set hgb_memory_gate [file join [file dirname [info script]] memory_gate.ps1]
set hgb_memory_logs [file join [file dirname $::env(HGB_PDS_PROJECT)] memory]
proc hgb_check_memory {phase} {
    global hgb_memory_gate hgb_memory_logs
    # 每个耗内存阶段前重新查询 Windows；查询失败或不足时 exec 抛错，停止该阶段。
    puts [exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File $hgb_memory_gate -LogDirectory $hgb_memory_logs -Phase $phase]
}
hgb_check_memory dev_map
dev_map -force_to_run
hgb_check_memory place
place -mode normal -optimize_gp_recovery TRUE -logic_optimize_lut6d FALSE
hgb_check_memory route
route -route_mode normal -slack_weight 90 -optimize_routing_recovery TRUE
hgb_check_memory route_optimize
route_optimize
report_timing
