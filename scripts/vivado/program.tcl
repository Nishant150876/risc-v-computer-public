# Program the Basys 3 over USB (JTAG) with a bitstream from build.tcl.
# The board must be plugged in and switched on. This loads volatile SRAM:
# the design is lost at power-off (flash programming comes later).
#
# Usage (Windows, repository root):
#   vivado -mode batch -nojournal -nolog -source scripts/vivado/program.tcl
#   vivado -mode batch -nojournal -nolog -source scripts/vivado/program.tcl -tclargs <top_module>

set top basys3_soc
if {[llength $argv] >= 1} { set top [lindex $argv 0] }
set repo [file normalize [file join [file dirname [info script]] .. ..]]
set bit  [file join $repo build vivado $top.bit]
if {![file exists $bit]} { error "missing $bit: run scripts/vivado/build.tcl first" }

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a35t*] 0]
if {$dev eq ""} { error "no xc7a35t found: is the Basys 3 connected and on?" }
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "== Programmed $dev with $bit"
close_hw_target
disconnect_hw_server
close_hw_manager
