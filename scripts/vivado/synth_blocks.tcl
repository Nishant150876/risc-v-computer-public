# Out-of-context Vivado synthesis check for the CPU blocks (Phases 1 and 2).
#
# build.tcl only synthesizes the modules under its top level, and the CPU
# blocks are not connected to the blink top yet. This script synthesizes each
# block on its own, so Vivado proves it is synthesizable and latch-free, and
# writes a utilization report per block into build/vivado/blocks/.
#
# Usage (Windows, repository root, Vivado on PATH):
#   vivado -mode batch -nojournal -nolog -source scripts/vivado/synth_blocks.tcl
#
# The script exits nonzero if synthesis fails, a latch is inferred, or the
# default 64 KB RAM does not infer 16 RAMB36s. Summary counts are primitive
# cells, not packed LUT sites; use the utilization reports for site totals.

set part   xc7a35tcpg236-1
# Phase 1 blocks, then Phase 2: next_pc, lsu, the 64 KB ram (expect 16
# RAMB36 block RAMs) and the whole single-cycle CPU without its memory.
set blocks {alu branch_unit decoder imm_gen regfile next_pc lsu ram cpu_single}

set repo   [file normalize [file join [file dirname [info script]] .. ..]]
set outdir [file join $repo build vivado blocks]
file mkdir $outdir
cd $outdir

# Packages (*_pkg.sv) first, then every core and memory source.
set core [file join $repo rtl core]
set srcs [list [file join $core rv32i_pkg.sv]]
foreach f [lsort [glob [file join $core *.sv] [file join $repo rtl mem *.sv]]] {
    if {![string match *_pkg.sv $f]} { lappend srcs $f }
}

set summary {}
set failed  0
read_verilog -sv $srcs
foreach block $blocks {
    puts "== Synthesizing $block (out of context)"
    catch {close_design}
    if {[catch {synth_design -top $block -part $part -mode out_of_context} msg]} {
        puts "== $block: SYNTHESIS FAILED: $msg"
        lappend summary [format "%-12s FAILED" $block]
        incr failed
        continue
    }
    report_utilization -file [file join $outdir ${block}_utilization.rpt]
    set luts    [llength [get_cells -hier -quiet -filter {IS_PRIMITIVE == 1 && PRIMITIVE_GROUP == LUT}]]
    set ffs     [llength [get_cells -hier -quiet -filter {REF_NAME =~ FD*}]]
    set lutram  [llength [get_cells -hier -quiet -filter {IS_PRIMITIVE == 1 && PRIMITIVE_GROUP == DMEM}]]
    set latches [llength [get_cells -hier -quiet -filter {REF_NAME =~ LD*}]]
    set bram    [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB*}]]
    set bram36  [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36*}]]
    lappend summary [format "%-12s LUT %5d   FF %5d   DMEM %3d   BRAM %2d   latch %d" \
        $block $luts $ffs $lutram $bram $latches]
    if {$latches > 0} {
        puts "== $block: LATCH INFERRED"
        incr failed
    }
    if {$block eq "ram" && ($bram36 != 16 || $bram != 16)} {
        puts "== ram: expected 16 RAMB36 block RAMs, got $bram36 RAMB36 / $bram total"
        incr failed
    }
}

puts "\n== CPU block synthesis ($part, each block alone)"
foreach line $summary { puts "   $line" }
puts "== Reports: $outdir"
if {$failed > 0} {
    puts "== BLOCK SYNTHESIS FAILED ($failed problem(s))"
    exit 1
}
puts "== ALL BLOCKS SYNTHESIZED, NO LATCHES"
