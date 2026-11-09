# Vivado non-project build for the Basys 3.
#
# Reads every rtl/**/*.sv file and fpga/basys3.xdc, runs synthesis,
# placement and routing, and writes into build/vivado/ (blink uses its subset XDC):
#   <top>.bit                    the bitstream
#   timing_summary.rpt           check "WNS" is not negative
#   utilization.rpt              LUTs, flip-flops, BRAM, DSP used
#   drc.rpt, post_synth_*.rpt    extra detail for debugging
#
# Usage (Windows, repository root, Vivado on PATH):
#   vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl
#   vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_top
# Default basys3_soc first builds sw/programs/hello using WSL's RISC-V GCC.
# To retain the Phase 3 C demo: -tclargs basys3_soc fib
# Phase 5: a third argument selects the CPU (single, the default, or pipe) and
# a fourth the CPU clock in MHz (default 25; must be an MMCM divide of 1 GHz
# in 0.125 steps): 25, 40, 50, 62.5, 80 and 100 MHz are valid (divides 40, 25, 20, 16, 12.5, 10):
#   vivado ... -source scripts/vivado/build.tcl -tclargs basys3_soc hello pipe 50
# Reports for each basys3_soc build are also copied to build/vivado/<cpu>_<mhz>mhz/.
# Optional fifth argument: output directory under build/, relative to the repo.
# Example: -tclargs basys3_soc vga_demo pipe 62.5 build/phase6/vivado-pipe62p5
#
# Building and programming are separate steps: see scripts/vivado/program.tcl.
# The script exits nonzero if timing fails (negative setup or hold slack).

set part   xc7a35tcpg236-1
set top    basys3_soc
set program hello
if {[llength $argv] >= 1} { set top [lindex $argv 0] }
if {[llength $argv] >= 2} { set program [lindex $argv 1] }
set cpu    single
set mhz    25
if {[llength $argv] >= 3} { set cpu [lindex $argv 2] }
if {[llength $argv] >= 4} { set mhz [lindex $argv 3] }
if {$cpu ne "single" && $cpu ne "pipe"} { error "CPU must be single or pipe" }
if {![string is double -strict $mhz] || $mhz <= 0} { error "invalid CPU clock in MHz" }
set divide [expr {1000.0 / $mhz}]
if {$divide < 2.0 || $divide > 128.0 || abs($divide * 8.0 - round($divide * 8.0)) > 1e-6} {
    error "$mhz MHz is not a 1 GHz / (2.0..128.0 in 0.125 steps) MMCM output"
}
set cpu_hz [expr {int(round($mhz * 1000000.0))}]
set period_ns [expr {1000.0 / $mhz}]
if {![regexp {^[A-Za-z_][A-Za-z0-9_]*$} $top]} { error "invalid RTL top name" }
if {![regexp {^[A-Za-z0-9_]+$} $program]} { error "invalid software program name" }

set repo   [file normalize [file join [file dirname [info script]] .. ..]]
set outdir [file join $repo build vivado]
if {[llength $argv] >= 5} {
    set outdir [file normalize [file join $repo [lindex $argv 4]]]
    set build_root [file normalize [file join $repo build]]
    if {[string first "[string tolower $build_root]/" "[string tolower $outdir]/"] != 0} {
        error "output directory must stay inside the repository's ignored build/ tree"
    }
}
file mkdir $outdir
# Vivado writes scratch files (clockInfo.txt, .Xil/, dfx_runtime.txt) into the
# working directory. Run from the ignored output folder so they never land in
# the repository root. Every path below is absolute, so this is safe.
cd $outdir
# A failed build must not leave an older target bitstream appearing current.
set target_bit [file normalize [file join $outdir $top.bit]]
if {[file dirname $target_bit] ne $outdir} { error "bitstream path escapes output folder" }
if {[file exists $target_bit]} {
    if {![file isfile $target_bit]} { error "bitstream target is not a regular file" }
    file delete $target_bit
}

# Collect sources: packages (*_pkg.sv) first, then everything else.
proc find_sv {dir} {
    set files [glob -nocomplain -directory $dir -types f *.sv]
    foreach sub [glob -nocomplain -directory $dir -types d *] {
        set files [concat $files [find_sv $sub]]
    }
    return $files
}
set all  [lsort [find_sv [file join $repo rtl]]]
set pkgs [lsearch -all -inline -glob $all *_pkg.sv]
set rest [lsearch -all -inline -not -glob $all *_pkg.sv]
set srcs [concat $pkgs $rest]
if {[llength $srcs] == 0} { error "no .sv files found under rtl/" }

puts "== Top: $top   Part: $part"
puts "== Sources:"
foreach f $srcs { puts "   $f" }

