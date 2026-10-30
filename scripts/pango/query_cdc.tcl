# Module: query_cdc
# Description: Query exact CDC pins in an existing synthesized design; no synthesis or implementation action.
if {![info exists ::env(HGB_PDS_PROJECT)] || ![file isfile $::env(HGB_PDS_PROJECT)]} {
    error "HGB_PDS_PROJECT must name an existing synthesized .pds"
}
set hgb_project_root [file dirname $::env(HGB_PDS_PROJECT)]
set hgb_audit [file join $hgb_project_root cdc-audit audit.tcl]
if {![file isfile $hgb_audit]} {
    error "Prepare cdc-audit/audit.tcl from this synthesis before native queries"
}
set hgb_memory_gate [file join [file dirname [info script]] memory_gate.ps1]
puts [exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File $hgb_memory_gate -LogDirectory [file join $hgb_project_root memory] -Phase cdc_query]
open_project $::env(HGB_PDS_PROJECT)
set_option max_threads 8
# 原生引脚只在已综合设计的动作上下文中解析，不能对延迟句柄冒充已查询对象。
open_design -action [get_actions synthesize -of_objects [get_tasks syn_1]] -file $hgb_audit
puts "HGB_CDC_QUERY_DONE"
