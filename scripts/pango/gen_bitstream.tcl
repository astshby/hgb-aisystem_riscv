# Module: gen_bitstream
# Description: Generate the configured bitstream from the routed project; no programming or JTAG.
if {![info exists ::env(HGB_PDS_PROJECT)] || ![file isfile $::env(HGB_PDS_PROJECT)]} {
    error "HGB_PDS_PROJECT must name the routed .pds"
}
set hgb_root [file dirname [info script]]
set hgb_threads 8
if {[info exists ::env(HGB_PDS_THREADS)]} { set hgb_threads $::env(HGB_PDS_THREADS) }
open_project $::env(HGB_PDS_PROJECT)
set_option max_threads $hgb_threads
# 位流生成前同样检查内存余量，避免在低内存时产生不完整产物。
puts [exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File [file join $hgb_root memory_gate.ps1] -LogDirectory [file join $hgb_root memory] -Phase gen_bit_stream]
gen_bit_stream
puts "HGB_BITSTREAM_DONE"
