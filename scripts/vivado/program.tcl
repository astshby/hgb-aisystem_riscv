# Script: program.tcl
# Description: Programs the first attached device with a supplied bitstream.
set bitstream [lindex $argv 0]
open_hw_manager
connect_hw_server
open_hw_target
set device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE $bitstream $device
program_hw_devices $device
