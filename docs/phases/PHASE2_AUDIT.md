[Project README](../../README.md) › [Docs index](../README.md) › **Phase 2 audit**

# Phase 2 repository audit — November 7, 2026

> [!IMPORTANT]
> **Phase 2 is implemented and verified. Its gate passed on November 7, 2026** ([GitHub Actions run #9](https://github.com/Nishant150876/risc-v-computer/actions/runs/42410438947), commit `a909c3f`).
> Final results: **63/63 regression tests**, **27/27 utility/harness tests**, **7/7 deliberate
> RTL mutations rejected**, **11/11 standalone RTL lint checks**, and **9/9 Vivado block
> syntheses without latches**. RAM infers 16 RAMB36s. The blink build meets timing; integrated
> CPU timing was still a Phase 3 task at this audit snapshot.

**Subsequent result:** [Phase 3](PHASE3_BOARD_C.md) passed its board gate with routed CPU
timing met at 25 MHz. It records the current 95 regression runs and 40 Python checks; this
page preserves the earlier audit's scope and measurements.

This review applies the supplied audit brief to the existing Phase 2 implementation. Its
leftover “before Phase 2” wording does not authorize starting Phase 3 or replacing the CPU.
The architecture, memory map, instruction policy and owner-approved reset-free register file
are preserved.

## A. Repository understanding

The repository builds an RV32I computer for the Basys 3. The working CPU is the single-cycle
reference; the five-stage pipeline and portable Tab5 debugger remain planned. Code and data
share 64 KiB of synchronous dual-port RAM. Fetch reads the next PC at a rising edge; data
accesses happen at the falling edge; register writes and retirement finish at the following
rising edge. This proves functional ordering, not real FPGA path delay.

| Area | Responsibility and relationships |
| --- | --- |
| `rtl/core/rv32i_pkg.sv` | Shared ISA/control types and retirement/stop records. Decoder controls ALU operands, immediate selection, branch/jump, LSU and write-back. |
| ALU, register file, immediate generator, decoder, branch unit | Phase 1 blocks reused by `cpu_single`; x0 is immutable and the CPU uses `BYPASS=0`. |
| `next_pc`, `lsu`, `ram`, `cpu_single` | Phase 2 integration, alignment policy, byte lanes, synchronous memory and architectural completion. |
| `tb/` | Ten unit benches plus the CPU program runner; register and memory observations check retirement. |
| `sw/tests/env/`, `sw/tests/`, `sw/riscv-tests/` | Custom CSR-free environment, 13 directed programs and the pinned official rv32ui suite. |
| `scripts/`, `.github/`, `.vscode/` | Simulation/software builds, Vivado flow, CI and shared editor tasks. |
| `rtl/top/`, `fpga/` | Still the Phase 0 blink and its clock/button/LED constraints. The CPU is not connected to the board yet. |
| `firmware/`, `host/`, `protocol/`, debug/diagnostic folders | Future Tab5 work, with detailed contracts already in `docs/`. |

The review covered the complete first-party inventory, all 21 pre-audit Markdown files,
source, benches, scripts, configuration, history and planning relationships before edits.
Earlier analysis was reused for byte-identical reference documents and images. For the
newly restored vendor submodule, the relevant rv32ui wrappers, shared scalar macros,
corresponding rv64ui implementations, environment conventions, README and license were
reviewed. Unused vendor benchmarks and other ISA suites are outside the supported regression.

Work began on `main` at `c989dbae1efdf28e84a0c9856de3f1a030d4dcc3`, with substantial
uncommitted Phase 2 work already present. That work was saved separately for comparison and
preserved on the **`phase-2`** branch. The CPU and its Phase 2 modules were not newly authored
by this audit. Only the submodule registration necessarily changed the Git index; no commit,
push, pull request, merge or tag was made.

## B. Phase 2 requirement verification

The source of truth is [Phase 2 in the build plan](../BUILD_PLAN.md#phase-2-single-cycle-cpu-in-simulation).

| Requirement | Implementation | Evidence after audit | Remaining issue |
| --- | --- | --- | --- |
| Next PC, reset, branch/JAL/JALR | Complete | `next_pc_tb`: 20,023 checks; directed branches/jumps and official programs | Physical timing belongs to Phase 3 |
| LSU sizes, lanes, extension, alignment | Complete | `lsu_tb`: 20,184 checks; load/store and misalignment programs | No bus or wait-state support claimed |
| 64 KiB synchronous dual-port RAM | Complete | `ram_tb`: 371 checks; Vivado: 16 RAMB36s | Other RAM depths are not verified configurations |
| Connected single-cycle CPU, ECALL/EBREAK | Complete in simulation | All 53 CPU programs; both stop causes and post-halt activity checked | Board integration remains Phase 3 |
| Prove memory edge schedule | Complete functionally | Dependent fetch/load/store ordering, read-first, both B clock modes and disabled ports | Setup/hold of CPU half-cycle paths not measured |
| Retirement, terminal and fault contract | Complete for Phase 2 | Actual memory/register writes checked against records; stop-edge retirement checked; terminal/fault mutations rejected | Ordered trace/debug fields remain later milestones |
| Program runner, results, trace, timeout | Complete | Regression plus adversarial real-bench tests; last-cycle halt boundary checked | GTKWave visual review not performed |
| Directed instruction-group programs | Complete | 13/13 pass; fault guards now initialized explicitly | No C runtime claimed |
| Official rv32ui with custom environment | Complete for the documented subset | 40/40 supported programs, registered pin `3df703cd52d5f0d8224e3c50bf03c6cb70efff98`; full 42-file inventory checked | `fence_i` and `ma_data` intentionally excluded |
| Fibonacci memory results | Complete | `fib.S`: 20 expected words, ending in 6765, checked by `fib.expect` | None for simulation |
| Phase gate confirmation | Passed | WSL and [GitHub Actions run #9](https://github.com/Nishant150876/risc-v-computer/actions/runs/42410438947) both pass | None |

The two official exclusions remain explicit: FENCE.I requires Zifencei; `ma_data` expects
misaligned data accesses to work or trap, while this execution environment stops. The results
do not claim privileged traps, CSRs, interrupts, RV32M or unrestricted compliance.

## C. Problems discovered, by severity

| Severity | Finding | Consequence and resolution |
| --- | --- | --- |
| High | Official submodule was only a `.gitkeep`; no `.gitmodules` or gitlink existed | Baseline was **23/24 passed**, with the official suite missing. Registered the exact documented pin. |
| High | A failure result could be overwritten with pass | A six-instruction probe writing failure then pass exited successfully before the fix. The first failing result now fails immediately. |
| Medium | Post-halt activity and stop-edge retirement were incompletely observed | A decoded store after halt could escape the old tests. The bench now checks actual bus activity, register writes, exact terminal/fault retirement and four quiet cycles. |
| Medium | Expectation parser silently ignored malformed trailing rows | A valid row followed by junk passed before the fix. Parsing is now line based and requires exactly two fields. |
| Medium | Fault/partial-write tests assumed untouched RAM was zero | Hardware does not promise that value. Poisoning RAM exposed the assumption; programs now initialize their guards and partial-write words. |
| Medium | Runner accepted a partial official suite and incompletely checked build tools | Empty/partial suites now fail inventory validation; GCC/objcopy/objdump and disassembly failures are checked. Timeout output and quoted rerun arguments are preserved. |
| Medium | Synthesis script printed zero BRAM despite a 16-tile report | The primitive-group filter was wrong. It now counts `RAMB*` cells and fails if default RAM does not infer 16 RAMB36s. |
| Low | `next_pc` checked only target bit 1 and the oracle copied that condition | Full-width odd target inputs violated the module's stated alignment contract. Both low bits are checked; the oracle uses modulo four. Decoded legal CPU B/J targets already had bit 0 clear. |
| Low | Converter accepted non-word RAM limits and could overwrite its input | Size must be positive and word aligned; aliasing is rejected; output is bounded, ASCII and LF. |
| Low | Current status and historical claims were mixed | Updated run counts, WSL/tool status, current retirement/reset fields, Phase 1 historical context and the incorrect “unobservable store gate” explanation. |

An investigated linker concern was **not a bug**: a BSS-only input linked into the existing
`.data` output as PROGBITS, and objcopy produced 20 bytes including the zero word at address
`0x10`. The working linker script was retained. No speculative datapath optimization or
architectural rewrite was made.

## D. Improvements implemented

| Files | Change and reason | Verification |
| --- | --- | --- |
| `.gitmodules`, `sw/riscv-tests` | Restore a reproducible, pinned official dependency | Gitlink/submodule status, 42-file inventory and 40 passing programs |
| `tb/system/cpu_tb.sv` | Fail immediately on bad results; strict expectations; poison uninitialized RAM; compare accepted bus/register effects and executing PC/instruction with retirement; verify stop edge and quiet state; accept a halt on the final permitted cycle | 53 programs, 27 utility/harness tests and targeted mutations |
| `sw/tests/fault_*.S`, `system.S`, `system.expect` | Initialize guard/partial-write words; place a store immediately after EBREAK and verify the guard survives | Directed programs pass with poisoned RAM; removed halt gate fails |
| `rtl/core/next_pc.sv`, `tb/core/next_pc_tb.sv` | Enforce the full four-byte target contract with an independent alignment oracle | 20,023 checks; old-condition mutation rejected; standalone lint and Vivado synthesis |
| `tb/core/lsu_tb.sv`, `tb/mem/ram_tb.sv` | Reserved-size and simultaneous-enable cases; avoid out-of-range reference slicing; check disabled ports and byte writes in both clock modes | 20,184 LSU checks and 371 RAM checks |
| `scripts/run_tests.py`, `bin2mem.py` | Close silent omission/build/result paths and protect image bounds/input files | 16 utility test methods, plus complete software builds and regression |
| `scripts/tests/`, `.github/workflows/tests.yml` | Standard-library tests of real harness failures and utility errors, run in CI | 27 methods total, including 11 real CPU-harness test methods and their subcases |
| `scripts/vivado/synth_blocks.tcl` | Correct BRAM reporting/guard; read sources once instead of repeatedly adding them | Before/after nine-block synthesis; 16 RAMB36s required |
| Markdown and `docs/reports/phase2/` | Preserve technical depth while correcting claims and saving reviewed RAM/register/CPU utilization reports | Local links/anchors, configuration and whitespace checks; reports compared with generated originals |
| Obsolete `.gitkeep` files | Remove placeholders replaced by actual implementation in `rtl/mem`, `rtl/top`, `fpga`, `scripts`, `sw/tests` and the submodule | Inventory review; empty implementation placeholders elsewhere retained |

The owner's reset-free register-file decision is now measured in Vivado: **0 flip-flops,
65 logic LUTs and 48 memory LUTs**, compared with the historical reset-enabled block's
992 flip-flops. This verifies the existing decision; it is not a new optimization made here.
Detailed current counts and the three saved reports are in
[the Phase 2 synthesis record](PHASE2_SINGLE_CYCLE.md#synthesis-evidence).

## E. Verification results

Tools actually used: WSL Ubuntu, Verilator **5.020**, RISC-V GCC **13.2.0**, Python 3 and
Windows Vivado **2025.2**, targeting `xc7a35tcpg236-1` for synthesis/build.

| Check actually run | Outcome |
| --- | --- |
| Initial existing runner, before audit edits | **23/24 passed**; official-suite dependency absent. The earlier 63/63 claim could not be reproduced from that checkout. |
| `python3 scripts/run_tests.py --build-dir /home/nishant/.cache/risc-v-computer/phase2-audit-final/tests --jobs 2` | **63/63 passed**, `--binary --timing --assert -Wall`, no Verilator warnings. Repeated after the final stop-edge checks. |
| `python3 -m unittest discover -s scripts/tests -v` | **27/27 passed**. Expected bad CPU images must fail; positive ECALL/EBREAK tails and exact timeout boundary pass. |
| Standalone Verilator `--lint-only --timing --assert -Wall --top-module <module>` for all 11 RTL modules | **11/11 passed**, no warnings |
| Seven temporary RTL mutation builds and simulations | **7/7 rejected by simulation assertions**, not compiler warnings; table below |
| `vivado -mode batch -nojournal -nolog -source scripts/vivado/synth_blocks.tcl` | Before and after runs passed. Final: **9/9 blocks**, zero latches, **16 RAMB36s** in RAM. Reports are out of context, not timing closure. |
| `vivado -mode batch -nojournal -nolog -notrace -source scripts/vivado/build.tcl` | Blink bitstream rebuilt, **WNS +7.066 ns**, **WHS +0.268 ns**, `== TIMING MET`. CPU is not in that top. No board programming. |
| Python AST parsing, shared task JSON and CI YAML checks | Passed; runner and Python test commands are present in CI |
| First-party Markdown links/anchors and code fences; reviewed report copies | **22 Markdown files, 736 local references, 41 Mermaid fences**, no missing local links/anchors or unclosed fences. All three report copies match generated originals. This is structural checking, not a Mermaid parser result. |
| `git diff --check` and `git diff --cached --check`, plus new-file whitespace review | Passed |
| Hosted GitHub Actions for this audit snapshot | **Not run.** Latest observed green [run #8](https://github.com/Nishant150876/risc-v-computer/actions/runs/42398617111) covers `c989dba`, which contains Phase 0/1. |
| Mermaid parser/rendering | No Mermaid parser was installed. Fences and diagram text were structurally reviewed; rendered syntax is **not claimed verified**. |
| CPU board execution, integrated 25 MHz timing, GTKWave visual inspection, Tab5 hardware | **Not run**; outside this simulation audit or unavailable as verified hardware evidence |

| Mutation, built from an isolated copy | Observed failure |
| --- | --- |
| Remove store commit gate, halt followed by SW | Halted CPU attempted a data access |
| Remove load commit gate, halt followed by LW | Halted CPU attempted a data access |
| Remove register write commit gate, halt followed by ADDI | Halted CPU is not quiescent |
| Corrupt retired store data while the actual store stays correct | Accepted store data disagrees with retirement |
| Restore target-bit-1-only alignment | Independent odd-target test mismatch |
| Omit ECALL/EBREAK retirement | Stop-edge retirement disagrees with terminal/fault contract |
| Falsely retire an illegal instruction | Stop-edge retirement disagrees with terminal/fault contract |

Raw regression/Python/lint/mutation output is retained locally under
`/home/nishant/.cache/risc-v-computer/phase2-audit-final/`. These machine-local logs are not
substitutes for CI or the tracked reviewed utilization reports.

## F. Remaining recommendations

1. Obtain CI for the exact reviewed snapshot after separately authorized Git delivery. Include
   the new submodule metadata, Phase 2 sources and tests; pushing only the old tracked files
   would omit much of the owner's implementation.
2. Follow Phase 3 for the MMCM, complete XDC, bus/I/O, C startup/linker bounds and integrated
   CPU timing. Constrain and measure both half-cycle paths; a 40 ns simulator clock is not a
   timing result. Define safe reset behavior around already accepted stores during integration.
3. Keep the single-cycle CPU as the later pipeline reference. Add wait-state/reset/integration
   cases when those interfaces exist; forwarding, hazards and lockstep remain Phase 5 work.
4. If generalized RAM depths or nonzero reset vectors become required, add explicit parameter
   constraints and tests. The default depth/vector are the configurations verified here.
5. Consider four-state simulation if unknown propagation becomes a concern. Do not add a
   hardware register reset merely to make two-state simulation look deterministic.
6. Keep Tab5 wiring/SDK approval behind T0: SKU, display/touch revision and power remain
   unknown. This audit does not change the debug/diagnostics milestones or approve wiring.

## G. Phase 2 readiness

**Phase 2 implementation: complete and locally verified.** All ten build-plan tasks have
evidence. **Phase 2 gate: passed** after this audit, when [GitHub Actions run #9](https://github.com/Nishant150876/risc-v-computer/actions/runs/42410438947) succeeded on `main`.
**Ready to advance to Phase 3.**

The audit brief's earlier “READY FOR PHASE 2” wording is superseded by its opening request to
review completed Phase 2 work. There is no remaining local implementation blocker found by
this audit.

---

**Related:** [Phase 2 design/evidence](PHASE2_SINGLE_CYCLE.md) · [Build plan](../BUILD_PLAN.md) ·
[Phase 1 history](PHASE1_CORE_BLOCKS.md) · [Scripts](../../scripts/README.md) · [Tests](../../tb/README.md)