read_verilog -sv $srcs
if {$top eq "basys3_top"} {
    read_xdc [file join $repo fpga basys3_blink.xdc]
} else {
    read_xdc [file join $repo fpga basys3.xdc]
}

if {$top eq "basys3_soc"} {
    set linux_repo [string trim [exec wsl --distribution Ubuntu --exec wslpath -u $repo]]
    puts "== Building the RV32I $program image in WSL"
    puts [exec wsl --distribution Ubuntu --exec python3 \
        $linux_repo/scripts/build_software.py $program --output-dir $linux_repo/build/software/$program --cpu-hz $cpu_hz]
    set image [file normalize [file join $repo build software $program $program.mem]]
    if {![file exists $image]} { error "software build did not produce $image" }
    set font [file normalize [file join $repo rtl mem font_rom.mem]]
    if {![file exists $font]} { error "missing font ROM; run scripts/font2mem.py" }
    puts "== CPU: $cpu at $mhz MHz (CPU_HZ=$cpu_hz), VGA pixel clock fixed at 25 MHz"
    synth_design -top $top -part $part -generic [format {INIT_FILE="%s"} $image] \
        -generic PIPELINE=[expr {$cpu eq "pipe" ? 1 : 0}] -generic CPU_HZ=$cpu_hz \
        -generic [format {FONT_FILE="%s"} $font]
} else {
    synth_design -top $top -part $part
}
report_utilization     -file [file join $outdir post_synth_utilization.rpt]
report_timing_summary  -file [file join $outdir post_synth_timing.rpt]

if {$top eq "basys3_soc"} {
    # BRAM power optimization adds look-ahead enables from downstream valid
    # logic. On this dual-clock display it traced through the pixel reset
    # synchronizer and created async BRAM enables (REQP-1839). Keep the RTL's
    # synchronous pixel reads; exclude only VGA RAM/ROM from this optimization.
    # AMD UG835: opt_design / set_power_opt -exclude_cells.
    set display_brams [get_cells -hier -quiet -filter {REF_NAME =~ RAMB* && NAME =~ *u_soc/u_vga/*}]
    if {[llength $display_brams] < 4} { error "VGA display memories/font did not infer block RAM" }
    set_power_opt -exclude_cells $display_brams
}
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -max_paths 10 -file [file join $outdir timing_summary.rpt]
report_utilization                 -file [file join $outdir utilization.rpt]
report_utilization -hierarchical   -file [file join $outdir hierarchical_utilization.rpt]
report_drc                         -file [file join $outdir drc.rpt]
report_clocks                      -file [file join $outdir clocks.rpt]
check_timing -verbose               -file [file join $outdir check_timing.rpt]
if {[llength [get_drc_violations -quiet]] != 0} {
    error "DRC violations remain; see $outdir/drc.rpt (no bitstream written)"
}

if {$top eq "basys3_soc"} {
    set cpu_clock [get_clocks -of_objects [get_pins u_clock/u_cpu_clock/O]]
    if {[llength $cpu_clock] != 1 || abs([get_property PERIOD $cpu_clock] - $period_ns) > 0.01} {
        error "CPU clock is not the constrained $mhz MHz MMCM output"
    }
    set pixel_clock [get_clocks -of_objects [get_pins u_clock/u_pixel_clock/O]]
    if {[llength $pixel_clock] != 1 || abs([get_property PERIOD $pixel_clock] - 40.0) > 0.01} {
        error "VGA pixel clock is not the constrained 25 MHz MMCM output"
    }
    set main_brams [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36* && NAME =~ *u_soc/u_ram/*}]
    if {[llength $main_brams] != 16} { error "expected 16 RAMB36s for main RAM alone" }
    set vga_brams [get_cells -hier -quiet -filter {REF_NAME =~ RAMB* && NAME =~ *u_soc/u_vga/*}]
    if {[llength $vga_brams] < 4} { error "VGA display memories/font did not infer block RAM" }
}

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "== Worst setup slack (WNS): $wns ns   Worst hold slack (WHS): $whs ns"
if {$top eq "basys3_soc"} {
    set rundir [file join $outdir "${cpu}_${mhz}mhz"]
    file mkdir $rundir
    foreach rpt {timing_summary.rpt utilization.rpt drc.rpt clocks.rpt check_timing.rpt} {
        file copy -force [file join $outdir $rpt] [file join $rundir $rpt]
    }
    set fd [open [file join $rundir summary.txt] w]
    puts $fd "cpu=$cpu mhz=$mhz program=$program wns=$wns whs=$whs"
    close $fd
}
if {$wns eq "" || $whs eq "" || $wns < 0 || $whs < 0} {
    puts "== TIMING FAILED: negative slack, see build/vivado/timing_summary.rpt"
    exit 1
}
puts "== TIMING MET"
write_bitstream -force [file join $outdir $top.bit]
puts "== Bitstream: [file join $outdir $top.bit]"
