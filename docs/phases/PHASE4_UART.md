[Project README](../../README.md) › [Docs index](../README.md) › **Phase 4 UART**

# Phase 4: the CPU console over USB UART

> [!IMPORTANT]
> **Physical gate passed November 7, 2026.** The actual Basys 3 printed `hello, world`,
> advanced its live counter, and echoed 41 text bytes plus all 256 binary values correctly
> on COM8. Simulation passed 101/101 cases; Python checks passed 58/58. Routed 25 MHz timing
> met setup/hold, and the DRC report has no violations. This snapshot later passed hosted
> CI run #16 when PR #6 merged.
> The optional ROM bootloader is deferred at the owner's request. Phase 5 later passed
> ([pipeline record](PHASE5_PIPELINE.md)).

## 1. Hardware and clocking

No extra wiring is needed. The Basys 3's existing micro-USB connection carries the console:
`RsRx` is B18 and `RsTx` is A18 in [basys3.xdc](../../fpga/basys3.xdc). The working CPU entry
point is [basys3_soc.sv](../../rtl/top/basys3_soc.sv); `basys3_top` remains the original blink.

```mermaid
flowchart LR
    CPU["RV32I CPU at 25 MHz"] <--> BUS["native MMIO bus"]
    BUS <--> U["console UART<br/>TX + 16-byte RX FIFO"]
    U <--> FTDI["Basys 3 USB serial bridge"]
    FTDI <--> PC["Windows terminal or uart_check.py"]
```

At 25 MHz, the rounded divider is **217 clocks/bit**: 115,207.37 baud, about +0.0064%
from 115,200. Frames are 8N1, least significant bit first, idle high, without flow control.
TX busy includes the complete stop bit. RX has two synchronization stages, validates the
middle of the start bit, samples each data bit and checks the stop. A bad frame is dropped;
a sustained break reports one error, then reception waits for the line to return high.

| RTL | Responsibility | Self-checking test |
| --- | --- | --- |
| [uart_tx.sv](../../rtl/io/uart_tx.sv) | Latched byte, exact bit timer, ignore start while busy | [uart_tx_tb.sv](../../tb/io/uart_tx_tb.sv): all 256 bytes, busy/data changes, full frame length and reset |
| [uart_rx.sv](../../rtl/io/uart_rx.sv) | Synchronizer, mid-bit samples, false-start/break recovery | [uart_rx_tb.sv](../../tb/io/uart_rx_tb.sv): all bytes in TX loopback and at ±2% and ±4.5% baud (proves the mid-bit sample point); bad stop, false start and reset |
| [uart.sv](../../rtl/io/uart.sv) | MMIO, 16-byte receive FIFO and sticky errors | [uart_tb.sv](../../tb/io/uart_tb.sv): permissions, lanes, full/empty, overflow, wrap, simultaneous full pop/push, seeded random traffic and bursts, and reset |
| Existing [bus](../../rtl/soc/bus.sv)/[soc](../../rtl/soc/soc.sv)/[board top](../../rtl/top/basys3_soc.sv) | Native bus and physical pins; no third RAM port or CPU redesign | Updated bus/SoC tests and [board_uart_tb.sv](../../tb/system/board_uart_tb.sv) with the actual C image |

The board reset boundary now has a plain synchronous register after the two-stage lock
reset pipe. Initial reset stays asserted; release takes three CPU edges. This removes the
asynchronous-set register from the BRAM-control path. The new routed DRC confirms
`REQP-1839` is cleared, with zero violations. Loss of clock lock still invalidates execution; this change
does not promise RAM preservation through an unreliable clock.

## 2. Register and transaction contract

| Address | Register | Contract |
| --- | --- | --- |
| `0x8000_0010` | TX, write only | Lane 0 sends the low byte if idle. A write while busy is ignored; upper lanes do not send. Reads return zero. |
| `0x8000_0014` | STATUS, read only | Bit 0 TX busy; bit 1 RX byte waiting; bit 2 sticky overrun; bit 3 sticky framing error; other bits zero. |
| `0x8000_0018` | RX, read only | Read oldest byte, zero-extended, and pop it. Empty returns zero. Any RX read clears both sticky error flags. |

FIFO overflow **drops the newest byte**, retaining existing unread bytes. A simultaneous pop
and arrival at a full FIFO accepts the new byte without overflow. A new error on the same
edge as a clear wins the clear. STATUS reads and writes to read-only registers do not pop
or clear anything. `0x8000_001C` stays unmapped. Software should use the 32-bit MMIO helpers;
reads of any byte address within the RX word select the same register and consume a byte.

The CPU's existing falling-edge data schedule is preserved. The bus samples RX data before
the pop; UART captures the MMIO request on that falling edge, then updates FIFO/TX state at
the next rising edge. Every FIFO state element has one writer. A previously accepted
transaction is not rolled back by a later CPU reset.

