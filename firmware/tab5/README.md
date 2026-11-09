[Project README](../../README.md) › **firmware/tab5/**

# `firmware/tab5/`: the touchscreen application

This folder will hold the firmware that turns the M5Stack Tab5 into the portable front panel of
the RISC-V computer. Read this page for a short overview; the full design is in
[TAB5_FIRMWARE.md](../../docs/tab5/TAB5_FIRMWARE.md).

> [!NOTE]
> **Status: 🚧 IN PROGRESS.** Two apps exist. [`t0_probe/`](t0_probe/README.md) is the T0
> bring-up check (display, touch and microSD pass on the real Tab5; UART loopback pending).
> [`t1_ui/`](t1_ui/README.md) provides selectable MOCK and real-packet UART backends. Native
> worker/UI checks and both ESP-IDF builds pass; this app and the physical FPGA link have
> not been run on the Tab5. The [simulation record](../../docs/tab5/TAB5_SIMULATION_DEBUG.md)
> distinguishes implemented controls from pending SD/console/advanced screens. Status labels are defined in the
> [root README](../../README.md#2-project-status).

<details open>
<summary><b>On this page</b></summary>

1. [What it will do](#1-what-it-will-do)
2. [Framework](#2-framework)
3. [Planned module structure](#3-planned-module-structure)
4. [Screens and when they become real](#4-screens-and-when-they-become-real)
5. [microSD layout](#5-microsd-layout)
6. [Build and recovery](#6-build-and-recovery)
7. [Related](#7-related)

</details>

---

## 1. What it will do

The M5Stack Tab5 is an ESP32-P4 device with a 5-inch 1280 × 720 touchscreen and microSD. The
firmware will:

- load programs from microSD;
- show the CPU's console output;
- drive the FPGA's debug hardware: halt, resume, step, breakpoints, registers, memory, trace,
  performance counters, self-test and fault injection.

> [!IMPORTANT]
> It is a **controller and observer**. The ESP32-P4 never runs the RISC-V programs being
> demonstrated; those always execute on the FPGA. Anything that is not live hardware data is
> labelled on screen.

| Badge | Meaning |
| --- | --- |
| **LIVE** | Just read from the connected FPGA |
| **CAPTURED** | A frozen hardware snapshot, shown with its age |
| **HISTORICAL** | A stored earlier result, such as an old benchmark |
| **MOCK** | Simulated data for UI development; never mixed with real controls |

---

## 2. Framework

| Choice | Role |
| --- | --- |
| **Native ESP-IDF + FreeRTOS + LVGL**, with one board-support layer matched to the actual device revision | The framework |
| Arduino with M5Unified/M5GFX | Allowed only as an isolated bring-up experiment |

The display/touch/SD probe identified a working board layer: ESP-IDF 5.5.6, BSP 1.3.2 and
LVGL 9.5.0. T1 pins BSP/LVGL and tracks its dependency lockfile. UART, electrical and power
qualification remain open parts of T0.

---

## 3. Planned module structure

The diagram shows the firmware layers, from the screens at the top to the board hardware at the
bottom. Each layer only calls the one below it.

```mermaid
flowchart TD
    UI["ui/<br/>LVGL screens, touch, labels"] --> STATE["state/<br/>connection, CPU, operation state"]
    STATE --> DEV["device/<br/>CPU control, memory, loader, captures"]
    DIAG["diagnostics/<br/>BIST, injection, reference compare"] --> DEV
    DEV --> PROTO["protocol/<br/>typed commands, sessions, retries"]
    PROTO --> TRANS["transport/<br/>UART, COBS, CRC, queues"]
    DEV --> STOR["storage/<br/>microSD manifests, reports"]
    TRANS --> BOARD["board/<br/>display, touch, SD, UART pins"]
    STOR --> BOARD
```

Task ownership:

- One task owns UART I/O and packet processing.
- Worker tasks do file and device operations.
- Only the UI task touches LVGL objects.
- Touch callbacks never block on serial or file access.

---

## 4. Screens and when they become real

| Screen | Enabled at |
| --- | --- |
| Home, Programs, Terminal, System | T1 as MOCK; T5 live |
| CPU Control, Registers, Memory | T3–T4, then STEP and breakpoints at T6–T7 |
| Pipeline, Trace | T8, verified pipeline only |
| Performance | Baseline at T5, full at T9 |
| Diagnostics, Fault Injection | T10, T11 |
| Reference report | T12 |
| Presentation / About | T1 static; verified actions at T13 |

---

## 5. microSD layout

These are example paths, not files that exist:

```text
/programs/<name>/manifest.json
/programs/<name>/program.bin
/expected/<test-id>/reference-data
/reports/<run-id>.json
/reports/<run-id>.csv
```

---

## 6. Build and recovery

> [!NOTE]
> Build instructions are in [t0_probe](t0_probe/README.md) and [t1_ui](t1_ui/README.md).
> T1 defaults to MOCK; real UART defaults to unassigned pins and fails visibly until a verified
> board binding is supplied. Compile success does not authorize wiring or imply a physical gate.

At implementation:

| Goes into Git | Stays ignored (already in `.gitignore`) |
| --- | --- |
| Source, `CMakeLists.txt`, component manifests, `sdkconfig.defaults`, board profile, dependency lockfiles, local assets | `build/`, `managed_components/`, `sdkconfig` |

---

## 7. Related

| For | See |
| --- | --- |
| Full firmware design | [TAB5_FIRMWARE.md](../../docs/tab5/TAB5_FIRMWARE.md) |
| The wire protocol it speaks | [protocol/README.md](../../protocol/README.md) |
| Hardware identification, wiring and power | [HARDWARE_CHECKLIST.md](../../docs/tab5/HARDWARE_CHECKLIST.md) |
| Milestones T0–T13 | [BUILD_PLAN.md](../../docs/BUILD_PLAN.md#10-tab5-milestones-portable-control-and-diagnostics) |

**Next step:** complete the remaining [T0 UART/electrical/power checks](../../docs/tab5/HARDWARE_CHECKLIST.md)
and T1 on-device responsiveness measurements before qualifying a real FPGA connection.
