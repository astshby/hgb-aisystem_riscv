# Module: implement_cdc
# Description: Implement existing synthesis with native-bound CDC constraints.
# No compile, synthesis, bitstream generation or device programming commands.
if {![info exists ::env(HGB_PDS_PROJECT)] || ![file isfile $::env(HGB_PDS_PROJECT)]} {
    error "HGB_PDS_PROJECT must name the compiled/synthesized .pds"
}
set hgb_project_root [file normalize [file dirname $::env(HGB_PDS_PROJECT)]]
set hgb_script_root [file normalize [file dirname [info script]]]
foreach hgb_constraint {backend_sync.lcf backend_cdc.scf} {
    if {![file isfile [file join $hgb_project_root $hgb_constraint]]} {
        error "Missing native-bound CDC input: $hgb_constraint"
    }
}
open_project $::env(HGB_PDS_PROJECT)
# 在映射前加载已由原生引脚/时钟树核验的约束，保留同域和DDR PHY真实路径检查。
add_constraint [file join $hgb_project_root backend_sync.lcf]
add_constraint [file join $hgb_project_root backend_cdc.scf]
puts "HGB_CDC_CONSTRAINTS_LOADED"
set hgb_threads 8
if {[info exists ::env(HGB_PDS_THREADS)]} { set hgb_threads $::env(HGB_PDS_THREADS) }
if {![string is integer -strict $hgb_threads] || $hgb_threads < 0} {
    error "HGB_PDS_THREADS must be a nonnegative integer (0 means automatic)"
}
set_option max_threads $hgb_threads
set hgb_memory_gate [file join $hgb_script_root memory_gate.ps1]
set hgb_memory_logs [file join $hgb_project_root memory]
proc hgb_check_memory {phase} {
    global hgb_memory_gate hgb_memory_logs
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
report_timing -max_path 100 -nworst 3 -report_logic_level_distribution -report_max_skew -report_exception TRUE
puts "HGB_CDC_PHYSICAL_DONE"