CPU-only reset, halt and reset-held RAM ownership do **not** reset UART. Global system reset
clears the FIFO, errors and serial engines. The full-board test sends a byte while the CPU is
held in reset and verifies it survives the restart. This console remains separate from the
future dedicated Tab5 packet UART; console text is never parsed as debug commands.

## 3. C interface and programs

[uart.h](../../sw/common/uart.h), [uart.c](../../sw/common/uart.c) and
[printf.c](../../sw/common/printf.c) supply:

- `putc`: poll busy, then send one raw byte; `uart_flush` waits for its stop bit to finish.
- `puts`: send a string and append CR LF; no implicit translation is applied by `putc`.
- `getc`: wait for RX available and return an unsigned byte; `uart_try_getc` returns −1
  instead of blocking when the FIFO is empty.
- `uart_status`: read availability and sticky error bits.
- `printf`: `%d`, `%u`, `%x`, `%s`, `%c` and `%%`, returning the emitted byte count. Signed
  minimum and unsigned maximum are supported. Null strings print `(null)`; unsupported
  conversions are emitted literally. Width, precision, floating point and long integers
  are not implemented. Decimal uses shift/subtract division, without multiply/divide helpers.

The builder links the shared C files with garbage collection of unused sections. The RV32I
target, custom startup, ELF checks, scratch/stack reservations and compatible libgcc stay in
place. Existing programs need no console code and retain their independent tests.

[hello/main.c](../../sw/programs/hello/main.c) prints `hello, world`, emits counter 0, then
increments about once per second using unsigned elapsed CPU cycles and echoes received
bytes. The counter also appears on LEDs/hex. It polls RX between updates; the 16-byte FIFO
absorbs short bursts while a counter line is printed. This is bounded buffering, not a
promise to absorb unlimited input without flow control. CPU reset restarts the program;
it preserves UART queues and the existing RAM/reset contract.

[printf_smoke/main.c](../../sw/programs/printf_smoke/main.c) verifies format limits, string/char
cases, return count and blocking `getc`, then flushes and returns through startup to EBREAK.
Both programs run in `cpu_tb`, whose UART mode decodes the actual TX pin and compares literal
expectation files. Default assembly result/fault rules remain in force for existing tests.

The separate `board_uart_tb` loads the **same hello image** on the complete physical top.
It checks greeting, exact echo, a real 25,000,000-cycle counter interval, reception during
counter printing and CPU reset. Its clock/baud/program are not accelerated substitutes.
The runner allows 180 seconds for this real-time board simulation; other tests default to
60. An explicit `--timeout` overrides either limit.

## 4. Build and run

From the repository root in WSL:

```bash
python3 scripts/run_tests.py
python3 -m unittest discover -s scripts/tests -v
python3 scripts/build_software.py hello
```

On Windows with Vivado on PATH:

```powershell
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl
vivado -mode batch -nojournal -nolog -source scripts/vivado/program.tcl
```

The default CPU image is now **hello**. To rebuild Fibonacci instead, use
`-tclargs basys3_soc fib` on the build command. Select `-tclargs basys3_top` for the original
blink build/program. Each build removes its old target bitstream first and writes a new
one only after clock/BRAM and setup/hold checks pass. Programming is volatile JTAG;
the optional ROM loader and configuration flash are not implemented here.

### Windows host checker

```powershell
python -m venv build/host-venv
build/host-venv/Scripts/python.exe -m pip install -r scripts/requirements-host.txt
build/host-venv/Scripts/python.exe -m serial.tools.list_ports -v
build/host-venv/Scripts/python.exe scripts/uart_check.py COM8 --all-bytes --report build/phase4/uart-hardware.json --capture build/phase4/uart-capture.bin
```

Use the actual listed port, not an assumed COM number. COM8 was detected on this owner's
machine. Start the checker **before programming**, or press the centre button after it
prints `Listening`; the greeting is emitted at startup. `--startup-timeout 120` allows time
for a JTAG programming command. Close PuTTY/Tera Term first because COM ports have one owner.

