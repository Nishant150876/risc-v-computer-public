# Write a bitstream into the Basys 3 configuration flash, so the design loads
# by itself at every power-on (JTAG programming with program.tcl is lost at
# power-off). Build the bitstream first with build.tcl.
#
# The flash chip differs between board revisions, so its Vivado part name is a
# required argument. Read the marking on the 8-pin chip next to the FPGA, then
# list the matching Vivado names:
#   vivado -mode batch -nojournal -nolog -source scripts/vivado/flash.tcl -tclargs list
# Program (Windows, repository root, board on USB and switched on):
#   vivado -mode batch -nojournal -nolog -source scripts/vivado/flash.tcl -tclargs <flash_part>
#   vivado ... -tclargs <flash_part> build/phase7/vivado-primes-single25/basys3_soc.bit
#
# Afterwards set jumper JP1 to QSPI and power-cycle the board. The flash is
# erased only over the range the image needs, and reprogramming replaces it.

set repo [file normalize [file join [file dirname [info script]] .. ..]]
set build_root [file normalize [file join $repo build]]

if {[llength $argv] < 1} {
    error "usage: -tclargs list | <flash_part> \[bitstream under build/\]"
}
set flash_part [lindex $argv 0]

if {$flash_part eq "list"} {
    # Families Digilent has fitted to Basys 3 boards; confirm against the chip.
    foreach pattern {s25fl032* s25fl128s* mx25l32* is25lp032* n25q32*} {
        foreach name [get_cfgmem_parts -quiet $pattern] {
            if {[string match *spi-x1_x2_x4* $name]} { puts "  $name" }
        }
    }
    exit 0
}

set bit [file join $build_root vivado basys3_soc.bit]
if {[llength $argv] >= 2} { set bit [file normalize [file join $repo [lindex $argv 1]]] }
if {[string first "[string tolower $build_root]/" "[string tolower $bit]"] != 0} {
    error "bitstream must be inside the repository's ignored build/ tree"
}
if {![file exists $bit]} { error "missing $bit: run scripts/vivado/build.tcl first" }

set part [lindex [get_cfgmem_parts -quiet $flash_part] 0]
if {$part eq ""} { error "unknown flash part $flash_part: run with -tclargs list" }
if {![string match *spi-x1_x2_x4* $part]} { error "$part is not a quad-SPI x1/x2/x4 part" }

# The default bitstream configures over a single data line, so write an SPIx1 image.
set mcs [file rootname $bit].mcs
# Flash density in MB, by the families listed above (Basys 3 boards carry 32 Mbit parts).
set size_mb 0
foreach {pattern mb} {s25fl032* 4 s25fl128s* 16 mx25l32* 4 is25lp032* 4 n25q32* 4} {
    if {[string match $pattern $part]} { set size_mb $mb; break }
}
if {$size_mb == 0} { error "no known size for $part; add it to flash.tcl" }
write_cfgmem -force -format mcs -size $size_mb -interface SPIx1 \
    -loadbit "up 0x00000000 $bit" -file $mcs
puts "== Flash image: $mcs"

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a35t*] 0]
if {$dev eq ""} { error "no xc7a35t found: is the Basys 3 connected and on?" }
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

create_hw_cfgmem -hw_device $dev -mem_dev $part
set cfgmem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.ADDRESS_RANGE use_file $cfgmem
set_property PROGRAM.FILES [list $mcs] $cfgmem
set_property PROGRAM.BLANK_CHECK 0 $cfgmem
set_property PROGRAM.ERASE 1 $cfgmem
set_property PROGRAM.CFG_PROGRAM 1 $cfgmem
set_property PROGRAM.VERIFY 1 $cfgmem
set_property PROGRAM.CHECKSUM 0 $cfgmem

# Vivado first loads a small helper design into the FPGA that bridges JTAG to the flash.
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
program_hw_cfgmem -hw_cfgmem $cfgmem
puts "== Programmed and verified $part with $bit"

# Reload the FPGA from flash now, the same way a power-on does.
boot_hw_device $dev
puts "== Booted from flash. Set JP1 to QSPI so this also happens at power-on."
close_hw_target
disconnect_hw_server
close_hw_manager
