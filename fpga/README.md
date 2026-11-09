[Project README](../README.md) › **fpga/**

# `fpga/`: Basys 3 pins and timing

This folder holds the constraints that connect the RTL to the physical Basys 3 board. Read
this page for the current board pins, clock constraints and reserved future connections.

> [!NOTE]
> **Status: 🚧 IN PROGRESS.** [basys3.xdc](basys3.xdc) maps 66 pins in the Phase 6 CPU/UART/VGA top (52 existing plus 14 VGA).
> Phase 4 met 25 MHz timing (WNS +0.367 ns, WHS +0.024 ns), with zero DRC violations;
> the physical USB console passed greeting/counter/echo. [basys3_blink.xdc](basys3_blink.xdc) preserves the original
> 18-pin blink target, which remains available. VGA constraints are implemented; new 25/62.5 MHz timing passes; monitor
> acceptance is unrun. Tab5 pins remain planned.
> Status labels are defined in the [root README](../README.md#2-project-status).

<details open>
<summary><b>On this page</b></summary>

1. [What lives here](#1-what-lives-here)
2. [What `basys3.xdc` maps now](#2-what-basys3xdc-maps-now)
3. [Planned contents](#3-planned-contents)
4. [Clocks](#4-clocks)
5. [Tab5 debug link pins](#5-tab5-debug-link-pins)
6. [Related](#6-related)

</details>

---

## 1. What lives here

An **XDC file** (Xilinx design constraints) is the bridge between the RTL and the physical board.
It does two jobs:

1. **Pin mapping:** it tells Vivado which FPGA package pin each top-level signal uses. For
   example, a signal named `led[0]` has to reach the pin that is actually wired to LED 0.
2. **Timing:** it declares the clocks, so Vivado can check that every signal settles within one
   clock period.

> [!WARNING]
> Any **negative slack** in the timing report means the design may fail on real hardware even if
> it passed in simulation.

---

## 2. What `basys3.xdc` maps now

Pin locations come from the official
[Digilent Basys 3 master XDC](https://github.com/Digilent/digilent-xdc/blob/master/Basys-3-Master.xdc).
The default top is [basys3_soc.sv](../rtl/top/basys3_soc.sv). All 66 SoC pin assignments and
the 18 original blink assignments follow that master. No Pmod wiring is added.

| Signal | Pin | Constraint |
| --- | --- | --- |
| `clk` | W5 | LVCMOS33; clock `sys_clk_pin`, period 10.00 ns (100 MHz) |
| `btnC` | U18 | LVCMOS33; `set_false_path` because the synchronizer handles the asynchronous button |
| `led[0]`–`led[15]` | U16, E19, U19, V19, W18, U15, U14, V14, V13, V3, W3, U3, P3, N3, P1, L1 | LVCMOS33 |
| `sw[0]`–`sw[15]` | V17, V16, W16, W17, W15, V15, W14, W13, V2, T3, T2, R3, W2, U1, T1, R2 | LVCMOS33; synchronized inputs |
| `btnU`, `btnL`, `btnR`, `btnD` | T18, W19, T17, U17 | LVCMOS33; synchronized and debounced, like `btnC` |
| `seg[0]`–`seg[6]`, `dp` | W7, W6, U8, V8, U5, V5, U7; V7 | Active-low segments a–g; decimal point off |
| `an[0]`–`an[3]` | U2, U4, V4, W4 | Active-low digit enables; digit 0 is rightmost |
| `RsRx`, `RsTx` | B18, A18 | Active USB-UART console: 115200 8N1, RX two-stage synchronization; no extra wiring |
| `vgaRed[0..3]` | G19, H19, J19, N19 | Four-bit red DAC |
| `vgaBlue[0..3]` | N18, L18, K18, J18 | Four-bit blue DAC |
| `vgaGreen[0..3]` | J17, H17, G17, D17 | Four-bit green DAC |
| `Hsync`, `Vsync` | P19, R19 | Active-low syncs, registered with RGB |
| Configuration | | `CFGBVS VCCO`, `CONFIG_VOLTAGE 3.3`, compressed bitstream |

Asynchronous human inputs and human indicator outputs have explicit false paths. Internal CPU
paths remain timed, including rising-to-falling RAM paths. The routed report has no unclocked
or unconstrained internal endpoints. Select the legacy blink with `-tclargs basys3_top` in
both the build and programming commands; its separate XDC matches its original ports.

---

## 3. Planned contents

Only pins used by a top are constrained. VGA is now implemented; portable connections remain pending:

| Signal group | Use |
| --- | --- |
| VGA pins (Phase 6) | 12-bit color plus sync; fixed 25 MHz pixels and output delays verified in Vivado; monitor observation unrun |
| Tab5 dedicated UART | Candidate only; requires the T0 electrical gate below |

---

## 4. Clocks

The current hardware uses an MMCM and BUFG to generate 25 MHz from the 100 MHz oscillator
(multiply by 10, divide by 40; 1 GHz VCO). Pipeline and pixel branches below are future work.

```mermaid
flowchart LR
    OSC["100 MHz board oscillator"] --> MMCM["MMCM"]
    MMCM --> C25["25 MHz<br/>single-cycle CPU"]
    MMCM --> CP["pipeline clock<br/>as fast as timing allows"]
    MMCM --> PIX["25 MHz<br/>VGA pixels"]
```

> [!IMPORTANT]
> Clocks are never made by dividing with counters; slow logic uses clock enables.

| Goal | Phase | Result |
| --- | --- | --- |
| Blink at 100 MHz, no MMCM | 0 | ✅ Met: WNS +7.066 ns, WHS +0.268 ns |
| No negative slack at 25 MHz for the single-cycle CPU | 3 | ✅ Met: WNS +0.828 ns, WHS +0.122 ns; generated period 40.000 ns |
| CPU/UART at 25 MHz, plain synchronous reset stage | 4 | ✅ Met: WNS +0.367 ns, WHS +0.024 ns; zero DRC violations and no internal unconstrained endpoints |
| Push the pipeline to 50 MHz and higher until timing fails, and record the top speed | 5 | Not yet run |

---

## 5. Tab5 debug link pins

> [!CAUTION]
> ❔ **NOT APPROVED.** A candidate only, from [HARDWARE_CHECKLIST.md](../docs/tab5/HARDWARE_CHECKLIST.md#3-candidate-uart-cable-not-an-approved-wiring-instruction).
> Do not wire it.

| Direction | Tab5 candidate | Basys 3 candidate |
| --- | --- | --- |
| Tab5 → FPGA | PORT.A G53 (UART TX) | JA1, FPGA pin J1, `dbg_uart_rx` |
| FPGA → Tab5 | PORT.A G54 (UART RX) | JA2, FPGA pin L2, `dbg_uart_tx` |
| Reference | PORT.A GND | A verified JA ground pin |
| Power | PORT.A 5V | **Leave unconnected** |

These pins go into the XDC only after the [T0 electrical gate](../docs/tab5/HARDWARE_CHECKLIST.md#t0-electrical-gate):

- [ ] both board revisions identified;
- [ ] logic levels and idle states verified;
- [ ] no back-powering;
- [ ] continuity checked.

The master XDC file describes rev. B of the board; reconcile it with the actual board before use.

---

## 6. Related

| For | See |
| --- | --- |
| The top-level module these constraints attach to | [rtl/README.md](../rtl/README.md) |
| The build script that reads this file | [scripts/README.md](../scripts/README.md#5-build-the-bitstream-buildtcl) |
| Hardware identification and power | [HARDWARE_CHECKLIST.md](../docs/tab5/HARDWARE_CHECKLIST.md) |

**Current evidence:** [Phase 4](../docs/phases/PHASE4_UART.md#5-verification-record), with saved timing,
clock, utilization and clean DRC reports. The [Phase 3](../docs/phases/PHASE3_BOARD_C.md) reports
remain the earlier Fibonacci build's evidence. No Tab5 wiring approval is implied.


[Phase 6 reviewed reports](../docs/reports/phase6/README.md) supersede Phase 4 timing for
the expanded VGA design: single-cycle 25 MHz WNS/WHS **+0.396/+0.074 ns**, pipeline
62.5 MHz **+0.313/+0.024 ns**, both with 22 RAMB36s and zero DRC violations. Six display
BRAMs are excluded from automatic power-enable optimization to preserve synchronous
read controls. No physical VGA monitor test or programming was performed.
