# Single-cycle debug and diagnostics simulation profile

November 9, 2026. Built on `deafa34`, as software and simulation work done ahead of the
remaining physical Tab5 dependencies. **No T0–T13 hardware gate is passed by this work.**

The existing Basys 3 top keeps debug disabled. No debug pins were assigned, and no board or Tab5
was flashed. The FPGA resource budget and physical integration must be checked before treating
this profile as a board image.

## Implemented scope

| Requested work | Implemented locally | Remaining |
| --- | --- | --- |
| FPGA packet link | Independent bounded COBS/CRC RTL, exact T2 frame/session vectors, dedicated 115200 8N1 UART test | Approved physical debug link and board qualification |
| Debug memory ownership | Classic master, byte selects, ACK/ERR/watchdog, native two-port RAM lending, verified DMA | Planned debug CSR address space; physical readback |
| CPU controls | Single-cycle HALT, RESUME, CPU_RESET, verified-image RUN/RESTART, exact STEP, two pre-execution breakpoints, register/memory access | Pipeline drain/admission and pipeline breakpoint qualification (T7) |
| Observation | Six real 64-bit counters; atomic capture; 256 × 32-byte retirement ring with freeze, order and overwrite counts | Pipeline stage snapshots, pipeline stall/flush/taken events, disassembly/SD exports |
| Loader | Ordered 192-byte chunks, per-write readback, independent actual-RAM CRC pass, BSS clearing/readback, invalid-image interlock | Tab5 SD launcher/container and portable cold boots |
| BIST/faults | Real scratch RAM March C-, actual CPU ALU known answers, one-use scratch read XOR, detection and verified selected-word restoration | Destructive full-RAM option, additional fault targets and on-device diagnostic pages |
| Tab5 client | Real C codec/client worker, selectable packet UART backend, live status, captured registers/counters, Home controls, validity/capability/age labels | Physical link, SD launcher, packet console and advanced touchscreen editors/pages |
| Laptop tools | Typed debugger, validated build-manifest loader, CLI/batch commands, actual Python-to-RTL co-simulation | Physical debug-port tests |

`DEBUG_ENABLE && PIPELINE` is rejected explicitly. The working pipeline and its original tests
remain available with debug disabled. No pipeline control, pipeline snapshot, console-channel
or reference-comparison capability is advertised by this profile.

## Hardware structure and important files

| File | Responsibility |
| --- | --- |
| `scripts/gen_protocol.py`, `rtl/debug/dbg_pkg.sv` | One schema generates C definitions and the SV package; the SV file is generated |
| `dbg_rx.sv`, `dbg_tx.sv` | Bounded streaming decode/encode, CRC and byte backpressure; RAM-style byte buffers |
| `dbg_dispatch.sv`, `dbg_packet.sv`, `dbg_uart.sv` | Lease/session/replay, typed dispatch, packet framing, separate UART endpoint |
| `dbg_wb_master.sv` | One-outstanding B4 Classic transfers; stable CYC/STB/address/data/select through ACK/ERR; watchdog |
| `dbg_ram_arbiter.sv` | CPU/DEBUG/BIST exclusivity, two quiet data edges before lending, fetch disabled during loans, fetch primed before CPU return |
| `dbg_dma.sv` | Bounded 1/2/4-byte element transfers; writes counted only after actual RAM readback |
| `cpu_single.sv`, `rv32i_pkg.sv` | Optional stopped-state register writer and actual-ALU test mux; retirement-boundary control |
| `dbg_executor.sv` | Typed commands, verified-image state, loader, observations and diagnostic coordination |
| `dbg_observer.sv` | Actual retirement capture, counter epochs/generations and circular trace |
| `rtl/diag/hw_bist.sv` | RTL March controller and 16 independently specified actual-ALU known answers |
| `dbg_system.sv` | Board-independent byte-packet endpoint + executor + the actual debug-enabled SoC/RAM |
| `tb/debug/dbg_host_server.sv` | Simulation-only FIFO bridge used by the actual Python client, excluded from synthesizable RTL |
| `host/dbglink/debugger.py`, `program.py`, `rtl_transport.py` | Typed host API, manifest validation and cached Verilator transport |
| `firmware/tab5/t1_ui/main/device/link_device.*`, `link_uart.*` | Pure C asynchronous backend and its ESP-IDF UART worker |

