# Script: create_project.tcl
# Description: Reproducibly creates the Zynq-7020 RTL project.
set xlen [lindex $argv 0]
if {$xlen eq ""} { set xlen 32 }

set repo_root [file normalize [file join [file dirname [info script]] ../..]]
set project_dir [file join $repo_root vivado-workspace project-rv$xlen]
create_project -force rhbyv_cpu $project_dir -part xc7z020clg400-1
set_property top cpu_top [current_fileset]
set_property verilog_define CORE_XLEN=$xlen [current_fileset]

set filelist [open [file join $repo_root scripts rtl_files.f] r]
while {[gets $filelist line] >= 0} {
    if {$line ne ""} { read_verilog -sv [file join $repo_root $line] }
}
close $filelist
read_verilog -sv [file join $repo_root vsrc cpu reset_sync.sv]
read_verilog -sv [file join $repo_root vsrc cpu cpu_top.sv]
update_compile_order -fileset sources_1
save_project
