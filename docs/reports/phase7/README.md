# Phase 7 routed FPGA reports

Six independent Vivado 2025.2 builds, November 8, 2026. All use the existing
`basys3_soc` RTL with either cpu_single at 25 MHz or cpu_pipe at 62.5 MHz; VGA pixels
stay at 25 MHz. No new RTL or constraints were introduced in Phase 7.

| Program | CPU / MHz | WNS (ns) | WHS (ns) | LUTs | FFs | RAMB36 | DSP | DRC violations |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| primes | single / 25 | +0.396 | +0.074 | 1,682 | 570 | 22 | 0 | 0 |
| primes | pipe / 62.5 | +0.313 | +0.024 | 1,585 | 940 | 22 | 0 | 0 |
| life | single / 25 | +0.396 | +0.074 | 1,682 | 570 | 22 | 0 | 0 |
| life | pipe / 62.5 | +0.313 | +0.024 | 1,585 | 940 | 22 | 0 | 0 |
| snake | single / 25 | +0.396 | +0.074 | 1,682 | 570 | 22 | 0 | 0 |
| snake | pipe / 62.5 | +0.313 | +0.024 | 1,585 | 940 | 22 | 0 | 0 |

Each directory contains routed timing, utilization, DRC, clocks, check-timing and
the build script's summary. Every build has zero unconstrained internal endpoints.
The asynchronous board-input false paths and deliberate board-output delay policy
remain the existing documented constraint contract; zero internal unconstrained
endpoints does not imply an external monitor or serial link was physically tested.

The figures repeat because only the software initialization image changes.
These are fresh builds, not copies of Phase 6 reports. Main RAM still infers 16
RAMB36 blocks, and VGA adds six. The existing VGA BRAM power-optimization exclusion
is retained; no DRC severity was waived.

[builds.json](builds.json) records each clock/profile, local baseline commit, bitstream
path/hash and observed results. [build-inputs.sha256](build-inputs.sha256) fingerprints
the build RTL, constraints, C runtime/program sources, ROM and build scripts. The
bitstreams themselves stay in ignored `build/phase7/`. Builds came from uncommitted local
changes on top of `b84f8d4`, not a newly published commit.

Reproduce from the repository root in Windows PowerShell with Vivado on PATH:

```powershell
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc primes single 25 build/phase7/vivado-primes-single25
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc primes pipe 62.5 build/phase7/vivado-primes-pipe62p5
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc life single 25 build/phase7/vivado-life-single25
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc life pipe 62.5 build/phase7/vivado-life-pipe62p5
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc snake single 25 build/phase7/vivado-snake-single25
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc snake pipe 62.5 build/phase7/vivado-snake-pipe62p5
```

Actual builds used the verified full Vivado executable path when it was not on PATH.
Builds are not board programming, a new frequency sweep, measured power or the
cold-power demo gate. See [Phase 7](../../phases/PHASE7_DEMOS.md) for acceptance.

[verification.json](verification.json) records the 277/277 regression, 80/80 Python/native
checks, 48/48 lint results and full-board demo measurements. The decoded prime transcripts
are [single 25 MHz](primes-single25.txt) and [pipe 62.5 MHz](primes-pipe62p5.txt), normalized
to LF for review; raw UART-capture hashes are recorded separately in the verification JSON.
Both raw captures passed `primes_check.py --capture-file` on Windows.

[source-rebuild.json](source-rebuild.json) records a clean source-only C rebuild: six
images at both clocks match the previously tested/built hashes. It copied no generated
outputs or Git metadata. The official test submodule was unnecessary for this C-only
check and was not exported. This is an automated self-check, not the independent
human/full-system rebuild gate.
