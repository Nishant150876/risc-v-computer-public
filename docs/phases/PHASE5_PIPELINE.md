[Project README](../../README.md) › [Docs index](../README.md) › **Phase 5 pipeline**

# Phase 5: the five-stage pipeline

This page describes the pipelined CPU, `cpu_pipe.sv`, how it is tested against the
single-cycle reference, and the board results. Read it before
changing the pipeline, its hazard logic or the pipeline SoC option.

> [!IMPORTANT]
> **Status (November 8, 2026): gate passed.** Lockstep, the hazard zoo, rv32ui and every C
> program pass on the pipeline in simulation: **261/261** test rows and **59/59** Python
> checks. On the Basys 3 the pipeline runs hello (UART check passed) and Fibonacci (`1A6D`),
> closes timing up to **62.5 MHz**, and measures **CPI 1.317** with the hardware counters. The
> single-cycle CPU and its 25 MHz board build are unchanged and still the default.

## 1. What was built

| File | What it does | Self-checking test |
| --- | --- | --- |
| [cpu_pipe.sv](../../rtl/core/cpu_pipe.sv) | IF, ID, EX, MEM, WB. One packed struct per pipeline register, each with a valid bit. | [cpu_pipe_tb.sv](../../tb/system/cpu_pipe_tb.sv), [lockstep_tb.sv](../../tb/system/lockstep_tb.sv), [pipe_first_pass_tb.sv](../../tb/system/pipe_first_pass_tb.sv) |
| [forward.sv](../../rtl/core/forward.sv) | EX/MEM → EX and MEM/WB → EX for rs1, rs2 and store data. Youngest wins; x0 is never forwarded. | [forward_tb.sv](../../tb/core/forward_tb.sv) |
| [hazard.sv](../../rtl/core/hazard.sv) | Load-use stall (1 cycle), taken branch/JAL/JALR flush of the 2 younger instructions, stop flush. | [hazard_tb.sv](../../tb/core/hazard_tb.sv) |
| [rv32i_pkg.sv](../../rtl/core/rv32i_pkg.sv) | `if_id_t`, `id_ex_t`, `ex_mem_t`/`mem_wb_t`, `fwd_sel_t`. | Used by all of the above |
| [bus.sv](../../rtl/soc/bus.sv) | New `READ_POSEDGE` option: reads sampled on the rising edge that ends MEM. | [bus_tb.sv](../../tb/soc/bus_tb.sv) (default mode), pipeline benches |
| [soc.sv](../../rtl/soc/soc.sv), [basys3_soc.sv](../../rtl/top/basys3_soc.sv) | `PIPELINE` selects the CPU (default 0 = single-cycle); `CPU_HZ` sets the MMCM output, UART baud and display scan. | `soc_pipe_tb`, `basys3_soc_pipe_tb`, `board_c_pipe_tb`, `board_uart_pipe_tb` |
| [clock_gen.sv](../../rtl/top/clock_gen.sv) | `CPU_HZ` parameter: CLKOUT0 divide = 1 GHz / CPU_HZ. The simulation model stays 25 MHz only. | [clock_gen_tb.sv](../../tb/top/clock_gen_tb.sv) |

`cpu_single.sv` is not modified. It stays the reference model.

## 2. How the pipeline works

| Stage | Work | Notes |
| --- | --- | --- |
| IF | Fetch PC drives RAM port A. | The RAM output register is the IF/ID instruction. A stall holds `imem_en` low so the instruction stays put. |
| ID | Decode, immediate, register read. | Register file `BYPASS=1` covers WB → ID (distance 3). |
| EX | Forwarding muxes, ALU, branch compare, next PC, store lanes, fault checks. | Branches resolve here; predict not-taken. |
| MEM | EX/MEM drives the data bus for the whole cycle. | Only a valid instruction issues an access, exactly once. MEM never stalls. |
| WB | Load lane select/extend, register write, retirement record. | The single register writer, as in the single-cycle CPU. |

**Costs.** A load followed by a user of its result costs 1 cycle (store data counts as a use).
A taken branch, JAL or JALR costs 2 cycles. A not-taken branch costs nothing.

**Stop contract (unchanged).** Faults (illegal, misaligned target, misaligned load/store) are
detected in EX, never retire and never touch the bus. ECALL/EBREAK retire. Either one flushes
the younger instructions and stops fetch; `halted` rises on the edge the stopping instruction
leaves WB. `pc` then holds the same value the single-cycle CPU stops with.

