# RISC-V Computer

A computer built from scratch in SystemVerilog: a five-stage pipelined RV32I processor, its
memory and I/O, and a portable touchscreen debugger, running on a Digilent Basys 3 FPGA.

[![tests](https://github.com/Nishant150876/risc-v-computer/actions/workflows/tests.yml/badge.svg)](https://github.com/Nishant150876/risc-v-computer/actions/workflows/tests.yml)

| At a glance | |
| --- | --- |
| **Instruction set** | RV32I, the 32-bit base integer set of the open RISC-V standard |
| **Language** | SystemVerilog for all hardware and testbenches |
| **Board** | Digilent Basys 3 (Xilinx Artix-7 FPGA) |
| **Portable debugger** | M5Stack Tab5 touchscreen (ESP32-P4) |
| **Current stage** | Phase 7 demos plus single-cycle portable-debug simulation; physical gates pending |

> [!IMPORTANT]
> **Phases 0–5 passed their recorded gates.** The physical board prints `hello, world`,
> advances its counter and echoes text plus all 256 binary byte values correctly over USB
> ([Phase 4 evidence](docs/phases/PHASE4_UART.md)). **Phase 5 passed November 8, 2026:** the
> 5-stage pipeline runs C on the board at up to 62.5 MHz with CPI 1.317, 1.90× faster than the
> single-cycle CPU ([evidence](docs/phases/PHASE5_PIPELINE.md)). Hosted CI passed for Phase 4
> ([run #16](https://github.com/Nishant150876/risc-v-computer/actions/runs/42492919381)) and Phase 5 ([run #18](https://github.com/Nishant150876/risc-v-computer/actions/runs/42501805157)).
>
> **Phase 6 VGA is implemented but not passed.** The integrated regression passes
> **277/277** after Phase 7 integration, Python checks **80/80**, and Vivado meets timing for the single-cycle CPU at
> **25 MHz** and the pipeline at **62.5 MHz**, with pixels fixed at **25 MHz** and zero DRC
> violations ([Phase 6 record](docs/phases/PHASE6_VGA.md)). No VGA monitor is available yet,
> so the physical display gate is unrun. Tab5 firmware/debug integration is a separate
> track in progress; the optional ROM bootloader is deferred.
>
> **Phase 7 is implemented locally:** primes, Life and Snake pass full-board simulations
> on both CPUs; all **48/48** benches are lint-clean and six fresh FPGA builds meet
> timing/DRC. The [Phase 7 record](docs/phases/PHASE7_DEMOS.md) separates that evidence from physical
> cold-power demos, photos/video and the independent rebuild, which remain unrun.

> **Portable debugging now has a local single-cycle implementation:** packet/session RTL,
> safe RAM ownership, halt/step/breakpoints, GPR/memory access, verified loading, trace/counters,
> actual RAM/ALU BIST, bounded fault injection, the laptop CLI and a selectable Tab5 packet
> client. See the [implementation and verification record](docs/tab5/TAB5_SIMULATION_DEBUG.md).
> Pipeline debug, SD launching, packet console and physical link/portable gates remain pending.


<details open>
<summary><b>On this page</b></summary>

1. [What this project is](#1-what-this-project-is)
2. [Project status](#2-project-status)
3. [Quick start](#3-quick-start)
4. [Architecture at a glance](#4-architecture-at-a-glance)
5. [How the CPU will run a program](#5-how-the-cpu-will-run-a-program)
6. [The portable debugging system](#6-the-portable-debugging-system)
7. [How the project is tested](#7-how-the-project-is-tested)
8. [Roadmap](#8-roadmap)
9. [Technology stack](#9-technology-stack)
10. [Repository structure](#10-repository-structure)
11. [Documentation map](#11-documentation-map)
12. [Troubleshooting](#12-troubleshooting)
13. [Contributing](#13-contributing)
14. [License, acknowledgments and glossary](#14-license-acknowledgments-and-glossary)

</details>

---

## 1. What this project is

A computer, at its heart, is a machine that reads a list of very simple instructions from
memory ("add these two numbers", "store this value there", "if this is zero, jump over
there") and carries them out one after another, millions of times a second.

This project builds that machine **from the logic up**, rather than buying one:

| Part | What it is |
| --- | --- |
| **The processor (CPU)** | Written in **SystemVerilog**, a hardware description language. Instead of listing steps for a computer to follow, it describes circuits: wires, registers and logic. |
| **The hardware** | A Digilent **Basys 3** board. Its **FPGA** (field-programmable gate array, a Xilinx Artix-7) is a chip whose internal wiring can be reconfigured, so the SystemVerilog becomes a real working circuit when it is loaded. |
| **The instruction set** | **RV32I**, the 32-bit base integer instruction set of the open RISC-V standard. Because it is a standard, ordinary C compiled with the RISC-V GCC toolchain now runs on the single-cycle CPU. |
| **The portable debugger** | An **M5Stack Tab5** touchscreen (ESP32-P4). It is planned to load programs from its microSD card, show their output, and halt, step, inspect and self-test the CPU, all without a laptop. |

### Why it matters

Building a processor exercises nearly every layer of computer engineering at once:

- digital logic and computer architecture;
- verification and FPGA timing;
- embedded C and bus protocols;
- hardware/software co-design.

The project is planned as a demonstration of **processor bring-up and post-silicon-style
diagnostics**: not only "it runs programs", but "here is the hardware that lets me prove *how*
it runs them, and find out when it doesn't."

> [!IMPORTANT]
> **One rule runs through the whole design: every program shown running on "our CPU"
> genuinely executes on the FPGA.** The Tab5 controls and observes; it never quietly does the
> CPU's work, and simulated or recorded data is always labelled as such.

---

## 2. Project status

<a id="status"></a>

Every README in this repository uses the same four labels:

| Label | Meaning |
| --- | --- |
| ✅ **IMPLEMENTED** | Present in the repository now. |
| 🚧 **IN PROGRESS** | Partly implemented, with evidence in the repository. |
| 📋 **PLANNED** | Specified in a design document, not implemented. |
| ❔ **NOT VERIFIED** | Stated somewhere, but not confirmed by anything in the repository. |

### What exists today

| Area | Status | Evidence |
| --- | --- | --- |
| Folder skeleton (`rtl/`, `tb/`, `sw/`, …) | ✅ IMPLEMENTED | Directories with READMEs; empty ones keep `.gitkeep` placeholders |
| Repository rules ([AGENTS.md](AGENTS.md), `.gitignore`, `.gitattributes`) | ✅ IMPLEMENTED | Files at the repository root |
| Build plan, architecture and protocol documents | ✅ IMPLEMENTED (documents only) | [docs/](docs/README.md) |
| Phase 0 counter smoke test | ✅ IMPLEMENTED | `rtl/core/counter.sv` and `tb/core/counter_tb.sv` pass 25 checks; [smoke evidence](docs/phases/PHASE0_SMOKE_TEST.md) |
| Test runner `scripts/run_tests.py` | ✅ IMPLEMENTED | 291 rows include 46 unit benches and 245 program runs: both CPUs, lockstep, UART, VGA, demos and the single-cycle debug profile; see [current evidence](docs/tab5/TAB5_SIMULATION_DEBUG.md) |
| Vivado build and program scripts | ✅ IMPLEMENTED | `scripts/vivado/build.tcl` and `scripts/vivado/program.tcl` ran in Vivado 2025.2 |
| Phase 0 blink top level and pins | ✅ IMPLEMENTED | `rtl/top/basys3_top.sv`, `fpga/basys3_blink.xdc`; original target preserved |
| Continuous integration | ✅ IMPLEMENTED | Phases 0–3 passed on `main` (Phase 3: run #11, commit `ba05705`) |
| **Phase 0 gate** | ✅ PASSED November 7, 2026 | [Phase 0](docs/BUILD_PLAN.md#phase-0-fresh-start) checkboxes |
| Shared package, ALU, register file, immediate generator, decoder, branch unit | ✅ IMPLEMENTED | [Phase 1 interfaces and tests](docs/phases/PHASE1_CORE_BLOCKS.md) |
| **Phase 1 gate** | ✅ PASSED November 7, 2026 | [Phase 1](docs/BUILD_PLAN.md#phase-1-building-blocks) checkboxes; GitHub Actions green on `main` |
| Single-cycle CPU, 64 KB RAM, test programs | ✅ IMPLEMENTED (simulation) | [Phase 2 design and evidence](docs/phases/PHASE2_SINGLE_CYCLE.md); 63/63 locally |
| **Phase 2 gate** | ✅ PASSED November 7, 2026 | [Phase 2](docs/BUILD_PLAN.md#phase-2-single-cycle-cpu-in-simulation) checkboxes; [audit](docs/phases/PHASE2_AUDIT.md) |
| **Phase 3 gate** | ✅ PASSED November 7, 2026 | Owner confirmed C Fibonacci on the Basys 3; [audit](docs/phases/PHASE3_AUDIT.md) |
| **Phase 4 gate** | ✅ PASSED November 7, 2026 | [USB UART greeting/counter/echo](docs/phases/PHASE4_UART.md); optional ROM deferred |
| UART and C console/printf | ✅ IMPLEMENTED | TX/RX, 16-byte receive FIFO, sticky errors, real hello program and Windows checker |
| VGA | 🚧 IN PROGRESS: text, pixels, color bars and C demo verified in simulation on both CPUs | [Phase 6](docs/phases/PHASE6_VGA.md); timing met at single 25 MHz and pipeline 62.5 MHz; monitor gate unrun |
| Phase 7 demos | ✅ IMPLEMENTED locally; physical acceptance pending | [Primes, Life and Snake](docs/phases/PHASE7_DEMOS.md), shared helpers, full-board tests, previews and [architecture sheet](docs/ARCHITECTURE.md) |
| Pipeline (`cpu_pipe.sv`, forwarding, hazards) | ✅ IMPLEMENTED | [Phase 5](docs/phases/PHASE5_PIPELINE.md): lockstep, hazard zoo, rv32ui and all C programs pass; hello, Fibonacci and `cpi_report` run on the board; Fmax 62.5 MHz |
| **Phase 5 gate** | ✅ PASSED November 8, 2026 | Board CPI 1.317 (single-cycle 1.000); 1.90× faster at 62.5 MHz; 1346 LUT, 772 FF, 16 BRAM |
| Bus, board I/O, MMCM and counters | ✅ IMPLEMENTED | [Phase 3](docs/phases/PHASE3_BOARD_C.md): simulated, timing met, programmed and observed on the board |
| C startup, linker and MMIO header | ✅ IMPLEMENTED | Fibonacci, runtime, hello and printf smoke programs pass; UART/printf now implemented |
| Tab5 firmware, debug protocol, debug and diagnostic hardware | 🚧 IN PROGRESS | [Single-cycle simulation profile](docs/tab5/TAB5_SIMULATION_DEBUG.md), real Python-to-RTL workflow and selectable C packet client; physical gates and pipeline debug pending |

### What has been checked, and what has not

| Item | Status | Notes |
| --- | --- | --- |
| Ubuntu simulation tools (Verilator, g++, Make, Python) | ✅ VERIFIED | Verilator 5.020, g++ 13.3.0, Make 4.3, Python 3.12.3; [observed versions](docs/phases/PHASE0_SMOKE_TEST.md#5-recorded-verification) |
| Vivado | ✅ VERIFIED for the VGA system and all three Phase 7 images | Vivado 2025.2: six routed builds at single 25 MHz / pipe 62.5 MHz; zero DRC violations; [reports](docs/reports/phase7/README.md) |
| RISC-V GCC | ✅ VERIFIED in WSL: Ubuntu | GCC 13.2.0, compatible RV32I libgcc, freestanding assembly and C builds |
| GTKWave | ❔ NOT VERIFIED | Not checked yet |
| Tab5 model/display, Basys 3 revision and flash part | ✅ IDENTIFIED; electrical/power checks pending | Tab5 V1.0/ST7123, Basys 3 Rev D and MX25L3273F; [hardware record](docs/tab5/HARDWARE_CHECKLIST.md). T0 UART and approved wiring remain open |
| CPU timing | ✅ VERIFIED after routing | With VGA: single 25 MHz WNS/WHS +0.396/+0.074 ns; pipe 62.5 MHz +0.313/+0.024 ns. Phase 5's earlier sweep passed 62.5 MHz and failed 80 MHz. Phase 7 has no new Fmax sweep or board run. Power is unmeasured. |
| Full system resources with VGA | ✅ VERIFIED after routing | Single: 1,682 LUTs, 570 FF; pipe: 1,585 LUTs, 940 FF. Both use 22 RAMB36 and zero DSPs; [Phase 7 reports](docs/reports/phase7/README.md) |

Phase-by-phase task counts are kept in the [progress dashboard](docs/BUILD_PLAN.md#2-progress-dashboard).

> [!NOTE]
> Earlier work (a Week 1 LED blink demo and the original week-by-week roadmap) is preserved in
> the Git history at commit `9341a22` and earlier. It is reference material, not current
> validated RTL.

---

## 3. Quick start

<a id="getting-started"></a>

These steps run the tests and the Phase 4 hello/echo design. Build Fibonacci with
`-tclargs basys3_soc fib`; select the original blink with `-tclargs basys3_top` on both commands.

### Before you begin

| Environment | Needs |
| --- | --- |
| **WSL** (Linux on Windows) | Verilator 5, g++, Make, Python 3 and RV32-capable RISC-V GCC for simulation. GTKWave is optional for waveform review. |
| **Windows** | Vivado, on `PATH` for batch builds; a serial terminal such as PuTTY or Tera Term (from Phase 4). |
| **Hardware** | Basys 3 and its USB cable. Later: the Tab5, a microSD card and a signal-only UART cable approved at milestone T0. |

> [!NOTE]
> Verilator 5.020, g++ 13.3.0, Make 4.3 and Python 3.12.3 were checked in the owner's
> **Ubuntu** distribution, RISC-V GCC 13.2.0 in WSL, and Vivado 2025.2 on Windows. GTKWave
> remains **NOT VERIFIED**. Check the installation in the environment you are using before relying on it.

### Step 1: Get the code

```bash
git clone https://github.com/Nishant150876/risc-v-computer.git
cd risc-v-computer
git submodule update --init sw/riscv-tests
```

### Step 2: Run every simulation test (WSL)

From WSL, in the repository root:

```bash
sudo apt install gcc-riscv64-unknown-elf    # one-time setup, if missing
python3 scripts/run_tests.py
python3 -m unittest discover -s scripts/tests -v
```

The runner finds every `tb/**/*_tb.sv`, builds each with Verilator, runs it, and prints a
pass/fail table. Today it ends with `277/277 passed` (32 unit benches and 245 program runs,
covering both CPUs, lockstep, UART, VGA and the Phase 7 demos). The separate Python command runs 80 utility, software and
CPU harness tests. Each command exits 0 only when all its checks pass.

<details>
<summary><b>Other ways to run the tests</b></summary>

| Option | What it does |
| --- | --- |
| `python3 scripts/run_tests.py counter` | Run only tests whose name contains `counter` |
| `python3 scripts/run_tests.py -v` | Show each test's output |
| `python3 scripts/run_tests.py --list` | List tests without running them |

In **VS Code connected to WSL: Ubuntu**, save your edits, then press **Ctrl+Shift+B**. The default
task, **Tests: run all testbenches**, compiles and runs the complete local regression.
Expected output:

```text
277/277 passed
```

**Terminal > Run Task > Smoke: build and run counter** runs just the original counter.
See [PHASE0_SMOKE_TEST.md](docs/phases/PHASE0_SMOKE_TEST.md) for the smoke test's source files, terminal
commands, tool versions and recorded checks.

</details>

### Step 3: Build the bitstream (Windows, Vivado on `PATH`)

From the repository root:

```bash
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl
```

The script builds the hello C image in WSL, then writes `build/vivado/basys3_soc.bit`
after its 40 ns CPU clock, RAM and setup/hold timing checks pass. It prints `== TIMING MET`.

### Step 4: Program the board (Windows)

Plug in the Basys 3 and switch it on, then run:

```bash
vivado -mode batch -nojournal -nolog -source scripts/vivado/program.tcl
```

Open the board's COM port at **115200 8N1, flow control None**, then press the centre button:
the CPU prints `hello, world`, a live counter and echoes your typing. The counter also appears
on LEDs/hex. Use [uart_check.py](scripts/uart_check.py) for automated greeting/counter/echo
checks; close PuTTY first because only one application can own the port. Setup and the
verified COM8 example are in [Phase 4](docs/phases/PHASE4_UART.md#4-build-and-run).
Configuration is volatile and is lost at power-off. To run the earlier switch/Fibonacci demo,
build with `-tclargs basys3_soc fib`, then program normally. The original blink remains
`-tclargs basys3_top` on build/program.

> [!TIP]
> Building a bitstream and programming the board are separate steps on purpose. You can build and
> read the timing report without touching the hardware.

For the implemented route from C to the board, see [Phase 4](docs/phases/PHASE4_UART.md) and
[sw/README.md](sw/README.md#4-from-c-to-the-board). For the scripts' options, see
[scripts/README.md](scripts/README.md).

---

### Phase 7 demos

The FPGA CPU now runs three more freestanding C programs:

| Program | Output and controls | Details |
| --- | --- | --- |
| Prime sieve | All 1,229 primes through 10,000, count, cycles, instructions and CPI over 115200 8N1 UART | [primes](sw/programs/primes/README.md) |
| Game of Life | 160 x 120 cells; SW0-3 select glider/gun/R-pentomino/random, BTNU restarts; SW15 manual, BTNR step | [life](sw/programs/life/README.md) |
| Snake | U/L/R/D turn; SW0 pause, SW1 slow; score on pixels/hex, BTNU restarts after game over | [snake](sw/programs/snake/README.md) |

BTNC stays CPU reset. Snake uses a 40 x 26 playfield below a two-row pixel HUD.
Both games wait for vertical blank for ordinary drawing and initialize while hidden.
The code and simulations can be used without a monitor; physical play/display acceptance
still needs a VGA display path. Tab5 does not yet mirror VGA or run these game controls.

Run from the repo root in WSL:

```bash
python3 scripts/run_tests.py primes
python3 scripts/run_tests.py life
python3 scripts/run_tests.py snake
python3 scripts/run_tests.py --evidence-dir build/phase7/simulation
```

Build a selected demo in Windows, with optional pipeline clock:

```powershell
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc snake pipe 62.5
```

The default remains the single-cycle hello image. Reviewed Phase 7 bitstreams are kept
separately under ignored `build/phase7/`; the existing programmer selects `build/vivado/`.
See the [Phase 7 build/run guide](docs/phases/PHASE7_DEMOS.md#4-fpga-builds-and-later-board-execution)
before selecting an isolated bitstream for a later hardware test.

These previews are **simulated FPGA RGB output**, checked pixel by pixel against
independent models. They are not monitor photographs:

| Life: Gosper glider gun | Snake: score and game over |
| --- | --- |
| ![Simulated Life gun output](docs/images/phase7/life-gun.png) | ![Simulated Snake game-over output](docs/images/phase7/snake-game-over.png) |

The [one-page architecture sheet](docs/images/phase7/architecture-sheet.pdf) is ready.
Physical cold-power demonstrations, board/screen photos, the real 60-second video,
the owner's bug story and an independent rebuild remain pending.

## 4. Architecture at a glance

<a id="architecture"></a>

> [!NOTE]
> System integration in this section is the **planned** design from the
> [build plan](docs/BUILD_PLAN.md) and the [integration architecture](docs/tab5/TAB5_INTEGRATION.md).
> The individual Phase 1 CPU blocks are already implemented and unit-tested.

The CPU only ever does three things with the outside world: **fetch** instructions, **load**
data and **store** data. The address alone decides where a load or store goes. That idea,
**memory-mapped I/O**, means LEDs, switches, the UART and the screen are all controlled with
ordinary load and store instructions; no special I/O instructions are needed.

The diagram shows every planned block inside the FPGA, and the two outside devices that talk to it.

```mermaid
flowchart LR
    subgraph FPGA["Basys 3 FPGA (Artix-7)"]
        CPU["RV32I CPU<br/>single-cycle, then 5-stage pipeline"]
        RAM["64 KiB dual-port RAM<br/>code, data and stack"]
        BUS["Bus decoder<br/>RAM or device?"]
        IO["Board I/O<br/>LEDs, switches, buttons, 7-segment"]
        UART["USB UART<br/>115200 baud console"]
        VGA["VGA<br/>optional display"]
        DBG["Debug and diagnostics<br/>packets, Wishbone, BIST"]
        CPU -- "port A: fetch" --> RAM
        CPU -- "port B: load/store" --> BUS
        BUS --> RAM
        BUS --> IO
        BUS --> UART
        BUS --> VGA
        DBG -. "halt, step, inspect" .-> CPU
        DBG -. "owned access while stopped" .-> RAM
    end
    LAPTOP["Laptop serial terminal<br/>development"] <--> UART
    TAB5["M5Stack Tab5<br/>touchscreen and microSD"] <-- "dedicated debug UART" --> DBG
```

| Block | Job | Planned in |
| --- | --- | --- |
| **CPU** | Fetches, decodes and executes RV32I instructions. Built single-cycle first, then as a 5-stage pipeline checked against it. | Phases 1, 2, 5 |
| **RAM** | One 64 KiB block RAM with two ports: port A fetches instructions while port B serves loads and stores. | Phase 2 |
| **Bus decoder** | Sends addresses at `0x8000_0000` and above to devices instead of RAM. | Phase 3 |
| **Board I/O** | 16 LEDs, 16 switches, 5 buttons and the 4-digit 7-segment display. | Phase 3 |
| **UART** | 115200 baud, 8 data bits, no parity, 1 stop bit, over the board's existing USB cable. | Phase 4 |
| **VGA** | 640 × 480 at 60 Hz; 80 × 30 text and a 160 × 120 pixel mode. Optional track. | Phase 6 |
| **Debug hardware** | Packet engine, debug-only Wishbone bus, halt/step/breakpoints, trace, counters, self-test, fault hooks. | T2–T12 |
| **Tab5** | Portable launcher, console, debugger and diagnostics screen. | T0–T13 |

### Memory map

RAM starts at address 0, where the CPU begins after reset. Every device lives at `0x8000_0000`
or above.

| Region | Addresses | Contents |
| --- | --- | --- |
| Main RAM | `0x0000_0000 – 0x0000_FFFF` | 64 KB of code, data and stack. Reset starts here. |
| Boot ROM (optional) | `0x0001_0000 – 0x0001_07FF` | 2 KB UART bootloader (Phase 4) |
| Devices | `0x8000_0000 – 0x8002_3FFF` | LEDs, switches, UART, counters, VGA |
| Simulation only | `0xF000_0000` | Tests write pass/fail here to end the run |

<details>
<summary><b>Full memory map, register by register</b></summary>

| Address | Size | Contents | Access |
| --- | --- | --- | --- |
| `0x0000_0000 – 0x0000_FFFF` | 64 KB | Main RAM: code, data, stack. Reset starts here. | read, write, execute |
| `0x0001_0000 – 0x0001_07FF` | 2 KB | Boot ROM for the optional UART bootloader (Phase 4) | read, execute |
| `0x8000_0000` | 4 B | LEDs (16 bits) | write |
| `0x8000_0004` | 4 B | 7-segment display: 16-bit value shown in hex | write |
| `0x8000_0008` | 4 B | Switches (16 bits) | read |
| `0x8000_000C` | 4 B | Buttons (5 bits) | read |
| `0x8000_0010` | 4 B | UART transmit byte | write |
| `0x8000_0014` | 4 B | UART status: bit 0 TX busy, bit 1 RX waiting, bit 2 sticky overrun, bit 3 sticky framing error | read |
| `0x8000_0018` | 4 B | UART received byte | read |
| `0x8000_0020` | 4 B | Cycle counter | read |
| `0x8000_0024` | 4 B | Instructions-retired counter | read |
| `0x8000_0028` | 4 B | VGA status: bit 0 displayed vblank, bit 1 mode pending, bits 3:2 applied mode | read |
| `0x8000_002C` | 4 B | VGA control: bits 1:0 requested mode (text/pixels/bars/black); lane 0, ignored while pending | read/write |
| `0x8001_0000 – 0x8001_0FFF` | 4 KB | VGA text buffer, 2400 bytes used; reserved tail reads zero | read/write |
| `0x8002_0000 – 0x8002_3FFF` | 16 KB | VGA pixel framebuffer, 9600 packed bytes used; reserved tail reads zero | read/write |
| `0xF000_0000` | 4 B | Simulation only: tests write pass/fail here to end the run | write |

The canonical copy of this map, with its open review notes, is in the
[build plan](docs/BUILD_PLAN.md#6-memory-map).

</details>

> [!NOTE]
> The debug hardware has its own separate address space (`0x4000_0000 – 0x4000_07FF`) that the
> CPU cannot reach; see the
> [debug-only allocation](docs/tab5/TAB5_INTEGRATION.md#debug-only-address-allocation). The C header
> [sw/common/mmio.h](sw/common/mmio.h) names the device addresses. Board I/O and counters
> are implemented, including UART. This Phase 6 implementation adds VGA mode control and readable
> display memories; debug entries remain reserved. Display updates are single-buffered and must
> finish inside vblank or use a hidden mode to avoid tearing.

---

## 5. How the CPU will run a program

<a id="walkthrough"></a>

> [!NOTE]
> A walkthrough of the **planned** design, to make the rest of the documentation easy to
> follow. No CPU exists yet to run it.

### The five steps of every instruction

Every RV32I instruction goes through the same five steps. Think of a sandwich counter: take the
order, read it, make it, fetch any extras from the back, hand it over.

```mermaid
flowchart LR
    IF["IF<br/>fetch"] --> ID["ID<br/>decode"] --> EX["EX<br/>execute"] --> MEM["MEM<br/>memory"] --> WB["WB<br/>write back"]
```

| Step | Name | What happens |
| :-: | --- | --- |
| **IF** | Instruction Fetch | Read the 32-bit instruction at the address held in the **program counter (PC)**. |
| **ID** | Instruction Decode | Work out what the instruction means and read its source **registers**: the CPU's 32 small, fast storage slots `x0`–`x31` (`x0` always reads as zero). |
| **EX** | Execute | The **ALU** (arithmetic logic unit) adds, subtracts, compares or shifts. Branches decide whether to jump. |
| **MEM** | Memory | Loads read RAM or a device; stores write it. Other instructions pass straight through. |
| **WB** | Write Back | Write the result into the destination register. |

### A five-instruction example

This tiny program adds two numbers and shows the answer on the board's LEDs:

```asm
addi x1, x0, 5        # x1 = 0 + 5                  encoding 0x00500093
addi x2, x0, 7        # x2 = 0 + 7                  encoding 0x00700113
add  x3, x1, x2       # x3 = 5 + 7 = 12             encoding 0x002081B3
lui  x4, 0x80000      # x4 = 0x8000_0000, the LED register address
sw   x3, 0(x4)        # store 12 there: the LEDs show 0b1100
```

Take `add x3, x1, x2`. Its 32 bits are split into fixed fields that the decoder reads directly,
which is a large part of why RISC-V is pleasant to implement:

```text
 funct7    rs2    rs1   funct3   rd    opcode
0000000   00010  00001   000   00011  0110011      = 0x002081B3
  add      x2     x1     add     x3   register-register ALU operation
```

> [!TIP]
> The last line, `sw x3, 0(x4)`, is where memory-mapped I/O appears. It is an ordinary store,
> but because its address is `0x8000_0000`, the bus decoder sends it to the LED register
> instead of RAM.

### Single-cycle first, then a pipeline

| Version | How it works | Why |
| --- | --- | --- |
| **Single-cycle** (Phases 2–4) | Each instruction does all five steps in one long clock cycle. | Slow but simple, so it is the easiest version to get exactly right. It then becomes the **reference model**: the pipeline is checked against it instruction by instruction. |
| **Pipelined** (Phase 5) | Like an assembly line, each step works on a different instruction at the same time, so up to five instructions are in flight. | Much higher throughput. In the planned design, the example above finishes in 9 cycles with no stalls. |

| Cycle → | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| `addi x1` | IF | ID | EX | MEM | WB | | | | |
| `addi x2` | | IF | ID | EX | MEM | WB | | | |
| `add x3` | | | IF | ID | **EX** | MEM | WB | | |
| `lui x4` | | | | IF | ID | EX | MEM | WB | |
| `sw x3` | | | | | IF | ID | **EX** | MEM | WB |

- **Cycle 5:** `add` needs `x2`, which `addi x2` has computed but not yet written back.
  **Forwarding** hands the value straight from the EX/MEM pipeline register to the ALU, so
  nothing waits.
- **Cycle 7:** `sw` gets its address register `x4` the same way, and its store data `x3` from
  MEM/WB.

The pipeline's three classic situations are handled like this:

```mermaid
flowchart TD
    Q{"Does the instruction in EX need<br/>a value not yet written back?"}
    Q -- "yes, an ALU result" --> F["Forward it from EX/MEM or MEM/WB<br/>no delay"]
    Q -- "yes, from the load just before it" --> S["Load-use hazard<br/>stall 1 cycle, then forward"]
    Q -- "no" --> N["Proceed normally"]
    B{"Taken branch or jump<br/>resolved in EX?"}
    B -- "yes" --> FL["Flush the 2 younger instructions<br/>predict not-taken"]
    B -- "no" --> N
```

![5-stage pipeline: forwarding sends results back to EX, so only load-use pairs stall](docs/images/pipeline.png)

<details>
<summary><b>Instruction-set and timing details for engineers</b></summary>

- All **40 RV32I base instructions** are recognized: 37 ordinary operations plus FENCE, ECALL
  and EBREAK. FENCE runs as a no-op. ECALL and EBREAK each retire once and then halt; this is
  the project's own execution-environment policy, not a privileged trap implementation, and
  tests and reports must label it that way.
- RV32M multiply/divide, CSRs, traps, interrupts and branch prediction are stretch goals. RV32I
  has no multiply or divide instructions, so C code links GCC's software versions with `-lgcc`.
- Misaligned loads and stores stop with a documented error rather than being emulated.
- **Single-cycle memory timing:** falling-edge block RAM reads are the initial candidate, and a
  dedicated memory/fetch/load testbench must prove the full edge schedule at 25 MHz before CPU
  integration. If it fails, the decision is revised explicitly.
- **Pipeline memory timing:** normal synchronous reads. The block RAM's output register doubles
  as the IF/ID register, so a stall must hold the RAM enable low.
- The register file has a `BYPASS` parameter: off for single-cycle (on, it would create a
  combinational loop) and on for the pipeline, covering write-back to decode.
- **Clocks:** an MMCM turns the 100 MHz board clock into 25 MHz for the single-cycle CPU and
  for VGA pixels. The pipeline will run as fast as timing allows, and that limit will be measured.

</details>

---

## 6. The portable debugging system

> [!NOTE]
> 📋 **PLANNED** (milestones T0–T13). Details: [Tab5 integration](docs/tab5/TAB5_INTEGRATION.md).

The finished system is two devices:

- the **Basys 3**, which runs the CPU plus the hardware that controls and observes it;
- the **Tab5**, which is the touchscreen interface to that hardware.

A typical planned interaction, from choosing a program to seeing its output:

```mermaid
sequenceDiagram
    participant U as Person at the Tab5
    participant T as Tab5 app
    participant F as FPGA debug hardware
    participant C as RV32I CPU
    U->>T: Select a program on microSD
    T->>F: LOAD_BEGIN, then LOAD_CHUNK packets
    T->>F: LOAD_COMMIT
    F->>F: Read RAM back and check CRC-32
    F-->>T: Image verified
    U->>T: Press RUN
    T->>F: RUN
    F->>C: Release the CPU at entry 0
    C-->>F: printf output into the console FIFO
    F-->>T: Console packets
    T-->>U: Genuine CPU output on screen
```

### The two portable gates

| Gate | What must work | Status |
| --- | --- | --- |
| **P1** (milestone T5) | Laptop-free cold boot, a program chosen from microSD, verified load into FPGA RAM, genuine CPU output and counters, and running program A then B without rebuilding the bitstream. The single-cycle CPU is enough. | 📋 PLANNED |
| **P2** (milestone T13) | P1 plus the verified pipeline, exact instruction stepping, pre-execution breakpoints, register and memory access, coherent snapshots, retirement trace, performance counters, hardware self-test, controlled fault detection and offline reference comparison. | 📋 PLANNED |

### Key design choices

| Choice | Why |
| --- | --- |
| A **dedicated debug UART**, separate from the CPU's own console | Program text can never become a command. |
| A versioned packet protocol with **COBS framing, CRC-32 and replay-safe request IDs** | A retried command can never run twice. |
| A **debug-only Wishbone B4 Classic** bus with adapters | The CPU keeps its native memory ports. |
| **Exclusive RAM ownership** (CPU, debug or self-test, never two at once) | Both RAM ports already have CPU jobs and there is no third port. |
| HALT **drains** the pipeline instead of gating the clock; STEP means **exactly one retired instruction**, not one clock cycle | Debugging stays architecturally correct on a pipeline. |

---

## 7. How the project is tested

> [!NOTE]
> ✅ **277 regression runs and 80 Python tests pass locally.** This covers 32 unit benches
> and 245 program runs: directed/rv32ui assembly on both CPUs and in lockstep, C runtime,
> formatting and console, and full-board Fibonacci, UART and VGA cases. Phase 4 alone was
> 101 runs and 58 Python checks. [Phase 4 evidence](docs/phases/PHASE4_UART.md) includes routed reports
> and the observed physical serial gate. That snapshot later passed hosted [CI run #16](https://github.com/Nishant150876/risc-v-computer/actions/runs/42492919381);
> Phase 3 passed [CI run #11](https://github.com/Nishant150876/risc-v-computer/actions/runs/42422996823).

The rule is to catch each bug at the cheapest layer that can catch it. Each layer below starts
in the phase shown.

```mermaid
flowchart LR
    U["Unit testbenches<br/>Phase 1"] --> D["Directed assembly tests<br/>Phase 2"]
    D --> R["Official rv32ui suite<br/>Phase 2"]
    R --> L["Single-cycle vs pipeline lockstep<br/>Phase 5"]
    L --> B["On the board<br/>Phase 3 onward"]
    B --> P["Portable qualification<br/>T5 and T13"]
```

- Every RTL module lands together with a **self-checking testbench**: it compares results
  against a reference model and fails by itself, rather than relying on someone reading waveforms.
- One command, `python3 scripts/run_tests.py`, runs every layer that works in simulation.
- GitHub Actions runs it on every push.

Details: [tb/README.md](tb/README.md) and the [verification matrix](docs/tab5/VERIFICATION_MATRIX.md).

---

## 8. Roadmap

<a id="roadmap"></a>

The core CPU follows phases in order, and each ends with a **gate**: a concrete test that must
pass before the next phase starts. The Tab5 milestones (T0–T13) have their own stated
dependencies. VGA (Phases 6–7) is optional and blocks neither portable gate.

The diagram shows both tracks and where they depend on each other.

```mermaid
flowchart LR
    P0["Phase 0<br/>build and test flow"] --> P1["Phase 1<br/>CPU blocks"]
    P1 --> P2["Phase 2<br/>single-cycle in sim"]
    P2 --> P3["Phase 3<br/>board and C"]
    P3 --> P4["Phase 4<br/>UART"]
    P4 --> P5["Phase 5<br/>pipeline"]
    P5 --> P6["Phase 6<br/>VGA, optional"]
    P6 --> P7["Phase 7<br/>demos and polish"]
    P0 --> TA["T0-T1<br/>Tab5 bring-up, mock UI"]
    P4 --> TB["T2-T4<br/>protocol, bus, control"]
    TA --> TB
    P3 --> TB
    TB --> T5["T5 = P1<br/>first portable demo"]
    T5 --> TC["T6-T12<br/>step, trace, BIST, faults"]
    P5 --> TC
    TC --> T13["T13 = P2<br/>full diagnostics"]
```

| Phase | Goal | Gate | Status |
| --- | --- | --- | --- |
| **0** Fresh start | One-command tests and bitstreams | `run_tests.py` passes in WSL and on GitHub Actions; scripted blink runs on the board | ✅ passed November 7, 2026 |
| **1** Building blocks | ALU, register file, immediates, decoder, branch unit | Every Phase 1 testbench passes locally and in CI | ✅ passed |
| **2** Single-cycle CPU | Every instruction in one clock, in simulation | All of rv32ui and every directed test pass | ✅ passed |
| **3** Board and C | Real C on real hardware | A C program shows fib(switches) on the 7-segment; fib(20) = 6765 = `0x1A6D` | ✅ passed |
| **4** UART | Text to a laptop | "hello, world", a live counter, and echo of typed text | ✅ passed; optional ROM deferred |
| **5** Pipeline | Five stages with forwarding and hazards | Lockstep, hazard zoo and rv32ui pass; C runs on the board; performance table filled | ✅ passed |
| **6** VGA | Text and pixels on a monitor | One C program prints text and draws pixels | 🚧 monitor unrun |
| **7** Demos and polish | Game of Life, prime sieve, Snake or Pong | All three run from cold power-on; rebuildable from the README alone | 📋 |

The full task lists, Tab5 milestones, risks, open questions and stretch goals (RV32M, branch
prediction, CSRs and traps, formal verification, CoreMark, Tiny Tapeout) are in the
[build plan](docs/BUILD_PLAN.md).

---

## 9. Technology stack

| Layer | Tool or standard | Used for | Status |
| --- | --- | --- | --- |
| Hardware description | SystemVerilog | All RTL and testbenches | ✅ Single-cycle CPU, RAM and Phase 3 board SoC |
| Simulation | Verilator 5, in WSL | Self-checking tests, `-Wall` clean | ✅ verified with 5.020 |
| Waveforms | GTKWave | Inspecting simulations | ❔ install NOT VERIFIED |
| FPGA build | Xilinx Vivado, non-project Tcl mode, on Windows | Synthesis, place and route, bitstreams | ✅ verified with 2025.2 |
| Software | RISC-V GCC, `-march=rv32i -mabi=ilp32`, no standard library | C and assembly programs | ✅ GCC 13.2.0, `riscv64-unknown-elf-` with compatible RV32I multilib verified |
| Scripts | Python 3 (standard library preferred) and Vivado Tcl | Test runner, builds, image conversion, host client | ✅ Simulation, C/image builder and Vivado flows; host client planned |
| CI | GitHub Actions | Run every test on every push | ✅ Phase 3 passed (run #11) |
| Tab5 firmware | ESP-IDF, FreeRTOS, LVGL | Touchscreen application | 📋 PLANNED; versions pinned after T0 |
| Hardware | Digilent Basys 3 (Artix-7), M5Stack Tab5 (ESP32-P4) | Target boards | Exact revisions ❔ NOT VERIFIED |

---

## 10. Repository structure

Every folder below exists now. Files marked ✅ are implemented; the rest of each folder holds
documentation and `.gitkeep` placeholders for the planned files.

```text
risc-v-computer/
├── .github/workflows/   ✅ tests.yml: run_tests.py on every push and pull request
├── .vscode/tasks.json   ✅ VS Code tasks: counter smoke test, run all tests
├── rtl/                 Hardware (RTL): the circuits             → rtl/README.md
│   ├── core/            ✅ counter, RV32I package/blocks, cpu_single
│   ├── mem/             ✅ 64 KiB dual-port RAM; boot ROM planned
│   ├── io/              ✅ board I/O, debounce, counters, UART/FIFO; VGA implemented
│   ├── soc/             ✅ soc (CPU + RAM + bus + I/O) and the bus decoder
│   ├── top/             ✅ basys3_soc board top, MMCM; original blink preserved
│   ├── debug/           Packet engine, Wishbone bridge, CPU control, trace
│   └── diag/            Memory/ALU self-test and fault hooks
├── tb/                  ✅ Testbenches, same subfolders as rtl/  → tb/README.md
│   ├── core/ mem/ io/ soc/ top/   ✅ 20 unit benches, one per module
│   ├── system/          ✅ cpu_tb program runner, board C and board UART benches
│   ├── data/            ✅ shared .mem fixtures
│   └── debug/ diag/     Planned Tab5 suites
├── sw/                  Software that runs ON the CPU              → sw/README.md
│   ├── common/          ✅ startup, linker, mmio.h, UART and printf
│   ├── tests/           ✅ 13 directed assembly tests: isa/, faults/, env/
│   ├── riscv-tests/     ✅ pinned official suite submodule
│   └── programs/        ✅ Fibonacci, runtime smoke, hello and printf smoke
├── scripts/             ✅ regression, C/image build, UART checker → scripts/README.md
│   ├── vivado/          ✅ build.tcl, program.tcl, synth_blocks.tcl
│   └── tests/           ✅ unit tests for the Python tools
├── fpga/                ✅ SoC 52-pin and legacy blink 18-pin XDC → fpga/README.md
├── firmware/tab5/       Tab5 touchscreen application             → firmware/tab5/README.md
├── host/                Python debug client and prep tools       → host/README.md
├── protocol/            Shared protocol schemas and vectors      → protocol/README.md
├── docs/                Build plan and design record              → docs/README.md
│   ├── phases/          ✅ Phase 0–4 records and audits
│   ├── tab5/            Tab5 architecture, protocol, firmware, hardware, requirements
│   ├── reports/         ✅ reviewed Vivado reports per phase
│   └── images/          Diagrams used by the READMEs
├── AGENTS.md            Working rules for this repository
└── README.md            You are here
```

Where generated files go:

- `run_tests.py` and the VS Code smoke task write to Ubuntu's `$HOME/.cache/risc-v-computer/`
  (`tests/` and `smoke/`), keeping simulation output off the Windows/OneDrive mount.
- Vivado output goes to `build/vivado/`, which Git ignores, along with Vivado projects,
  bitstreams, logs and compiled binaries.
- Source memory images (`.mem`, `.coe`) and reviewed reports in `docs/` stay trackable.

> [!NOTE]
> The official suite is already a pinned submodule. Initialize it after cloning with
> `git submodule update --init sw/riscv-tests`; the runner rejects a missing or partial suite.

---

## 11. Documentation map

<a id="docs-map"></a>

| Document | What it covers |
| --- | --- |
| [docs/README.md](docs/README.md) | Index of every design document and how they relate |
| [docs/BUILD_PLAN.md](docs/BUILD_PLAN.md) | **Source of truth**: phases, gates, design decisions, memory map, risks, progress checkboxes |
| [docs/phases/PHASE0_SMOKE_TEST.md](docs/phases/PHASE0_SMOKE_TEST.md) | The first passing simulation: VS Code task, counter checks, observed tool versions |
| [docs/phases/PHASE1_CORE_BLOCKS.md](docs/phases/PHASE1_CORE_BLOCKS.md) | Implemented CPU-block interfaces, behavior and local verification; CI gate status |
| [docs/phases/PHASE2_SINGLE_CYCLE.md](docs/phases/PHASE2_SINGLE_CYCLE.md) | Single-cycle CPU: edge schedule, retirement/stop contract, test programs, evidence |
| [docs/tab5/TAB5_INTEGRATION.md](docs/tab5/TAB5_INTEGRATION.md) | Debug architecture, RAM ownership, halt/step/breakpoint contracts, loader, trace |
| [docs/tab5/DEBUG_PROTOCOL.md](docs/tab5/DEBUG_PROTOCOL.md) | Packet format, sessions, retries, commands and status codes |
| [docs/tab5/TAB5_FIRMWARE.md](docs/tab5/TAB5_FIRMWARE.md) | Tab5 framework choice, modules, screens, microSD layout |
| [docs/tab5/HARDWARE_CHECKLIST.md](docs/tab5/HARDWARE_CHECKLIST.md) | Board identification, wiring, power and cold-boot gates |
| [docs/tab5/VERIFICATION_MATRIX.md](docs/tab5/VERIFICATION_MATRIX.md) | Every requirement mapped to the test that will prove it |
| [docs/tab5/TAB5_REQUIREMENTS.md](docs/tab5/TAB5_REQUIREMENTS.md) | The original 35-section Tab5 specification, preserved |

### Suggested reading paths

| If you are… | Read in this order |
| --- | --- |
| **New to hardware** | This page → [the walkthrough](#5-how-the-cpu-will-run-a-program) → [rtl/README.md](rtl/README.md) → [tb/README.md](tb/README.md) |
| **Wanting to build and run it** | [Quick start](#3-quick-start) → [scripts/README.md](scripts/README.md) → [sw/README.md](sw/README.md) → [fpga/README.md](fpga/README.md) |
| **An engineer reviewing the architecture** | [BUILD_PLAN.md](docs/BUILD_PLAN.md) → [TAB5_INTEGRATION.md](docs/tab5/TAB5_INTEGRATION.md) → [DEBUG_PROTOCOL.md](docs/tab5/DEBUG_PROTOCOL.md) → [VERIFICATION_MATRIX.md](docs/tab5/VERIFICATION_MATRIX.md) |
| **A recruiter** | [What this project is](#1-what-this-project-is) → [The portable debugging system](#6-the-portable-debugging-system) → [Roadmap](#8-roadmap) |
| **Contributing** | [AGENTS.md](AGENTS.md) → [the current phase](docs/BUILD_PLAN.md#9-build-phases) → the README of the folder you are changing |

---

## 12. Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `verilator not found on PATH (run this from WSL)` | `run_tests.py` was started in a Windows shell | Run it from WSL, where Verilator is installed |
| A test shows `BUILD` in the results table | Verilator could not compile the bench or the RTL | Read the first `%Error` line in the table; run with `-v` for the full log |
| A test shows `FAIL` with `exited 0 but never printed PASS` | The bench finished without its `PASS` line | Every bench must print a line starting with `PASS` when its checks succeed |
| Slow builds or Make clock-skew warnings | Generated files are on a Windows/cloud-synced mount | Keep generated files on the Linux filesystem; the runner and smoke task already use `$HOME/.cache/risc-v-computer/` |
| `== TIMING FAILED: negative slack` | The design does not meet its clock constraint | Open `build/vivado/timing_summary.rpt` and find the failing path |
| `missing …basys3_top.bit: run scripts/vivado/build.tcl first` | `program.tcl` found no bitstream | Run `build.tcl` first |
| `no xc7a35t found: is the Basys 3 connected and on?` | Vivado cannot see the board | Check the USB cable and the power switch |

<details>
<summary><b>Pitfalls the plan already anticipates for later phases</b></summary>

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `riscv32-unknown-elf-gcc: command not found` | The toolchain was installed with a `riscv64-unknown-elf-` prefix | Use that prefix with the same flags, if it was built with 32-bit (multilib) support |
| Simulation tools missing in a Windows shell | Verilator and GCC are planned for WSL; Vivado and the serial port for Windows | Run each step in its intended environment |
| Instructions off by one, or loads return the previous value | Block RAM's one-cycle read delay | Revisit the memory-timing decision; the dedicated memory testbench exists to catch this |
| Passes in simulation, fails on the board | Timing, clock or reset problem | Read the Vivado timing report first; check clock and reset; show internal values on the 7-segment display or use Vivado's ILA |

</details>

---

## 13. Contributing

The working rules are in [AGENTS.md](AGENTS.md) and apply to everyone who changes the repository.
The essentials:

- Follow the phases in order, and never tick a gate whose test has not actually passed.
- One module per file with a matching `snake_case` name; `logic` with `always_ff` and
  `always_comb`; no latches; clock `clk` and active-high synchronous reset `rst`; Verilator
  `-Wall` clean.
- A module and its self-checking testbench land in the same commit, and no commit breaks the
  test run.
- Work on a task branch and open a pull request into `main`. Report exactly which checks ran
  and what they showed.

---

## 14. License, acknowledgments and glossary

No license file has been added yet, so default copyright applies until one is chosen.

The pipeline follows the textbook design in Harris & Harris, *Digital Design and Computer
Architecture*, chapter 7. The instruction set is the
[ratified RISC-V RV32I specification](https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html).
Board facts come from Digilent's Basys 3 reference manual and master XDC, and Tab5 facts from
M5Stack's documentation, all linked in [HARDWARE_CHECKLIST.md](docs/tab5/HARDWARE_CHECKLIST.md).

<details>
<summary><b>Glossary</b></summary>

| Term | Meaning |
| --- | --- |
| **ALU** | Arithmetic logic unit: the circuit that adds, subtracts, compares and shifts. |
| **BIST** | Built-in self-test: hardware that tests other hardware, such as RAM, by itself. |
| **Block RAM (BRAM)** | Dedicated memory blocks inside the FPGA; the Basys 3 manual lists 1,800 Kbits. |
| **COBS** | Consistent Overhead Byte Stuffing: removes zero bytes from a packet so `0x00` can mark its end. |
| **CPI** | Cycles per instruction: clock cycles divided by instructions completed. |
| **CRC-32** | A checksum that detects accidental corruption of a packet or program image. |
| **FPGA** | Field-programmable gate array: a chip whose logic can be reconfigured to become a custom circuit. |
| **Forwarding** | Passing a result directly to a later instruction before it reaches the register file. |
| **Gate** | The test that must pass before the next phase starts. |
| **Hazard** | A situation where the next instruction in a pipeline cannot safely proceed yet. |
| **ILA** | Integrated logic analyzer: Vivado's on-chip tool for watching live signals. |
| **MMCM** | Mixed-mode clock manager: FPGA hardware that makes clean new clocks from the 100 MHz input. |
| **MMIO** | Memory-mapped I/O: devices controlled through ordinary loads and stores to special addresses. |
| **PC** | Program counter: the address of the instruction being executed. |
| **Retire** | An instruction retires when it has finished and its results are architecturally visible. |
| **RTL** | Register-transfer level: hardware described as registers and the logic between them. |
| **RV32I** | The 32-bit base integer instruction set of RISC-V. |
| **UART** | A simple serial link that sends bytes one bit at a time. |
| **Wishbone** | An open on-chip bus standard; used here only for the debug path. |
| **WNS / WHS** | Worst negative slack (setup) and worst hold slack from the Vivado timing report; negative means timing failed. |
| **XDC** | Xilinx design constraints: the file that maps signals to physical pins and sets timing. |

</details>

**Next acceptance step:** observe the [Phase 6](docs/phases/PHASE6_VGA.md#8-remaining-gate)
monitor gate and the [Phase 7](docs/phases/PHASE7_DEMOS.md#6-acceptance-that-remains)
physical demos when the necessary display/boot setup is available.
Phase 5 results: [performance table](docs/phases/PHASE5_PIPELINE.md#5-board-results).
Tab5 work stays on the independent [portable milestone track](docs/BUILD_PLAN.md#10-tab5-milestones-portable-control-and-diagnostics).