The checker requires the greeting, two increasing counter values and byte-for-byte text
echo. `--all-bytes` additionally tests all 256 binary values. Fragmented counter lines are
handled even when interleaved with echo; corrupt/extra/missing bytes, stalled counters,
short writes, resets and bounded timeouts fail. Its parser tests use deterministic fake
ports and no external Python package; physical serial access uses
[pyserial 3.5](https://pyserial.readthedocs.io/en/latest/pyserial_api.html).
The referenced ECE 362 Lab 7 tester was not present in this repository; this checker is an
independent implementation of the greeting/counter/echo requirements.

### Interactive terminal

Use PuTTY's **Serial** connection on the same COM port: **115200, 8 data bits, no parity,
1 stop bit, flow control None**, with local echo off. A portable executable is available
from the [official PuTTY download page](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html).
After connecting, press centre reset to see the greeting; typed bytes should be echoed by
the FPGA CPU. Do not run the checker while the terminal owns the port.

## 5. Verification record

Source: local Phase 4 working tree, based on `2d64d52`, before it was committed.
Tools: WSL Ubuntu Verilator 5.020 and RISC-V GCC 13.2.0; Windows Vivado 2025.2;
Windows Python 3.14 with pyserial 3.5. The original CPU/core/RAM are unchanged.

| Check actually run | Result |
| --- | --- |
| Full regression, `--binary --timing --assert -Wall` | **101/101 passed**: 20 unit benches and 81 program runs, no Verilator warnings |
| Python unittest discovery | **58/58 passed**, including real-pin UART checker failures and 14 deterministic host-checker cases |
| Standalone lint | **21/21 RTL modules and 23/23 benches**, `--lint-only --timing --assert --trace -Wall`, no warnings |
| Final edge-case reruns | UART/full-board **2/2 passed** after adding new-framing-error versus simultaneous clear; RX **1/1 passed** with all bytes at exactly ±2% baud (integer time resolution) |
| C formatting and input | `printf_smoke` verifies all supported conversions, integer limits, return count, getc and EBREAK; no multiply/divide helpers linked into console images |
| Full-board UART simulation | Actual hello image, actual clock/baud and a real one-second interval; exact echo, concurrent paste and CPU-reset reception all pass |
| Routed timing | **WNS +0.367 ns, WHS +0.024 ns**, generated CPU period 40.000 ns; both margins remain small |
| Clock coverage | No unclocked/unconstrained internal endpoints, multiple clocks or timing loops |
| Resources | **1,471 LUTs** (1,421 logic + 50 memory), **402 flip-flops**, **16 RAMB36**, **0 latches** |
| Routed DRC | **Zero violations**; previous `REQP-1839` warnings are cleared |
| Bitstream | Written successfully; synthesis has ordinary unused-bit/constant/BRAM-mapping warnings, no errors or critical warnings |
| Physical programming | Volatile JTAG succeeded on `xc7a35t_0`, startup HIGH; no flash modification |
| Physical UART gate | COM8 115200 8N1: greeting received, counter 0→1, **41/41 text bytes and 256/256 binary values echoed exactly** |
| Observed counter cadence | Two serial reads were 1.014 seconds apart; USB/host read timing is not a cycle-accurate benchmark |
| Interactive terminal | PuTTY 0.85 opened on COM8 and visibly displayed successive live counters; left open for the owner |
| Phase 4 hosted CI | **Not run**, because these changes remain local |

Handoff checks parse all eight Python files, validate task JSON/CI YAML, resolve 871 local
Markdown links/anchors across 25 documents, and pass `git diff --check`. All 44 Mermaid
blocks parse with the Mermaid 11.4.1 parser (see the audit below); rendering was not checked.

The board hello binary is byte-identical to the simulated image: **1,525 bytes**, padded to
1,528 in `.mem`, CRC-32 **`2cdf25cb`**, SHA-256
**`47c9e893fdbbf4d50baa6dab9295d87a2f96357ab5e12a991fcfb036d2febcd5`**.
This compares the image supplied to Vivado with the simulation input; runtime FPGA RAM
readback remains T5 work. A requested host evidence report starts as failed and becomes
passed only after all serial checks complete, so failed/interrupted reruns cannot leave
an older PASS looking current.
The portable PuTTY executable was downloaded from its official release and checked against
the release SHA-256 and its valid Simon Tatham Authenticode signature. It is local tooling
under ignored `build/tools/`, not a repository dependency.

Reviewed routed reports: [timing](../reports/phase4/timing_summary.rpt),
[utilization](../reports/phase4/utilization.rpt), [clocks](../reports/phase4/clocks.rpt),
[constraint coverage](../reports/phase4/check_timing.rpt), [DRC](../reports/phase4/drc.rpt).
Only line endings and trailing whitespace are normalized for Git. False-path human and
asynchronous UART pins explain the report's missing external input/output delay notices;
no internal endpoint is unconstrained. Maximum frequency and power were not measured.

The existing Phase 3 reports remain historical evidence. New hardware results belong under
`docs/reports/phase4/`; local build/host logs go under ignored `build/phase4/` and simulation
logs under Ubuntu's `$HOME/.cache/risc-v-computer/phase4/`.

## 6. Next boundary

At the time of this record Phase 5 had not started; it has since passed
([PHASE5_PIPELINE.md](PHASE5_PIPELINE.md)). The optional recovery bootloader stays deferred.
Tab5 hardware identification, dedicated framed link, debug control, runtime loader, BIST,
fault injection and portable power remain their own milestones.

---

**Related:** [Build plan](../BUILD_PLAN.md) · [Phase 4 audit](PHASE4_AUDIT.md) · [Phase 3 audit](PHASE3_AUDIT.md) ·
[Scripts](../../scripts/README.md) · [Software](../../sw/README.md) · [Tests](../../tb/README.md)