**MMIO side effects.** UART RX reads (`0x8000_0018`) pop the FIFO. With `READ_POSEDGE=1` the
bus samples the RX byte on the same rising edge that the UART pops it, so the value read is
the value popped. Flushed instructions, bubbles and the repeated decode cycle of a stall never
reach MEM with their valid bit set. [pipe_mmio.S](../../sw/tests/pipeline/pipe_mmio.S) proves it: one typed
byte survives wrong-path RX reads and a load-use stall, and is read exactly once.

**First-pass mode.** `cpu_pipe #(.DATA_HAZARDS(0))` turns off forwarding, the bypass and the
load-use stall. Control flushes stay on. Code then needs 3 NOPs between dependent
instructions; `pipe_first_pass_tb` runs such code and shows the same code without NOPs reads
stale registers.

## 3. Tests

Run from WSL at the repository root:

```bash
python3 scripts/run_tests.py
python3 -m unittest discover -s scripts/tests -v
```

Expected: `261/261 passed` and `Ran 59 tests ... OK`. Useful subsets:

| To run | Command |
| --- | --- |
| Pipeline program runner only | `python3 scripts/run_tests.py cpu_pipe_tb` |
| Lockstep only | `python3 scripts/run_tests.py lockstep` |
| Hazard zoo on all three CPU benches | `python3 scripts/run_tests.py hazard_zoo` |
| One pipeline program with a trace | `python3 scripts/run_tests.py cpu_pipe_tb:directed/hazard_zoo -v`, then rerun the printed command with `+trace` |

| Bench | Programs | What it checks |
| --- | --- | --- |
| `cpu_pipe_tb` | All 82 `cpu_tb` programs, same plusargs | Same pass rules as `cpu_tb`, plus: the access issued in MEM equals the access retired one cycle later; retired instruction equals RAM at its PC; a stall holds the fetch enable low; quiet after stop. |
| `lockstep_tb` | 65: directed, rv32ui, hazard zoo, C programs | Ordered retirement records field for field (including instructions with no register write), every bus access, then stop cause, stop PC, x1–x31 and all RAM. The first mismatch prints its index, both records and the last 4 matches. `+inject_mismatch=<n>` is a self-test. |
| Pipeline wrappers | soc, board top, board C, board UART | The Phase 3/4 board benches with `PIPELINE=1`. |

Lockstep uses a deterministic MMIO model (never TX busy, scripted RX bytes, counters that
grow per read) so CPI differences cannot change program behaviour. Programs that never halt
(`hello`, `fib`) compare a fixed retirement window.

**Mutation check.** Each of these deliberate bugs, applied one at a time, made
`cpu_pipe_tb:directed/hazard_zoo` (or `pipe_mmio` for the bus case) fail, then was reverted:
no EX/MEM forward (rs1 or rs2), no MEM/WB forward (rs1 or rs2), WB priority over MEM, x0
forwarded, no load-use stall, load-use ignoring rs2, no redirect flush, flush of ID only,
no stop flush, no register-file bypass, store data not forwarded, RAM enabled during a stall,
and a read enable not gated by the valid bit. Removing valid gating from the *write* strobes
alone was not detected: bubbles never carry a stale store in this design, so that gate is
defensive only.

## 4. CPI: single-cycle vs pipeline

Measured in simulation with the RTL cycle and instret counters (`perf_counters.sv`, the same
logic the board uses). Both CPUs retire identical instruction streams except where noted.

| Program | Instructions | Single-cycle cycles | Single CPI | Pipeline cycles | Pipeline CPI |
| --- | --: | --: | --: | --: | --: |
| `cpi_bench` (C kernels: fib, sum, sort, calls, copy) | 38,173 | 38,173 | 1.000 | 50,362 | 1.319 |
| `runtime_smoke` (C startup, libgcc divide) | 564 | 564 | 1.000 | 854 | 1.514 |
| `fib_20` (board C image, to first display write) | 128 | 128 | 1.000 | 174 | 1.359 |
| rv32ui, all 40 programs combined | 12,831 | 12,831 | 1.000 | 14,195 | 1.106 |
| `hazard_zoo` | 352 | 352 | 1.000 | 400 | 1.136 |
| directed `fib` | 185 | 185 | 1.000 | 227 | 1.227 |
| directed `branch` | 117 | 117 | 1.000 | 161 | 1.376 |
| directed `load_store` | 170 | 170 | 1.000 | 175 | 1.029 |

Small programs include 4 pipeline fill cycles. `printf_smoke` and `hello` wait on the UART,
so their instruction counts differ between CPUs and their CPI is not meaningful.

