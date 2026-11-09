[Project README](../../README.md) › [Docs index](../README.md) › **Phase 0 smoke test**

# Phase 0 counter smoke test

This page records the project's first working simulation check: a four-bit counter and its
self-checking testbench, run through a shared VS Code task. Use it to run the smoke test
yourself, and as the evidence record for that Phase 0 task.

> [!NOTE]
> **Verified November 7, 2026 in Ubuntu under WSL 2.** This record was written when the smoke test
> was the only working check. The rest of Phase 0 (the general test runner, Vivado build, board
> programming and CI) has since passed the same day; see
> [Phase 0 in the build plan](../BUILD_PLAN.md#phase-0-fresh-start). Phase 1 blocks now have
> [their own record](PHASE1_CORE_BLOCKS.md); the simulated single-cycle CPU is now recorded in
> [Phase 2](PHASE2_SINGLE_CYCLE.md). This page preserves the original smoke-test evidence.

<details open>
<summary><b>On this page</b></summary>

1. [Run it from VS Code](#1-run-it-from-vs-code)
2. [What the two files do](#2-what-the-two-files-do)
3. [Build location](#3-build-location)
4. [Run it from a terminal](#4-run-it-from-a-terminal)
5. [Recorded verification](#5-recorded-verification)
6. [Check the intentional failure](#6-check-the-intentional-failure)
7. [Next task](#7-next-task)

</details>

---

## 1. Run it from VS Code

1. Open this project in VS Code connected to **WSL: Ubuntu**.
2. Save any source edits, then choose **Terminal > Run Task > Smoke: build and run counter**.
3. This runs only the original counter. Since Phase 1, **Ctrl+Shift+B** defaults to
   **Tests: run all testbenches**, which includes this counter and all other benches.

Expected result:

```text
PASS: counter reset, counting, wraparound and restart (25 checks)
```

What the task does:

- The shared [.vscode/tasks.json](../../.vscode/tasks.json) prepares output, compiles with
  Verilator, then runs the executable.
- A failed compile prevents the run; a failed assertion gives a nonzero process exit status.
- Verilator compile diagnostics are linked to source locations in the editor where available.

> [!WARNING]
> Use this task in a WSL window: its tools and generated executable are Linux programs, not
> Windows executables.

---

## 2. What the two files do

| File | What it is |
| --- | --- |
| [rtl/core/counter.sv](../../rtl/core/counter.sv) | A four-bit counter. At each rising clock edge, active-high `rst` clears it; otherwise it increments. Four-bit arithmetic wraps from 15 to 0. It is a simulation smoke module, not a completed CPU block or an FPGA blink design. |
| [tb/core/counter_tb.sv](../../tb/core/counter_tb.sv) | Generates the clock and checks the counter's behavior, listed below. A separate timeout fails the test if it stops making progress. |

The testbench checks, in order:

1. initial reset;
2. held reset;
3. twenty increments including wraparound;
4. reset asserted between clock edges;
5. reset at the next rising edge;
6. counting afterward.

How the bench is built:

| Detail | Why |
| --- | --- |
| Samples at falling edges | Rising-edge state changes have settled by then. |
| `--assert` | Assertions require it. |
| `--timing` | Timed clock generation requires it. |
| `-Wall` | Verilator's full warnings, kept clean. |

All three flags are included in the task.

---

## 3. Build location

Generated C++/object files and the executable go in `$HOME/.cache/risc-v-computer/smoke`
**inside Ubuntu**.

- This avoids timestamp skew and object-file churn on the Windows/OneDrive-backed source
  directory.
- No global clock or WSL configuration was changed.
- Other project jobs may still use the ignored repository `build/` directory as documented.

---

## 4. Run it from a terminal

From a WSL terminal at the repository root, the same steps are:

```bash
mkdir -p "$HOME/.cache/risc-v-computer/smoke"
verilator --binary --timing --assert -Wall -j 2 \
    --top-module counter_tb \
    --Mdir "$HOME/.cache/risc-v-computer/smoke" \
    "$PWD/rtl/core/counter.sv" "$PWD/tb/core/counter_tb.sv"
"$HOME/.cache/risc-v-computer/smoke/Vcounter_tb"
```

> [!TIP]
> `python3 scripts/run_tests.py counter` now runs the same bench through the general test runner,
> which writes to `$HOME/.cache/risc-v-computer/tests` instead. See
> [scripts/README.md](../../scripts/README.md).

---

## 5. Recorded verification

**Source snapshot:** local changes on the Phase 0 feature branch, based on
`4c1c07897c320d43c002d2675c1d87c524ae5e14`. No commit, push, or PR was made at the time.

| Check | Observed result |
| --- | --- |
| VS Code task dependencies and commands | Executed from the actual task JSON in Ubuntu; prepare, compile, then run succeeded. |
| Verilator flags | `--binary --timing --assert -Wall -j 2`; no HDL warnings. |
| Normal test | PASS, 25 checks, process exit 0. |
| Intentional failure | `+force_failure` asked the same checker to expect 1 during reset; it detected `expected 1, got 0`, exited nonzero (SIGABRT / -6). |
| Timeout guard | Present in the testbench; the normal run completes before its 1,000 ns limit. |
| Build location | Final native-Ubuntu-cache build completed without the mounted-folder clock-skew warning seen on the initial attempt. |

| Tool | Observed version |
| --- | --- |
| Verilator | 5.020 |
| g++ | 13.3.0 |
| GNU Make | 4.3 |
| Python | 3.12.3 |

What this record does **not** cover:

- The IDE button itself is for the owner to run; its configured commands were verified
  programmatically.
- GTKWave, RISC-V GCC and Vivado were not checked by this smoke test.
- No synthesis, FPGA programming, or hardware timing result is implied by this record. (Those
  were checked separately later in Phase 0.)

---

## 6. Check the intentional failure

To inspect the intentional failure manually in Ubuntu:

```bash
ulimit -c 0
"$HOME/.cache/risc-v-computer/smoke/Vcounter_tb" +force_failure
```

> [!CAUTION]
> That command is **supposed to fail**. `ulimit` disables core-dump files for that shell; no
> normal simulation source is changed to trigger the test.

---

## 7. Next task

When this record was written, Phase 0 was **2/6 tasks complete** (skeleton and smoke test), and
the next task was the general `scripts/run_tests.py` runner.

**Now:** all six Phase 0 tasks and the gate have passed (November 7, 2026). Phase 1 passed
the same day; see [its record](PHASE1_CORE_BLOCKS.md). Phases 2 and 3 also passed that day;
see the [board/C evidence](PHASE3_BOARD_C.md). [Phase 4 UART](PHASE4_UART.md) has also passed;
Phase 5 is planned next.

---

**Related:** [Build plan, Phase 0](../BUILD_PLAN.md#phase-0-fresh-start) · [scripts/README.md](../../scripts/README.md) · [tb/README.md](../../tb/README.md) · [Docs index](../README.md)