Debug controls preserve the existing register file's single writer and immutable x0. A HALT
request cannot cancel a store that already reached its falling-edge RAM access. STEP releases
one instruction and returns to stopped state after its architectural completion; faults retire
zero instructions, while ECALL/EBREAK retire once and terminate. Breakpoints compare the next
selected instruction before it can change state. A resume bypass permits exactly one real
instruction of progress, including a jump to its own PC.

The CPU keeps its native RAM ports. There is no third port. The debug-only Classic adapter
addresses RAM words with byte selects and rejects high-address aliases/MMIO. The reserved
`0x4000_xxxx` CSR map remains unimplemented; typed register/control commands use the controlled
CPU interfaces directly. This is a bounded Classic profile, without pipelined cycles or RTY.
See chapter 3 of the [OpenCores Wishbone B4 specification](https://kolegite.com/EE_library/datasheets_and_manuals/FPGA/wishbone_spec_B4.pdf).

A lost ACK or an ERR on a write cannot prove that RAM was unchanged. The master reports an
uncertain write; failed/uncertain program edits leave the image invalid. Packet retries reuse
the same session/ID/body and replay the cached terminal reply. They do not repeat the write,
STEP, load chunk or diagnostic operation.

## Typed protocol profile

All fields are little-endian; exact layouts are in `protocol/schema.json`. The base frame and
session contracts are unchanged. Only `length` bytes of a response payload are valid; internal
padding is not part of the wire or replay contract.

| Command | Request | Reply |
| --- | --- | --- |
| HALT / RESUME / STEP / CPU_RESET | Empty | 36-byte STATUS; reset during a long operation returns ACCEPTED + operation ID |
| REG_READ | start u8, count u8, reserved u16 | generation u32, start/count, reserved u16, contiguous u32 values |
| REG_WRITE | index u8, 3 zero bytes, value u32 | generation u32 + actual readback value u32; x0 rejected |
| MEM_READ / MEM_WRITE | address u32, size u8, flags=0 u8, count u16, optional data | READ: generation/count/size/reserved (8 bytes) + data. WRITE: verified count/size/uncertain/address (8 bytes) |
| BREAK_SET / CLEAR | Schema-defined slot, enable and PC fields | OK; LIST returns generation, next PC, triggered slot and two slot records |
| LOAD_BEGIN | 40-byte layout + up to 48 UTF-8 name bytes | Nonzero load ID u32 |
| LOAD_CHUNK | load ID u32, offset u32, byte count u16, reserved u16, 1–192 data bytes | load ID u32 + next verified offset u32 |
| LOAD_COMMIT / ABORT / RUN / RESTART | Matching load/image ID u32 | COMMIT returns ACCEPTED + operation ID u64; RUN/RESTART return actual STATUS |
| COUNTERS_LATCH | Empty | Atomic 64-byte versioned counter capture |
| COUNTERS_READ / TRACE_READ | generation u32, offset u32, count u16, reserved u16 | 12-byte generation/offset/count/record-size prefix + selected captured data |
| TRACE_ARM | flags u32 = 1 (clear and arm) | New generation u32; append/re-arm without clearing is unsupported |
| TRACE_FREEZE | Empty | 48-byte frozen descriptor |
| BIST_START | test ID u8, 3 zero bytes, address u32, bytes u32 | ACCEPTED + operation ID u64 |
| BIST_ABORT / DIAG_RESULT | operation ID u64 | Abort acknowledges the existing operation; RESULT returns the frozen typed result |
| INJECT_ARM | kind=1 u8, trigger=1 u8, duration=1 u16, address/mask/flags=0 u32 | One-use arm ID u32 |
| INJECT_FIRE / CLEAR / RESULT | arm ID u32 | FIRE/CLEAR acknowledge actual completion; RESULT returns 48 bytes of evidence. RESULT ID 0 queries the current record read-only |

Memory commands accept only naturally aligned elements wholly inside the 64 KiB RAM, with at
most 192 data bytes per request. Running-state memory edits are rejected before image state
or ownership changes. Manual verified edits set MODIFIED; a failed edit cannot be resumed.

### Loading and execution

This profile requires load address and entry PC 0, initialized image size 1–53248 bytes, RV32I
ISA 1 / ILP32 ABI 1, flags 0, word-aligned BSS after initialized data and ending at or below
`0xD000`, scratch `0xD000..0xDFFF`, and stack `0xE000..0xFFFF` with initial SP `0x10000`.
Malformed names, bounds and ISA/ABI fields cannot invalidate a previously verified image.

BEGIN invalidates the old image and holds CPU reset. Chunks are strictly contiguous; holes,
overlap, wrong IDs and oversized data are rejected. Each chunk receives actual RAM readback.
COMMIT then **reads the entire initialized image again from FPGA RAM**, computes CRC32, clears
and verifies BSS, and only then marks the image valid. Verification, abort, lease loss and CPU
reset cannot leave a partial image runnable. RUN/RESTART accept a verified image ID, never an
arbitrary PC. CPU-only reset preserves the packet session and verified RAM image.

Poll STATUS for the returned operation ID until DONE/FAILED, then DIAG_RESULT. Loader result
kind 1 is 36 bytes: ID, kind/state/status, completed bytes, expected/observed CRC, error address,
image ID and reserved word. A new operation replaces the previous result. The Python client
does not silently start a new mutation after an uncertain outcome; read actual state/results
and explicitly reconcile first.

### Counters and trace

Counter definition version 1 has width 64 and six events: active CPU cycles, retired
instructions, loads, stores, conditional branches and jumps (JAL/JALR). Cycles exclude stopped
and reset-held time. Capture includes events sampled on its clock edge. The 64-byte record
contains definition/width/count, generation, six u64 values, CPU epoch, stopped flag and reserved
bytes. COUNTERS_READ offsets/counts are bytes, with record size 1. Unsupported stalls, flushes
and branches-taken are shown as unavailable, not as measured zeros.

Trace format 1 is eight little-endian words: order low32, PC, instruction, next PC, destination
value, memory address, store data and flags. Flags are rd-write bit 0, rd bits 1–5, memory-read
bit 6, write strobes bits 7–10, stop cause bits 11–13; other bits are zero. The descriptor gives
full 64-bit first/last order, generation, count/depth, record size, frozen/overwritten flags,
overwritten count and CPU epoch. TRACE_READ uses logical oldest-first record offsets, at most
six records per response. CPU reset invalidates a frozen trace generation. A wrapped trace is
an explicitly bounded history; missing prefix/order gaps never establish a fabricated first
divergence or diagnose a particular RTL component.

### Diagnostics and controlled faults

Memory BIST ID 1 runs March C- over an aligned nonempty subset of the reserved 4 KiB scratch:
write 0 ascending; read 0/write 1 ascending; read 1/write 0 ascending; read 0/write 1 descending;
read 1/write 0 descending; read 0 ascending. Writes additionally get immediate verified
readback. A full scratch run completes 10240 logical cases. It is destructive to scratch;
full/program RAM testing is unsupported. ALU BIST ID 2 requires zero address/length and tests
the **actual halted CPU ALU** through its owned mux with 16 fixed known answers, not a duplicate
ALU or a C reference computation.

Diagnostic result kinds 2 (memory) and 3 (ALU) are 44 bytes: operation ID, kind/state/status,
completed cases, first failing address (ALU vector index), expected/observed value, failure
count, tested range and phase. ALU operation/operand export and a destructive full-RAM mode
remain future work. Abort drains an accepted RAM transaction and returns CPU ownership.

The only injection type implemented is one read-path XOR on one aligned scratch word during
a BIST read, including its verified-write readback. ARM is reset-disarmed and bounded; FIRE
first saves the actual original RAM word. A matching BIST read fires once, records the real
trigger-time baseline and XOR result, and disarms the hook. Detection is linked only when the
diagnostic's address, expected/observed values and one trigger agree. This remains observable
when March writes patterns, unlike a pre-test stored bit flip that March would overwrite.

CLEAR disarms first, restores the saved selected word and verifies actual RAM readback. It
does not promise to restore the entire scratch range. CPU/link reset disarms hooks; an
unrestored reset is recorded as aborted cleanup, never a restoration success. RUN/RESUME/STEP
reject an armed or uncleared injection. These are deliberately modelled hardware faults, not
claims of physical silicon defects or exhaustive fault coverage.

## Running without hardware

From WSL, with the existing Verilator/GCC tools:

```sh
python3 scripts/run_tests.py dbg_ --jobs 1
python3 scripts/run_tests.py cpu_single_debug --jobs 1
python3 scripts/run_tests.py hw_bist --jobs 1
python3 -m unittest discover -s host/tests -v
python3 host/dbglink_cli.py --rtl-sim hello status
```

`--rtl-sim` builds/caches the actual `dbg_system` Verilator executable under
`~/.cache/risc-v-computer/rtl-link/`. It passes complete wire frames through OS FIFOs to the real
packet engine and SoC. Deterministic simulation clocks advance during requests and bounded
idle windows; wall time is not FPGA time. `--sim` remains the T2 BASE_STATUS reference model
and refuses advanced capabilities. Neither option is a physical board test.

Build a normal program with `scripts/build_software.py`. The host validates its adjacent JSON
and BIN (architecture, entry, image/BSS/stack/scratch bounds, CRC32 and SHA256) before loading:

```sh
python3 scripts/build_software.py hello --output-dir build/software/hello
python3 host/dbglink_cli.py --rtl-sim --manifest build/software/hello/hello.json load run
```

The CPU console stays on its separate UART; this command does not fabricate console packets.
Use `--script` for ordered per-command parameters; JSON numeric values are decimal integers:

```json
[
  {"command":"load", "manifest":"build/software/hello/hello.json"},
  {"command":"break-set", "address":0, "slot":0},
  {"command":"run"},
  {"command":"regs"},
  {"command":"step"},
  {"command":"counters"}
]
```

The same typed commands can use `--port COMx` on Windows after the physical endpoint, pins
and timing have been qualified. Do not confuse the existing USB CPU console with that future
dedicated debug port.

## Tab5 backend and evidence boundaries

T1 UI defaults to labelled MOCK. In menuconfig, `T1 UI → Data backend` selects the real packet
UART worker. Pin defaults are **-1/unassigned** and fail visibly until verified assignments
are supplied; no candidate wiring table has been approved by these builds. UART I/O and
COBS/CRC/session work run in one worker with bounded queues and nonblocking FIFO writes.
LVGL callbacks only enqueue commands. There is no automatic MOCK fallback.

Home shows received status, identity and capability-gated controls. Registers/counters are
separately captured with independent ages and validity masks. Missing data stays unavailable;
fresh status cannot refresh an older capture's age. A lost mutation reply locks controls for
reconciliation. Programs remain a disabled MOCK list on a real backend; packet console,
touchscreen editors, SD loading and the advanced pages are pending.

Native screenshots labelled **PACKET TEST FIXTURE** test rendering/policy only; they are not
physical FPGA/Tab5 evidence. Both MOCK and UART firmware profiles compile with ESP-IDF 5.5.6,
BSP 1.3.2 and pinned LVGL 9.5.0. No app was flashed during this work. The UART compile used
ignored, compile-only GPIO settings; repository defaults remain unassigned.

## Verification record

Evidence is under ignored `build/debug-sim/`. The initial complete regression passed 291/291.
A subsequent parallel rebuild hit Verilator 5.020's internal locked-thread-pool failure on
unchanged `debounce_tb`; the final checks use `--jobs 1`. This is recorded separately from RTL
assertion results. Final resource/regression results must be read with the final handoff.

- T2 RTL: all 23 valid and 19 malformed golden frames; 11 session scenarios / 43 replies;
  backpressure, timeout, abort, errors and real-baud dedicated UART simulation.
- Core/executor: 75 typed commands on actual SoC/RAM, plus instruction steps across loads,
  stores, NOP/x0, both branch outcomes, JAL/JALR, repeated PCs, termination and faults;
  pre-store/wrong-path breakpoint checks; reset/abort/invalid-metadata interlocks.
- Observer/BIST: atomic low-word carry and full-width wrap; 256-record ordering/overwrite;
  full scratch March; actual ALU; bounded fault detection/restoration and drained abort.
- Host: codec/session/native-C comparisons, typed workflow/failure tests, and the actual
  Python-to-RTL A-to-B load/control/trace/BIST/fault workflow with an intentionally lost STEP
  reply. This integration test contains no Python CPU implementation.
- Tab5 native: 37 state checks, 122 worker checks under ASan/UBSan, 51 MOCK UI checks per
  orientation and 11 packet-fixture UI checks per orientation. Firmware builds are compile
  evidence; responsiveness, electrical wiring, power and physical gates remain unrun.

`scripts/vivado/synth_debug.tcl` is synthesis-only. It writes utilization/hierarchy/checkpoint
evidence and rejects a profile exceeding the Basys 3 LUT capacity before attempting timing.
The intermediate parallel-buffer designs exceeded the budget; their rejected reports are
preserved in `build/debug-sim/area-*.rpt`. No routed timing, pin qualification or board success
is implied by a simulation or synthesis report.