At the same clock the pipeline is slower (CPI above 1). It wins because it closes timing at
62.5 MHz, well above the break-even point of about **CPI × 25 MHz** (33 MHz). The board
measurement in section 5 agrees with this table: 1.317 on the board against 1.319 in
simulation (the board figure leaves out startup and the final display writes).

## 5. Board results

All numbers below were observed on the Basys 3 with Vivado 2025.2 on November 8, 2026.

**Clock sweep** (routed; Fmax is the fastest clock that met timing):

| CPU | MHz | WNS (ns) | WHS (ns) | LUT | FF | RAMB36 | Result |
| --- | --: | --: | --: | --: | --: | --: | --- |
| pipeline | 25 | +11.876 | +0.075 | 1,323 | 767 | 16 | pass |
| pipeline | 50 | +1.807 | +0.081 | 1,313 | 770 | 16 | pass |
| pipeline | **62.5** | **+0.134** | +0.050 | 1,346 | 772 | 16 | **pass (Fmax)** |
| pipeline | 80 | −0.642 | +0.065 | 1,419 | 773 | 16 | fail |
| pipeline | 100 | −3.745 | +0.035 | 1,429 | 773 | 16 | fail |
| single-cycle | 25 | +0.484 | +0.074 | 1,476 | 402 | 16 | pass |

The 25 MHz pipeline LUT/FF figures come from the Fibonacci build; the other rows are hello.
Clocks between 62.5 and 80 MHz were not tried. The worst path at 80 MHz runs from the block
RAM port B output to the enable pins of the ID/EX register.

**Programs on the board:**

| Program | CPU and clock | Result |
| --- | --- | --- |
| hello + `uart_check.py --all-bytes` on COM8 | pipeline, 25 MHz | pass: greeting, counter, 41/41 text bytes, all 256 byte values |
| hello + `uart_check.py --all-bytes` on COM8 | pipeline, 62.5 MHz | pass; the counter ticks every 0.375 s instead of 0.940 s (2.5×), as expected |
| Fibonacci, SW4 + SW2 on | pipeline, 25 MHz | owner observed `1A6D` |
| `cpi_report` | pipeline 25, single-cycle 25, pipeline 62.5 MHz | checksum `991d` correct, 4 identical runs each |

**CPI on the board.** [`cpi_report`](../../sw/programs/cpi_report/main.c) runs the same kernels
as `cpi_bench` ([workload.h](../../sw/programs/cpi_bench/workload.h)) and prints the hardware
cycle and instret counters over UART, read just before and after the workload:

| CPU | MHz | Cycles | Instructions | CPI | Run time |
| --- | --: | --: | --: | --: | --: |
| single-cycle | 25 | 37,623 | 37,617 | 1.000 | 1,504.9 µs |
| pipeline | 25 | 49,546 | 37,617 | 1.317 | 1,981.8 µs |
| pipeline | 62.5 | 49,546 | 37,617 | 1.317 | **792.7 µs** |

At its Fmax the pipeline finishes the workload **1.90× faster** than the single-cycle CPU.
The 6 extra single-cycle cycles are the counter reads around the workload.

```text
run 1: cycles 49546 instret 37617 CPI 1.317 checksum 991d ok
```

## 6. How to rebuild

`scripts/vivado/build.tcl` takes two optional arguments: CPU and clock in MHz. The clock must be
a 1 GHz MMCM divide in 0.125 steps (25, 40, 50, 62.5, 80, 100 are valid).

```powershell
# Windows, repository root
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc cpi_report pipe 62.5
vivado -mode batch -nojournal -nolog -source scripts/vivado/program.tcl
```

Without the extra arguments the build is the Phase 4 single-cycle 25 MHz build. Each
`basys3_soc` build also copies its reports and a one-line `summary.txt` (WNS/WHS) to
`build/vivado/<cpu>_<mhz>mhz/`. The script exits nonzero on negative slack, before writing a
bitstream. Read `cpi_report` at 115200 baud on the board's COM port.

> [!NOTE]
> At the time of these board runs, `hello` and `cpi_report` counted one second as 25,000,000
> cycles, so the 62.5 MHz counter ticked faster; the UART baud was still correct because
> `CLK_HZ` follows `CPU_HZ`. Since Phase 7 both programs use the builder's `RVC_CPU_HZ`, so a
> rebuilt image ticks once per real second at its configured clock. The 25 MHz images are
> byte-identical to the ones measured here.

Hosted [CI run #18](https://github.com/Nishant150876/risc-v-computer/actions/runs/42501805157) passed on `main` (commit `dbc1864`).
