[Project README](../../../README.md) › [firmware/tab5](../README.md) › **t1_ui/**

# `t1_ui/`: Tab5 touchscreen UI and packet client

The Tab5 application has shared state, Demo/Engineering navigation and two selectable
backends. MOCK remains the default and labels its simulated data. The UART worker uses the
real T2 C codec/client for identity/status, GPR and 64-bit counter captures, plus queued
HALT/RESUME/STEP/CPU_RESET controls. Its physical link is still unverified.

> [!NOTE]
> **Status: 🚧 IN PROGRESS.** Desktop checks pass: 37 state checks, 202 real-link worker checks,
> 51 MOCK UI checks per orientation and 11 packet-fixture UI checks per orientation.
> Both MOCK and UART profiles build with ESP-IDF. No T1 app was flashed; responsiveness and
> memory measurements on the real device remain open. See the [implementation record](../../../docs/tab5/TAB5_SIMULATION_DEBUG.md).

## Screens

| Screen | At T1 | Real at |
| --- | --- | --- |
| Home | Link/CPU/operation state, identity, PC, CPI summary, shortcuts, simulation controls | T5 |
| Programs | Program list with a simulated transfer (progress, success, failure). Run is disabled | T5 |
| Terminal | Bounded 4 KiB console with follow, clear and a visible dropped-bytes count | T5 |
| Registers | x0–x31 with ABI names, hex/decimal, changed highlight, binary detail. Edit is disabled | T4 |
| Counters | Cycles, instructions, stalls, flushes, loads/stores, branches, CPI and an interval-CPI chart | T5 / T9 |
| System | Build, heap, stack, frame time, touch-to-frame time, queue drops (these are measured, not mock) | T2 / T5 |
| About | Static explanation of the project | T1 |
| CPU Control, Memory, Pipeline, Trace, Diagnostics, Fault Injection, Reference | Locked page that says which milestone enables it | T3–T12 |

**Demo** mode lists Home, Programs, Terminal, Counters and About. **Engineering** lists everything.
Switching only changes the view: the model, the terminal buffer and the backend stay as they are.

## How MOCK is kept honest

- A persistent `MOCK DATA` badge in the top bar and an amber banner under it, on every screen.
- Each data card has its own badge: `MOCK`, `MOCK - STALE` or `MOCK - NO DATA YET`.
- Console lines from the mock start with `MOCK>`. The identity says `Basys 3 (MOCK)`.
- In MOCK mode, buttons only drive the simulation. On the UART backend, Home controls enqueue
  real capability/state-gated requests; simulation controls and the MOCK program list are disabled.
- Packet console, SD loading, touchscreen editing and advanced diagnostic pages remain pending.
  Missing registers/counters show unavailable values; separate capture ages cannot be refreshed
  by a newer status packet. A lost or explicitly uncertain mutation locks further controls.
- After an unplug the last values stay on screen, greyed and marked `STALE`.

## Layout

```text
main/
├── app_main.c          Tab5 start-up, FreeRTOS queues and tasks, "T1:" log lines
├── state/app_state.*   the model: three state machines, snapshot, console ring, CPI history
├── device/mock_device.* the MOCK backend (pure C, time-driven)
├── device/link_device.* nonblocking C packet client and capability/capture policy
├── device/link_uart.*   ESP-IDF UART owner, bounded buffers and worker queues
├── port/ui_port.h      what the UI needs from the platform
└── ui/                 LVGL shell (ui.c), helpers, one scr_*.c per screen
sim/                    desktop build: unit tests + LVGL simulator with scripted touch
```

Only the LVGL task touches LVGL. The selected backend sends immutable messages through a bounded
32-entry queue; the UI drains it at 5 Hz. Taps send commands through a bounded 8-entry queue
and never wait. A full queue drops and counts, it never blocks.

## Versions

Same as [`t0_probe`](../t0_probe/README.md), which passed on this Tab5: ESP-IDF v5.5.6,
`espressif/m5stack_tab5` 1.3.2, LVGL 9.5.0. The panel is 720 × 1280 portrait; the UI rotates it
to 1280 × 720 landscape (`idf.py menuconfig` → **T1 UI** → **Screen rotation**; pick 270 if it
is upside down). Portrait works too.

## Build and flash

In the **ESP-IDF 5.5 PowerShell** window:

```
cd C:\Users\Nisha\OneDrive\Desktop\risc-v-computer\firmware\tab5\t1_ui
idf.py set-target esp32p4
idf.py build
idf.py -p COM9 flash monitor
```

Exit the monitor with `Ctrl+]`. `dependencies.lock` is tracked for reproducible dependencies.
The flash command is a manual hardware step; it was not run during the simulation work.

`idf.py menuconfig` → **T1 UI → Data backend** selects MOCK or packet UART. UART defaults
to GPIO **-1/unassigned**, with no automatic MOCK fallback. Do not assign candidate pins until
the [electrical gate](../../../docs/tab5/HARDWARE_CHECKLIST.md) approves them. The separate
UART compile test used ignored compile-only settings and proves compilation only.

## Desktop checks (no Tab5 needed)

From WSL or Linux with `gcc`, `cmake` and `git`:

```
cd firmware/tab5/t1_ui
sim/run_sim.sh
```

It fetches LVGL 9.5.0 once, builds with `-Wall -Wextra -Werror` and the address/UB sanitizers,
runs the unit tests, then drives the real UI by tapping widget centres in landscape and portrait.
It also tests the real packet worker and both orientations with a labelled **PACKET TEST FIXTURE**.
Screenshots land in `build-sim/shots/`. To keep builds on Linux storage when the repository
is on OneDrive, run from the repository root with:

```bash
T1_SIM_BUILD_DIR="$HOME/.cache/risc-v-computer/tab5-ui" bash firmware/tab5/t1_ui/sim/run_sim.sh
```

## T1 gate record (fill in on the device)

1. Flash, then tap through every screen in both modes.
2. On **Programs**, start a simulated load and keep switching screens while it runs.
3. On **Home**, press Unplug, wait for `STALE`, then Reconnect. Press Link error and wait.
4. Open **System** and note frame time, touch-to-frame time, lowest free heap and unused stack.
5. Copy the monitor lines that start with `T1:` into this table.

| Measurement | Target | Result |
| --- | --- | --- |
| Touch to finished frame, max | ≤ 100 ms | ❔ |
| Frame time, max | (record) | ❔ |
| Lowest free heap | (record) | ❔ |
| Unused stack, mock / LVGL task | > 1 KiB each | ❔ |
| Message drops in normal use | 0 | ❔ |
| Mode switch keeps `model` hash in the `T1:` log | same value before and after (with Unplug pressed first) | ❔ |

Touch-to-frame is measured from LVGL seeing the press to the end of the next refresh. It does
not include the touch controller's own scan time.
