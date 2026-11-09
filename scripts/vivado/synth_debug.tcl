# Single-cycle debug profile synthesis only. No board programming or pin claims.
# Run from the repository root with Vivado -mode batch -source this file.
set repo [file normalize [file join [file dirname [info script]] .. ..]]
set out [file join $repo build debug-sim synth]
file mkdir $out
proc sources {dir} {
    set result [glob -nocomplain -directory $dir -types f *.sv]
    foreach sub [glob -nocomplain -directory $dir -types d *] { set result [concat $result [sources $sub]] }
    return $result
}
cd $repo
set all [lsort [sources [file join $repo rtl]]]
set packages [lsearch -all -inline -glob $all *_pkg.sv]
set rest [lsearch -all -inline -not -glob $all *_pkg.sv]
read_verilog -sv [concat $packages $rest]
synth_design -top dbg_system -part xc7a35tcpg236-1 -mode out_of_context -flatten_hierarchy rebuilt
write_checkpoint -force [file join $out dbg_system_synth.dcp]
create_clock -name clk -period 40.000 [get_ports clk]
set_input_delay 0 -clock clk [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay 0 -clock clk [all_outputs]
opt_design
set utilization [report_utilization -return_string]
set utilization_file [open [file join $out utilization.rpt] w]
puts $utilization_file $utilization
close $utilization_file
report_utilization -hierarchical -hierarchical_depth 4 -file [file join $out hierarchy.rpt]
write_checkpoint -force [file join $out dbg_system.dcp]
# Count occupied LUT sites after LUT combining, as Vivado's device-budget report does.
# Counting LUT primitive cells separately double-counts compatible LUT5/LUT6 pairs.
if {![regexp {\|\s*Slice LUTs\*?\s*\|\s*([0-9]+)\s*\|} $utilization unused lut_sites]} {
    error "Could not read Slice LUT usage; refusing to assume that the profile fits."
}
if {$lut_sites > 20800} {
    error "Debug profile exceeds Basys 3 LUT capacity; resource optimization required. Timing/placement gates not run."
}
report_timing_summary -report_unconstrained -max_paths 10 -file [file join $out timing_summary.rpt]
check_timing -verbose -file [file join $out check_timing.rpt]
puts "DEBUG_PROFILE: synthesis completed; results in $out. Placement, routing, pins and physical gates remain separate."
exit
