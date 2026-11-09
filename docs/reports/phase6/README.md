# Phase 6 reviewed FPGA reports

Vivado **2025.2**, `xc7a35tcpg236-1`, November 8, 2026. These are the integrated
VGA design running `vga_demo`, not the earlier Phase 5 design. Both bitstreams
were built successfully; neither was programmed. No monitor was available.

| CPU | CPU clock | Pixel clock | WNS | WHS | Slice LUTs | FF | RAMB36 | DRC violations |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Single-cycle | 25 MHz | 25 MHz | +0.396 ns | +0.074 ns | 1682 | 570 | 22 | 0 |
| Pipeline | 62.5 MHz | 25 MHz | +0.313 ns | +0.024 ns | 1585 | 940 | 22 | 0 |

Both use zero DSPs and have zero unclocked registers, unconstrained internal
endpoints, multiple-clock pins, combinational loops or latch loops. The
asynchronous switches/buttons/UART and human indicator outputs retain their
documented false paths. VGA outputs have pixel-clock output-delay constraints.
The six VGA BRAMs are separate from main RAM's original sixteen.

Each configuration folder contains routed timing, utilization, hierarchical
utilization, DRC, clocks, endpoint checks and post-synthesis utilization.
The source scripts, rather than a generated Vivado project, reproduce the build.

Commands run from the repository root on Windows (Vivado on PATH):

```powershell
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc vga_demo single 25 build/phase6/vivado-single25-clean
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc vga_demo pipe 62.5 build/phase6/vivado-pipe62p5-clean
```

The optional fifth argument places generated output under ignored `build/`,
preserving previous Phase 5 artifacts. The ordinary four-argument/default build
still writes `build/vivado/`, the directory used by `program.tcl`.

The build excludes only the VGA BRAMs from automatic BRAM power optimization;
this preserves their explicit synchronous reads and prevents unsafe reset-derived
look-ahead enables. [Phase 6](../../phases/PHASE6_VGA.md) explains the correction
and the remaining physical monitor gate. No DRC severity is lowered or waived.
