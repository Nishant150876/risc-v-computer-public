[Project README](../../README.md) › [Docs index](../README.md) › **Original Tab5 requirements**

# Extra M5Stack Tab5 Integration — Portable RISC-V Silicon Debug, Diagnostics, and Demonstration Platform

> [!NOTE]
> **This is the owner's original Tab5 proposal, preserved word for word.** It is the record of
> intent that every other document traces back to. Only the layout has changed: sentences are
> grouped into paragraphs and lists, key constraints are highlighted in callout boxes, and
> navigation and short group labels have been added. No sentence has been reworded, added to or
> removed.

How to use this document:

- **Section *n* is requirement REQ-*n*.** Each section links to the row in the
  [verification matrix](VERIFICATION_MATRIX.md) that says which milestone delivers it and how it
  will be proven.
- **It states intended functionality, not progress.** Scheduling and acceptance gates are in the
  [build plan](../BUILD_PLAN.md); the technical contracts that implement it are in the
  [integration architecture](TAB5_INTEGRATION.md) and the [debug protocol](DEBUG_PROTOCOL.md).
- **Status:** 📋 PLANNED. No Tab5 milestone has passed yet.

<details open>
<summary><b>Contents: 35 sections in 10 groups</b></summary>

| Group | Sections |
| --- | --- |
| **Purpose, roles and portability** | [1. Overview and Main Objective](#1-overview-and-main-objective) · [2. Existing Project Context](#2-existing-project-context) · [3. Main Design Philosophy](#3-main-design-philosophy) · [4. Standalone and Portable Operation](#4-standalone-and-portable-operation) · [5. Tab5 as the Main Display of the RISC-V Computer](#5-tab5-as-the-main-display-of-the-risc-v-computer) · [6. Two Main Application Modes](#6-two-main-application-modes) |
| **Communication and bus** | [7. Direct Communication Between Tab5 and FPGA](#7-direct-communication-between-tab5-and-fpga) · [8. Wishbone Debug Bus Integration](#8-wishbone-debug-bus-integration) |
| **CPU control and state access** | [9. Hardware CPU Halt, Resume, and Reset](#9-hardware-cpu-halt-resume-and-reset) · [10. True Instruction-Level Single-Stepping](#10-true-instruction-level-single-stepping) · [11. Hardware Breakpoints](#11-hardware-breakpoints) · [12. Register Inspection and Modification](#12-register-inspection-and-modification) · [13. Memory Viewer and Editor](#13-memory-viewer-and-editor) |
| **Program loading and console** | [14. Program Loading Directly From the Tab5](#14-program-loading-directly-from-the-tab5) · [15. CPU Software Console on the Tab5](#15-cpu-software-console-on-the-tab5) |
| **Observation and performance** | [16. Live Five-Stage Pipeline Visualization](#16-live-five-stage-pipeline-visualization) · [17. Instruction Retirement Trace Buffer](#17-instruction-retirement-trace-buffer) · [18. Performance Monitoring and Hardware Counters](#18-performance-monitoring-and-hardware-counters) |
| **Self-test, faults and reference comparison** | [19. Built-In Self-Test System](#19-built-in-self-test-system) · [20. Controlled Fault Injection](#20-controlled-fault-injection) · [21. Automated Diagnostic Comparison Against a Reference Model](#21-automated-diagnostic-comparison-against-a-reference-model) |
| **Screens, demo flow and firmware** | [22. User Interface Screens](#22-user-interface-screens) · [23. Career-Fair Demonstration Mode](#23-career-fair-demonstration-mode) · [24. Firmware Architecture on the Tab5](#24-firmware-architecture-on-the-tab5) |
| **Engineering process and physical design** | [25. FPGA RTL Architecture for the Diagnostics System](#25-fpga-rtl-architecture-for-the-diagnostics-system) · [26. Verification and Testing Requirements](#26-verification-and-testing-requirements) · [27. Power, Reliability, and Physical Design](#27-power-reliability-and-physical-design) · [28. Development Order and Integration Strategy](#28-development-order-and-integration-strategy) |
| **Demonstrations** | [29. First Complete Standalone Demonstration](#29-first-complete-standalone-demonstration) · [30. Final Complete Demonstration](#30-final-complete-demonstration) |
| **Documentation, extensions, constraints and vision** | [31. Documentation and Portfolio Requirements](#31-documentation-and-portfolio-requirements) · [32. Additional Features That Could Be Added Later](#32-additional-features-that-could-be-added-later) · [33. Technical Constraints and Important Design Decisions](#33-technical-constraints-and-important-design-decisions) · [34. What I Want You to Do With My Existing Codebase](#34-what-i-want-you-to-do-with-my-existing-codebase) · [35. Final Vision](#35-final-vision) |

</details>

---

## 1. Overview and Main Objective

<sub>REQ-01 · [How it will be proven](VERIFICATION_MATRIX.md#purpose-roles-and-portability-req-01req-06)</sub>

I want to add a major new feature to my existing RISC-V computer project using my M5Stack Tab5, which is an ESP32-P4-based touchscreen development device. You have already examined my existing project, codebase, architecture, development plan, and progress. I want you to use that understanding to integrate this new feature into the project properly. This is not a separate project, and I do not want to abandon or unnecessarily rewrite any of the work we have already completed.

The goal is to extend my existing RISC-V computer into a complete, portable, standalone computing and silicon diagnostics platform that I can physically carry to university events, career fairs, interviews, engineering demonstrations, and other locations without needing to bring a laptop, external monitor, keyboard, or internet connection.

I want the finished system to consist primarily of two devices.

- The first is my Digilent Basys 3 FPGA board, which will contain the RISC-V processor that we are building from scratch in SystemVerilog, along with its memory, buses, peripherals, debugging infrastructure, and diagnostic hardware.
- The second is my M5Stack Tab5, which will act as the main touchscreen display, user interface, program launcher, processor debugger, performance-monitoring console, and hardware diagnostics controller.

The Tab5 will communicate directly with the FPGA through a hardware communication interface. Initially, I want to use UART because it is relatively simple to develop, test, and debug. Later, we can consider upgrading to SPI for faster communication if doing so provides a meaningful benefit.

The Tab5 must not simply display pictures or graphics generated by the FPGA. Instead, it should be an intelligent control and observation device that communicates with the FPGA, issues commands, reads processor state, displays execution information, loads programs, and controls diagnostic operations. The primary computing hardware must remain the custom RISC-V processor inside the Basys 3.

> [!IMPORTANT]
> The ESP32-P4 inside the Tab5 must not secretly execute the RISC-V programs that are supposed to be running on our custom FPGA processor. The Tab5 can run its own firmware, user interface, communication protocol, and reference-model software, but whenever we demonstrate a program running on our designed CPU, that program must genuinely execute on the FPGA. This distinction is extremely important because the main purpose of the project is to demonstrate my understanding of processor architecture, RTL design, verification, embedded systems, hardware debugging, and silicon diagnostics.

I want the finished project to feel like a miniature professional processor bring-up and post-silicon diagnostics environment. The long-term goal is to have a system where I can power everything on, select a program from the Tab5, load that program into the FPGA computer, run it on my own RISC-V processor, inspect what the processor is doing, halt execution, single-step instructions, set breakpoints, investigate failures, run hardware self-tests, inject controlled faults, and display meaningful diagnostic reports.

Everything required for the demonstration should work locally without relying on cloud services, internet access, a laptop, or an external computer. This is intended to become the main demonstration and one of the most important technical features of my entire RISC-V project.

---

## 2. Existing Project Context

<sub>REQ-02 · [How it will be proven](VERIFICATION_MATRIX.md#purpose-roles-and-portability-req-01req-06)</sub>

Our existing project is a RISC-V computer being developed from scratch in SystemVerilog for the Digilent Basys 3 FPGA board. The original development plan starts with a complete RV32I single-cycle processor and eventually advances to a five-stage pipelined processor.

The pipeline stages are Instruction Fetch, Instruction Decode, Execute, Memory, and Write Back.

The intended processor includes the complete base RV32I instruction set, an ALU, register file, instruction decoder, immediate generator, branch logic, load/store unit, forwarding logic, hazard detection, pipeline flushing, and the memory and peripheral infrastructure needed to run bare-metal C programs.

The original architecture uses 64 KB of unified dual-port block RAM for instructions and data. The intended memory map places main RAM between 0x00000000 and 0x0000FFFF, with memory-mapped peripherals beginning at 0x80000000.

Existing planned peripherals include LEDs, switches, buttons, seven-segment displays, UART, performance counters, and VGA functionality. The original project also includes testing using Verilator, waveforms using GTKWave, FPGA synthesis and implementation using Vivado, bare-metal C software compiled using the RISC-V GCC toolchain, automated tests, and eventual performance measurements.

We also planned to retain the single-cycle processor as a reference implementation for checking the pipelined processor. All of these remain important.

> [!IMPORTANT]
> However, since you have already examined the actual codebase, you must treat the current source code as the authoritative source of what has really been implemented. The original development document contains planned features, and those features must not be mistaken for completed work.

Some components may already exist, some may be partially implemented, and others may still be entirely unfinished. Before integrating the Tab5, inspect the actual current modules, memory interfaces, UART implementation, bus architecture, top-level design, testbenches, constraints, scripts, and software environment. Identify what already works, what can be reused, and what needs to be added.

> [!WARNING]
> Also, do not assume the existing memory-mapped bus is already a Wishbone bus. The original CPU plan describes memory-mapped addressing, but Wishbone integration was not necessarily implemented.

I have experience working with Wishbone interfaces in another hardware project, and I would like to incorporate a clean Wishbone-based debug access architecture here where appropriate. However, this should be done carefully and without unnecessarily replacing a working processor memory interface. The Tab5 integration must build on our existing CPU roadmap rather than interfere with the fundamental processor development.

---

## 3. Main Design Philosophy

<sub>REQ-03 · [How it will be proven](VERIFICATION_MATRIX.md#purpose-roles-and-portability-req-01req-06)</sub>

> [!IMPORTANT]
> The entire integration must follow one principle: the Tab5 is the external control and observation system, while the FPGA implements the actual processor and the hardware required to debug it.

The difficult engineering work should primarily exist in our SystemVerilog design.

- For example, when I press HALT on the Tab5, the Tab5 sends a command to the FPGA. The FPGA must contain the hardware control logic that safely stops the processor.
- When I press STEP, the FPGA must advance the processor by exactly one architecturally retired instruction.
- When I set a breakpoint, the FPGA must contain hardware capable of detecting the relevant instruction address and stopping execution.
- When I inspect registers, the FPGA must provide an actual hardware-access mechanism for reading the internal register file.
- When I request an instruction trace, the FPGA must provide trace information captured during genuine CPU execution.
- When I run a memory self-test, the test must actually exercise the FPGA memory.
- When I inject a fault, the corruption must occur in real FPGA state through deliberately designed and controlled hardware hooks.

The Tab5 is responsible for presenting these capabilities through a professional touchscreen application. It should manage communication, user commands, display updates, program files, diagnostic results, and test orchestration.

I want the result to demonstrate genuine hardware-software co-design rather than merely placing a graphical interface in front of simulated data.

> [!IMPORTANT]
> All displayed processor information must come from actual FPGA hardware whenever the device is operating in live mode. Any demonstration using generated, simulated, or prerecorded information must be clearly labeled and kept separate from actual hardware measurements.

---

## 4. Standalone and Portable Operation

<sub>REQ-04 · [How it will be proven](VERIFICATION_MATRIX.md#purpose-roles-and-portability-req-01req-06)</sub>

Portability is one of the most important requirements. I want to be able to carry the completed system into a career fair and demonstrate it immediately.

**The enclosure**

- Ideally, the Basys 3 and Tab5 should be physically mounted together in a compact portable enclosure or presentation stand.
- The Tab5 should be positioned at the front so that the touchscreen is clearly visible.
- The Basys 3 should also be visible, either beside the Tab5 or through a transparent section of the enclosure, so that people can see that a real FPGA board is running the processor.
- The final arrangement should be portable, organized, and presentable.
- It should not look like a temporary breadboard experiment with loose wires scattered across a table.

**Power and wiring**

The system should use a short, protected communication cable between the Tab5 and FPGA. Both devices must receive proper power.

I would prefer a portable USB power bank or another suitably designed portable power solution. We must verify the actual power requirements rather than assume that one board can safely power the other. The standard Tab5 and Tab5 Kit have different battery configurations, so the power architecture must account for the specific device I own. It may be necessary to power the FPGA and Tab5 from separate regulated outputs of the same power bank or from a combination of the Tab5's battery and a separate FPGA supply.

Whatever arrangement we choose must be electrically safe, reliable, and practical for repeated demonstrations. The communication wiring must use compatible logic voltage levels, proper grounding, and verified connector pin assignments. We must inspect the official Tab5 schematic and Basys 3 documentation before finalizing the wiring.

**Startup and recovery**

- The finished system must boot automatically.
- The Basys 3 should be configured to load the FPGA bitstream from its onboard nonvolatile configuration flash, rather than requiring Vivado and a JTAG connection every time it powers on.
- The Tab5 should store its own firmware internally and launch the diagnostics application automatically.
- The startup sequence should work even if the Tab5 and FPGA become ready at different times.
- The Tab5 should wait for the FPGA, establish communication, verify that the correct protocol is running, and display the connection status.
- If the FPGA is disconnected, resetting, or not responding, the Tab5 should display a clear message rather than freezing.
- When the connection returns, the application should recover automatically.

> [!IMPORTANT]
> I want the final system to pass a genuine cold-boot test: completely disconnect the laptop, switch everything off, power both devices from their portable power sources, and successfully run the full demonstration. No laptop should be necessary for normal operation.

A laptop will still be used during development to modify SystemVerilog, rebuild FPGA bitstreams, compile firmware, and create new software programs. However, once the system is prepared, the normal demonstration must work independently.

---

## 5. Tab5 as the Main Display of the RISC-V Computer

<sub>REQ-05 · [How it will be proven](VERIFICATION_MATRIX.md#purpose-roles-and-portability-req-01req-06)</sub>

The Tab5 should replace the laptop terminal and external VGA monitor as the primary user interface for demonstrations. This does not mean removing existing VGA or UART functionality. If VGA functionality already exists or is planned, we should preserve it where practical. However, completing VGA should no longer be a prerequisite for showing the computer to another person.

I want to open the Tab5 application and see information about my custom processor. The home screen should display the processor connection status, processor architecture, current execution state, current program, clock frequency, program counter, total cycles, instructions retired, and other important information.

The application should distinguish among states such as disconnected, initializing, ready, running, halted, breakpoint reached, test running, and error. The user interface should also allow me to launch programs, stop execution, restart programs, inspect registers, view memory, open the terminal, analyze performance, and access advanced diagnostics.

The Tab5 has a 5-inch 1280 by 720 touchscreen, so the interface should be designed around that screen size rather than simply displaying a desktop interface scaled down.

- The main screen should prioritize readability and quick operation.
- Important controls must be large enough to use comfortably.
- The application should be visually professional, with clear sections, well-organized information, readable hexadecimal values, meaningful colors, and concise error messages.
- I want a consistent interface that feels like an actual embedded diagnostic instrument.
- Avoid unnecessary animations that reduce responsiveness or make technical information harder to understand.

> [!IMPORTANT]
> The user interface must remain responsive even while the FPGA is running a long program, transferring data, or performing a diagnostic test. The firmware must avoid blocking the entire touchscreen application while waiting for a communication response.

---

## 6. Two Main Application Modes

<sub>REQ-06 · [How it will be proven](VERIFICATION_MATRIX.md#purpose-roles-and-portability-req-01req-06)</sub>

I want the Tab5 to have two major user-facing modes: Demo Mode and Engineering Mode. Demo Mode should be optimized for career fairs and presentations. Engineering Mode should provide deeper processor debugging and diagnostics. Both modes should use the same underlying communication protocol and hardware infrastructure.

Demo Mode should make the system impressive and easy to understand even for someone who has never studied CPU architecture. It should display a simple explanation of the processor, a visual representation of the five-stage pipeline, a few performance measurements, and large buttons to launch demonstrations. I want someone to be able to understand the basic idea within approximately one minute. Demo Mode should include several preloaded RISC-V programs and a guided sequence that shows the processor executing real instructions.

Engineering Mode should expose detailed information such as the complete register file, current program counter, instruction words, disassembly, pipeline-stage information, memory contents, hardware breakpoints, instruction trace, performance counters, self-test results, and fault-injection tools.

It should be possible to switch between these modes without rebooting the FPGA or losing the current program, except where a particular diagnostic operation requires a controlled reset.

Demo Mode is for presentation. Engineering Mode is for proving the depth of the hardware design.

---

## 7. Direct Communication Between Tab5 and FPGA

<sub>REQ-07 · [How it will be proven](VERIFICATION_MATRIX.md#communication-and-bus-req-07req-08)</sub>

The first major infrastructure feature is a reliable bidirectional communication link between the M5Stack Tab5 and the Basys 3. I want to begin with UART.

**Physical connection**

- The Tab5's ESP32-P4 should communicate through suitable exposed GPIO/UART pins, and the FPGA should communicate through assigned Pmod pins or another electrically appropriate connection.
- Do not assume that the Tab5's generic GPIO numbering is identical to older M5Stack devices.
- Use the actual Tab5 hardware documentation, schematic, and M5-Bus pinout.
- Also inspect the Basys 3 master XDC before selecting FPGA pins.
- The connection should include transmit, receive, and common ground, using compatible signal levels.
- Avoid connecting power pins between the devices unless the electrical design has been explicitly verified.

**Keeping debug and console traffic separate**

We need to decide whether the FPGA already has a UART peripheral and whether it is suitable for reuse. If an existing UART module serves C-program output, we must not allow debug packets and normal program text to interfere with one another.

My preferred architecture is to keep the hardware diagnostics link logically separate from the CPU's ordinary software console. For example, we could use a dedicated debug UART endpoint on FPGA Pmod pins while preserving the existing CPU UART peripheral and onboard USB-to-UART path for development. Later, we can expose the CPU software console through the Tab5 using packetized messages over the debug link. This would let us keep one physical Tab5-to-FPGA cable while supporting multiple logical functions.

**The packet protocol**

The communication protocol must be designed intentionally rather than sending random text commands without defined framing. It should have a versioned packet format, message type, command identifier, request identifier or sequence number, payload length, payload, and error-detection field such as CRC. Responses should identify the command they correspond to.

The protocol must support positive acknowledgments, negative acknowledgments, timeouts, invalid commands, corrupted packets, and recoverable communication failures.

We should support chunked transfers because program files and instruction traces will be larger than individual register values. Large transfers should include bounded packet sizes, checksums, acknowledgment handling, and recovery from missing or corrupted chunks.

Commands that modify hardware state should have clear execution semantics.

> [!CAUTION]
> A communication timeout must not cause the firmware to blindly repeat a write or fault-injection command if doing so could create an unintended second operation. We should use transaction identifiers or another mechanism to make retries safe.

The protocol should also support connection discovery, firmware or protocol version reporting, hardware capability reporting, and health checks. This will let the Tab5 determine which features are actually available in the FPGA rather than assuming every planned diagnostic engine has been implemented.

We should document the complete packet protocol so it can also be used from a Python test tool on a laptop during development. I want this communication system to be thoroughly tested before building complicated touchscreen features around it.

---

## 8. Wishbone Debug Bus Integration

<sub>REQ-08 · [How it will be proven](VERIFICATION_MATRIX.md#communication-and-bus-req-07req-08)</sub>

One of my major goals is to incorporate a real hardware bus interface as part of this integration. I have worked with Wishbone-related hardware in another project, and I would like to apply that experience here.

The proposed architecture is to implement a UART-to-Wishbone debug bridge.

1. The UART packet engine receives commands from the Tab5.
2. A command decoder translates requests into internal operations.
3. For memory-mapped accesses, the debug bridge acts as a Wishbone master.
4. The Wishbone interconnect routes transactions to appropriate memory or peripheral targets.

The debug interface should support reading and writing 32-bit words, and preferably byte and halfword operations where justified by the architecture. It should use appropriate acknowledgment, stall, and error-handling behavior for the selected Wishbone version and interface.

> [!IMPORTANT]
> However, I do not want to completely redesign a working CPU memory interface merely to add Wishbone. Please inspect the existing RTL before deciding how extensively Wishbone should be introduced.

If the existing CPU already uses a simple RAM interface, we can implement a compatible bridge, arbiter, or adapter. If the memory-mapped bus is not implemented yet, we can design the interconnect with future debugging requirements in mind.

The CPU and the debug master may both need access to main memory or peripherals. We must define how those requests are arbitrated.

For the first implementation, it is acceptable to restrict certain debug reads and writes to periods when the CPU is safely halted. This will simplify memory consistency and prevent the debugger from corrupting an actively running program. Later, selected nonintrusive monitoring functions can remain available while the processor runs.

> [!WARNING]
> The 64 KB dual-port RAM requires particular attention because one port may already be used for instruction fetch and the other for CPU loads and stores. We must not assume that an additional debug master can directly use a nonexistent third RAM port.

The implementation should use safe access arbitration or controlled port multiplexing. The bridge also needs clear address decoding and protection against invalid memory accesses.

We should reserve a documented address region or internal debug-register address space for diagnostic features, but we must not assign arbitrary permanent addresses until we inspect the existing memory map. The final address allocation must not conflict with RAM, boot ROM, existing peripherals, VGA, or simulation-only addresses.

---

## 9. Hardware CPU Halt, Resume, and Reset

<sub>REQ-09 · [How it will be proven](VERIFICATION_MATRIX.md#cpu-control-and-state-access-req-09req-13)</sub>

The Tab5 must be able to control CPU execution. I want dedicated touchscreen controls for HALT, RESUME, STEP, and RESET. These actions must correspond to actual hardware behavior implemented in the FPGA.

- HALT should stop the processor at a defined and consistent architectural boundary.
- RESUME should continue execution from the halted processor state.
- RESET should restore processor state according to our documented reset behavior.
- We may also provide a separate restart-program command that initializes execution from the selected program's entry point.

> [!CAUTION]
> It is extremely important that the processor not be halted by simply disabling an arbitrary clock signal. We should use a clock-safe control mechanism, such as controlled pipeline enables, valid/ready coordination, or an appropriate drain-and-stop procedure.

For the five-stage pipelined CPU, several instructions may be in flight simultaneously. A halt request must not leave memory writes partially executed, duplicate architectural side effects, lose instructions, or produce an inconsistent state.

One reasonable initial strategy is to stop fetching new instructions, allow appropriate in-flight instructions to complete, and then enter a defined halted state. The exact approach must be designed around our actual pipeline implementation.

When the processor is halted, the Tab5 should report that state clearly. It should be possible to inspect the architecturally committed register values and memory.

The debug system must define the meaning of the reported program counter. For example, it must distinguish between the last retired instruction PC and the next instruction that would execute. This becomes especially important for breakpoints and single-stepping.

The control module should generate clean status information such as running, halt requested, safely halted, halted at breakpoint, or fault. We must verify that halting and resuming do not alter the architectural results of the program, except when the user intentionally changes state through the debugger.

---

## 10. True Instruction-Level Single-Stepping

<sub>REQ-10 · [How it will be proven](VERIFICATION_MATRIX.md#cpu-control-and-state-access-req-09req-13)</sub>

One of the most important features is real hardware single-stepping. When I press STEP on the Tab5, I want the processor to execute exactly one architectural instruction and return to a halted state.

> [!WARNING]
> This must not merely advance the FPGA by one clock cycle.

In a five-stage pipeline, an instruction can require multiple cycles to travel through the processor. The processor may also experience stalls, flushes, jumps, branches, or memory delays. Therefore, the single-step mechanism should be based on instruction retirement or another rigorously defined architectural completion event.

A successful step must account for the next instruction to execute, any younger instructions already in flight, and the correct handling of side effects. The implementation must ensure that exactly one intended instruction commits before the CPU returns to a halted state. Special cases should include branches, jumps, loads, stores, load-use stalls, and instructions that terminate execution.

The single-step feature should initially be verified using carefully controlled programs. Once it works, the Tab5 should display the new PC, instruction, changed registers, and relevant execution status after each step. I want to be able to tap STEP repeatedly and watch a C program progress instruction by instruction.

This will be one of the main live demonstrations at career fairs.

---

## 11. Hardware Breakpoints

<sub>REQ-11 · [How it will be proven](VERIFICATION_MATRIX.md#cpu-control-and-state-access-req-09req-13)</sub>

I want to implement actual hardware execution breakpoints. The Tab5 should allow me to enter or select an instruction address and enable a breakpoint.

The FPGA must store the breakpoint configuration in dedicated hardware registers. During execution, the debug hardware should compare the relevant instruction PC against the configured breakpoint address.

When the processor reaches the breakpoint, execution should stop before that instruction produces architectural side effects. The implementation must define how the breakpoint interacts with the pipeline.

> [!WARNING]
> Simply comparing the retirement PC and halting afterward may be too late if the intended behavior is to stop before the breakpoint instruction executes. We should design this correctly rather than using a misleading approximation.

For an initial implementation, supporting one or two instruction-address breakpoints is sufficient. We can expand the number later.

The debugger should support enabling, disabling, clearing, and listing breakpoints. It should report which breakpoint triggered and the corresponding PC.

Resuming from a breakpoint must not immediately trigger the same breakpoint again without making progress. We should implement a safe mechanism to step past a breakpoint or temporarily suppress its retriggering for the appropriate instruction.

Future extensions could include memory watchpoints, conditional breakpoints, or data-access triggers. However, those should only be added after basic execution breakpoints are thoroughly verified.

---

## 12. Register Inspection and Modification

<sub>REQ-12 · [How it will be proven](VERIFICATION_MATRIX.md#cpu-control-and-state-access-req-09req-13)</sub>

The Tab5 should provide access to the RISC-V architectural register file.

I want a register screen that displays all 32 general-purpose registers, with their numeric identifiers and standard ABI names where useful.

- The screen should show each register's current value in hexadecimal.
- It would also be useful to display selected values in signed decimal, unsigned decimal, or binary format.
- The register screen should clearly indicate which registers changed after the previous instruction.

For example, after stepping through an ADD instruction, the destination register could be highlighted.

The values must come from the real FPGA register file. The debug interface should provide a controlled method for accessing the register file while the CPU is halted.

Since the existing register file may only have two CPU read ports and one CPU write port, we must design access carefully. Options include adding a debug read/write path, multiplexing existing access ports while halted, or providing a controlled state-access mechanism. We must preserve normal CPU behavior.

> [!IMPORTANT]
> The RISC-V x0 register must always remain zero. Debug writes to x0 should either be rejected or ignored consistently with the architecture.

I also want an advanced capability to modify a general-purpose register while the processor is safely halted. This will allow us to demonstrate debugging and controlled fault injection. Writes must be restricted to supported states and followed by verification that the requested value was applied.

> [!CAUTION]
> The debugger must not write directly into internal register storage in an uncontrolled way that creates conflicting drivers or unpredictable synthesis behavior.

---

## 13. Memory Viewer and Editor

<sub>REQ-13 · [How it will be proven](VERIFICATION_MATRIX.md#cpu-control-and-state-access-req-09req-13)</sub>

The Tab5 should contain a memory inspection interface.

- I want to enter a memory address and read data from the FPGA.
- The screen should display memory in hexadecimal form, preferably with an address column and groups of bytes or 32-bit words.
- Where useful, it should also provide ASCII interpretation.
- I want to navigate memory, move between address ranges, and refresh the display.

The debugger should support modifying memory contents while the processor is safely halted. This includes writing individual bytes, halfwords, and words if the bus and memory architecture support those operations.

Memory access must respect alignment, byte-enable behavior, and valid address ranges.

The interface must clearly distinguish ordinary RAM from memory-mapped peripherals.

> [!WARNING]
> We should avoid accidentally reading or writing peripherals with destructive side effects while performing a simple memory dump.

The protocol and hardware should return meaningful errors for unsupported or invalid accesses. A read operation should return the actual value stored in the FPGA, not a cached Tab5 value unless the UI clearly indicates that it is showing previously captured data. After writing memory, the Tab5 should be able to read it back and verify the operation.

This feature will also provide the foundation for loading programs into FPGA RAM.

---

## 14. Program Loading Directly From the Tab5

<sub>REQ-14 · [How it will be proven](VERIFICATION_MATRIX.md#program-loading-and-console-req-14req-15)</sub>

This is one of the most important requirements for making the project completely standalone.

I want to store multiple compiled RISC-V programs on the Tab5's microSD card. These programs will be compiled on my development computer using the RISC-V GCC toolchain and then copied onto the microSD card. During a career fair, I should be able to select a program directly from the touchscreen without connecting a laptop.

> [!IMPORTANT]
> The Tab5 should transfer the program into the FPGA's instruction/data memory through the debug communication interface. The FPGA should then execute that program on the custom RISC-V CPU. I do not want to rebuild the FPGA bitstream every time I change the C program. The FPGA bitstream contains the processor hardware. The program loader changes the software stored in the processor's RAM. This distinction should be fundamental to the architecture.

For example, I want to have programs such as Fibonacci, a prime-number generator, an ALU demonstration, an array-processing program, a sorting algorithm, and a processor diagnostic test. I should be able to choose between these from the Tab5.

The loading sequence should safely halt or reset the processor, verify the program file, transfer program bytes into the correct RAM addresses, and confirm the contents before execution. Because the original design uses unified RAM for code, data, and stack, we must respect the 64 KB memory capacity and existing linker layout.

We should define a simple program manifest containing information such as program name, target ISA, program size, loading address, entry point, checksum, and optional description. Raw binary files can be used initially if their load address and entry point are defined by the known linker configuration. ELF loading can be considered later if the additional complexity is justified. We should not assume that every arbitrary compiled binary can be loaded without considering its linker script, memory layout, initialization requirements, or instruction-set compatibility.

The loader must reject programs that are too large, use unsupported addresses, or otherwise violate the memory layout.

> [!CAUTION]
> Transfer errors must be detected. The system must not execute a partially transferred or corrupted program.

After loading, the Tab5 should display a successful verification result, the program name, the entry address, and an option to run it. The CPU must begin execution from the correct entry point with the required reset and startup conditions. Instruction fetch must observe the newly loaded program, even if instruction prefetching or buffering is introduced later. The Tab5 should also be able to terminate or restart a running program.

> [!IMPORTANT]
> A strong acceptance test would be to load Program A, execute it, then load Program B and execute it without changing the FPGA configuration. This should work entirely offline.

---

## 15. CPU Software Console on the Tab5

<sub>REQ-15 · [How it will be proven](VERIFICATION_MATRIX.md#program-loading-and-console-req-14req-15)</sub>

I also want to use the Tab5 as the primary terminal for programs running on the FPGA. In the original project, C programs can produce output through a memory-mapped UART peripheral. Initially, this output may be visible through a terminal application on a laptop. For the portable version, I want the text to appear directly on the Tab5 screen. For example, if a C program uses our custom printf function, the resulting characters should be displayed in a terminal window on the Tab5. The output must be genuinely generated by the RISC-V CPU.

The Tab5 should also be able to send input characters back to the FPGA program if the software supports reading input. We must provide a clean communication path for this.

One possibility is to forward the CPU's UART output into a hardware FIFO and expose it through the Tab5 debug-link protocol. Another is to implement a virtual UART channel in the existing bus architecture. The exact design should depend on the RTL already present.

> [!CAUTION]
> The debug packets and software console data must be distinguishable. CPU-generated text must never accidentally be interpreted as a debug command. Likewise, debug packet bytes must never accidentally appear as user program input.

The terminal should support ordinary characters, line breaks, scrolling, and optionally clearing the display.

This feature is necessary because I want to run programs without a laptop. The Tab5 should be the complete user-facing console for the RISC-V computer.

---

## 16. Live Five-Stage Pipeline Visualization

<sub>REQ-16 · [How it will be proven](VERIFICATION_MATRIX.md#observation-and-performance-req-16req-18)</sub>

I want the Tab5 to show what is happening inside the pipelined CPU. This is one of the most visually interesting features for demonstrations.

The interface should contain five clearly labeled pipeline stages: IF, ID, EX, MEM, and WB. For each stage, I want to see meaningful information such as whether the stage is valid, the instruction PC, the instruction mnemonic or encoded instruction, and relevant control or status information.

The screen should show which instructions are currently in flight. It should distinguish normal instructions from pipeline bubbles, stalls, and flushed instructions. For example, when a load-use dependency occurs, the interface should be able to show that the processor inserted a stall. When a taken branch causes younger instructions to be flushed, that behavior should be visible.

> [!IMPORTANT]
> The Tab5 must not invent these events. We should expose the necessary pipeline-valid signals, stage PCs, instruction information, and event indicators through a dedicated observation or snapshot interface.

Because the CPU may operate at tens of megahertz, it is not realistic to transfer every pipeline cycle through an initial low-speed UART link and render every cycle on a touchscreen. Therefore, we should distinguish between live sampled status and detailed captured execution history.

During normal execution, the Tab5 can periodically request coherent pipeline snapshots at a manageable rate. For detailed cycle-by-cycle investigation, we can use a dedicated hardware capture mechanism or a triggered trace buffer. The screen should show when a snapshot was captured and avoid presenting old state as though it were an instantaneous live value.

The implementation should be efficient enough not to interfere with normal processor operation unnecessarily. In Engineering Mode, the user should be able to halt execution, inspect the pipeline state, and examine the instructions around a stall, flush, or breakpoint. This will make the five-stage processor much easier to explain to other people.

---

## 17. Instruction Retirement Trace Buffer

<sub>REQ-17 · [How it will be proven](VERIFICATION_MATRIX.md#observation-and-performance-req-16req-18)</sub>

I want a proper hardware instruction-tracing subsystem inside the FPGA. The CPU should produce a retirement event whenever an instruction completes architecturally. The trace subsystem should capture information associated with retired instructions.

The minimum information should include the instruction PC, the instruction encoding, and a valid retirement indication. Where practical, it should also capture destination register information, destination value, memory operation information, and useful exception or control-flow indicators.

A 256-entry circular instruction trace buffer is a good initial target. The buffer should continuously record recent retired instructions, overwriting the oldest records when full.

When the processor halts or reaches a breakpoint, the Tab5 should be able to retrieve the recent execution history. This will let me see what the processor executed immediately before a failure.

I want the Tab5 to display the trace as a scrollable instruction list. Ideally, the interface should translate supported RV32I instruction encodings into readable assembly mnemonics. For example, I should see instructions such as ADDI, LW, SW, BEQ, JAL, and ADD rather than only raw hexadecimal words. The trace should identify changes to registers when that information is available. It should also identify branch or jump events and other useful execution behavior.

The buffer must be designed so that trace reads do not corrupt ongoing writes. We should define coherent snapshot behavior, freezing behavior, or another safe mechanism for retrieving trace records. The trace system should distinguish retired instructions from fetched or speculatively in-flight instructions that were later flushed.

The initial buffer capacity should be selected based on actual FPGA block RAM usage. If 256 entries are too expensive with the full record format, we should evaluate compression or a smaller initial buffer without compromising correctness. This feature should be verified in simulation against the CPU's expected retirement sequence.

---

## 18. Performance Monitoring and Hardware Counters

<sub>REQ-18 · [How it will be proven](VERIFICATION_MATRIX.md#observation-and-performance-req-16req-18)</sub>

The Tab5 should provide a performance dashboard that displays real measurements from the FPGA. The CPU should expose hardware performance counters. The most important counters are total cycles and instructions retired. From these, the Tab5 can calculate cycles per instruction, or CPI, when the retired-instruction count is nonzero.

For the pipelined processor, I also want counters for stalls, load-use hazards, pipeline flushes, taken branches, and other meaningful events supported by the architecture.

> [!WARNING]
> If the CPU initially uses static predict-not-taken behavior, we should label branch-related measurements accurately. For example, taken-branch flushes can be counted, but we should not claim to have a sophisticated branch predictor or dynamic prediction statistics unless those features exist.

Additional counters can be introduced as the CPU architecture grows. The performance interface should display both cumulative values and values measured over a defined execution interval. For example, I want to start a program, collect the cycle count, record instructions retired, and display CPI.

For longer programs, we should account for counter overflow. We should consider sufficiently wide counters and an atomic or latched snapshot interface so that multiword counter reads are consistent. The clock frequency displayed on the Tab5 must correspond to the configured hardware clock rather than a guessed value.

The dashboard should allow comparison between programs. For example, I could run Fibonacci and then a sorting program and compare their measured instruction counts and cycle counts. If we later benchmark the single-cycle and pipelined processors, we can store those measurements and display a comparison.

However, results must be labeled clearly so that historical measurements are not confused with live hardware readings. I would also like the Tab5 to save benchmark results to the microSD card for later analysis.

---

## 19. Built-In Self-Test System

<sub>REQ-19 · [How it will be proven](VERIFICATION_MATRIX.md#self-test-faults-and-reference-comparison-req-19req-21)</sub>

A major advanced feature is built-in self-test, commonly called BIST. I want the FPGA to contain diagnostic logic that can actively test selected hardware components. The Tab5 should provide a dedicated Diagnostics screen where I can choose which test to run.

**Memory self-test**

The first major test should be a memory BIST. We can implement a memory march-test controller that writes known patterns, reads them back, and verifies the results. The test should cover relevant memory addresses and use patterns capable of detecting common memory faults.

> [!WARNING]
> Because this test may overwrite memory, it must be restricted to a safe state. The Tab5 must warn the user before destructive memory tests. We should define whether a test operates on a reserved scratch region, whether program memory is preserved, or whether the CPU must be reloaded afterward. The memory BIST engine must not silently destroy the running program or stack.

**ALU self-test**

The second major test should be an ALU self-test. This should exercise selected arithmetic and logical operations using known input combinations and expected outputs. We should decide whether this is implemented through a dedicated hardware test path, a diagnostic micro-operation interface, or known-good programs executed by the CPU. If we implement a dedicated hardware BIST path, we must clearly separate that mechanism from ordinary software-based CPU testing.

**Results**

The BIST system should report meaningful results. A result should include the test identity, completion status, number of test cases or locations tested, failure count, and relevant error information. For a memory test, useful diagnostic information would include the failing address, expected value, actual value, and test pattern. For an ALU test, useful information would include the operation, operands, expected result, and observed result.

The Tab5 should show clear PASS, FAIL, and ERROR states. The application should also save test reports when requested. We should verify the BIST controllers using self-checking testbenches and deliberately introduced fault models.

> [!IMPORTANT]
> The goal is to build actual hardware self-test infrastructure, not merely run a software program and call it BIST.

---

## 20. Controlled Fault Injection

<sub>REQ-20 · [How it will be proven](VERIFICATION_MATRIX.md#self-test-faults-and-reference-comparison-req-19req-21)</sub>

I want the system to support deliberate and controlled fault injection for diagnostic testing. This should be one of the advanced features of the project. The purpose is to intentionally introduce a known error and observe whether our diagnostic mechanisms detect it.

For example, the Tab5 could select a location in a scratch memory region and request that a specified bit be flipped. The FPGA would apply the corruption through a controlled hardware mechanism. We could then run a memory test or a CPU program to observe the effects. Eventually, we could also support carefully controlled corruption of selected register values.

We should avoid creating fault-injection behavior that accidentally affects unrelated hardware state. Fault injection must only operate in explicitly supported conditions. The user should be able to select the target, bit position, and test type where applicable.

The system should record the original value, requested modification, resulting value, and whether the diagnostic test detected the fault. I want a clear report showing what was injected and what happened afterward. For example, the report might state that a bit was flipped in a particular memory location, the expected value was different from the observed value, and the memory diagnostic successfully identified the mismatch.

The system should support restoring the original value or resetting the affected test environment after the experiment.

> [!WARNING]
> We must distinguish between transient fault injection, persistent corruption, and ordinary debug writes. A simple software write that changes a memory location should not automatically be presented as equivalent to a hardware-level fault-injection experiment unless we explicitly define it that way.

Later, fault injection can be expanded to investigate how instruction execution behaves under corrupted data. We should not add complicated fault-injection features before the normal CPU and debugging mechanisms are stable.

---

## 21. Automated Diagnostic Comparison Against a Reference Model

<sub>REQ-21 · [How it will be proven](VERIFICATION_MATRIX.md#self-test-faults-and-reference-comparison-req-19req-21)</sub>

I would like to add an advanced feature that makes the system more than a conventional debugger. The Tab5 should eventually help identify incorrect CPU execution by comparing the FPGA processor against a software reference model of RV32I behavior. The purpose is to build a small processor validation and fault-isolation environment.

The reference model can execute supported RV32I instructions and maintain architectural state, including the PC, registers, and relevant memory effects. The FPGA should provide an actual instruction retirement trace that can be compared with this model.

1. During a diagnostic test, both systems should begin from equivalent initial conditions.
2. The reference model can then calculate expected architectural behavior.
3. The diagnostic application compares the expected results against the FPGA's observed retirement events.

If a mismatch occurs, I want the Tab5 to identify the earliest observable divergence. For example, it could show the instruction PC, decoded instruction, expected destination register value, actual destination register value, and surrounding instruction history. This should be based on actual comparison logic rather than heuristic guesses.

> [!WARNING]
> If the comparison only identifies an architectural mismatch, the system should report that clearly. It should not automatically claim that a particular RTL component is defective without supporting evidence.

The comparison must account for memory-mapped I/O, program inputs, supported instructions, and deterministic initial conditions. We should begin with a restricted set of deterministic test programs and expand coverage over time.

The comparison can run on the Tab5's ESP32-P4, provided performance and memory resources are sufficient. Alternatively, the reference-model computation can be performed during test preparation and its expected results stored on the microSD card. For the portable final system, I want the comparison to work offline.

This feature is especially important because it demonstrates a connection between processor verification and post-silicon diagnostics. It allows the project to show not only that a processor can run programs, but also that we can systematically detect and investigate incorrect processor behavior.

---

## 22. User Interface Screens

<sub>REQ-22 · [How it will be proven](VERIFICATION_MATRIX.md#screens-demo-flow-and-firmware-req-22req-24)</sub>

I want a complete, polished touchscreen application rather than a single page of text.

- The Home screen should introduce the RISC-V computer, display the connection state, identify the CPU, and provide direct access to the most important operations.
- The Program Launcher should list available programs stored on the Tab5, display their descriptions, and provide buttons to load, run, stop, and restart them.
- The Terminal screen should display output generated by the CPU and optionally allow sending input to the program.
- The CPU Control screen should show the processor state, PC, current instruction, HALT, STEP, RESUME, RESET, and breakpoint controls.
- The Registers screen should show all architectural registers and make it easy to inspect changes.
- The Memory screen should allow address-based inspection and controlled modification.
- The Pipeline screen should show IF, ID, EX, MEM, and WB information.
- The Trace screen should display recent retired instructions and support scrolling through execution history.
- The Performance screen should show hardware counters, CPI, execution metrics, and benchmark comparisons.
- The Diagnostics screen should provide access to memory BIST, ALU testing, and diagnostic reports.
- The Fault Injection screen should support controlled experiments with clear warnings.
- The System screen should provide connection details, firmware version, FPGA protocol version, supported capabilities, battery or power status where available, and communication diagnostics.
- The Presentation or About screen should contain a short explanation of the project, a simplified architecture overview, and information about the hardware and software that I designed.

I would also like the ability to show project information even when the FPGA is temporarily disconnected. However, such offline information must be clearly separated from live processor status.

The interface should use a consistent theme and remain usable by both me and someone seeing the project for the first time. For advanced pages, technical accuracy is more important than unnecessary visual decoration.

---

## 23. Career-Fair Demonstration Mode

<sub>REQ-23 · [How it will be proven](VERIFICATION_MATRIX.md#screens-demo-flow-and-firmware-req-22req-24)</sub>

This project is intended to become my primary career-fair demonstration. I want a special presentation workflow that can demonstrate its most important capabilities quickly. A recruiter should be able to see that I have built a real processor rather than a touchscreen application that merely imitates a CPU.

1. The main demonstration should begin with the Tab5 showing the FPGA connection and processor information.
2. I should then be able to select a precompiled C program, load it into FPGA memory, and execute it.
3. The Tab5 should display the program's actual output.
4. Next, I should be able to show the processor's PC, registers, and execution counters.
5. Then I should press HALT, inspect the current processor state, and single-step an instruction.
6. If possible, I would also demonstrate a hardware breakpoint.
7. After that, I could show the retirement trace and explain how the hardware captured the recent instruction history.
8. For someone who wants a deeper technical demonstration, I could open the diagnostics screen, run a memory self-test, and show the result.
9. An additional advanced demonstration could intentionally inject a fault and show that our diagnostic system detects it.

> [!IMPORTANT]
> The most important thing is that the system must be reliable. I would rather have a fully working demonstration containing program loading, execution, CPU control, and trace capture than a larger collection of features that frequently fail.

However, I do want all the advanced features included in the long-term architecture so they can be implemented incrementally.

I also want a built-in explanation screen with concise information about the processor architecture, pipeline design, RTL implementation, verification approach, bus interface, and diagnostic hardware. This should help me explain the project without opening a laptop or searching through documentation.

The final system should have a repeatable short demonstration sequence and a deeper technical demonstration sequence. Both should be tested from a fresh power-on state.

---

## 24. Firmware Architecture on the Tab5

<sub>REQ-24 · [How it will be proven](VERIFICATION_MATRIX.md#screens-demo-flow-and-firmware-req-22req-24)</sub>

The Tab5 firmware should be modular and maintainable. I do not want one enormous source file containing the display logic, UART protocol, file handling, debugging commands, and application state. We should separate the application into logical components.

- The communication layer should manage the physical UART interface, packet framing, checksums, timeouts, and connection recovery.
- The protocol layer should translate high-level operations into request and response packets.
- The device-control layer should provide operations such as reading registers, writing memory, loading programs, controlling execution, retrieving trace records, and starting diagnostic tests.
- The storage layer should manage microSD files, program manifests, saved reports, and demonstration configuration.
- The application-state layer should track connection status, current program, processor state, recent measurements, and ongoing operations.
- The user-interface layer should render screens and process touch input.
- The diagnostics layer should manage self-test results, fault-injection experiments, and optional reference-model comparison.

The firmware should remain responsive during communication and large transfers. Use an event-driven or asynchronous design where appropriate. We should not block the entire user interface while waiting for the FPGA. The application must handle temporary disconnections and incomplete responses gracefully.

For development, we may begin with Arduino and the M5Unified/M5GFX libraries to verify the display, touch, microSD, and UART hardware. For the larger final application, ESP-IDF with LVGL is an option worth evaluating, especially if it provides a better long-term architecture.

Do not select the software framework merely because it is fashionable. Evaluate the available Tab5 board support, display-driver compatibility, library maintenance, debugging tools, and ease of integration.

The Tab5 has had different display and touch controller revisions. Verify the hardware revision and use compatible current display libraries or board-support packages.

I want the firmware to be reproducible and documented. The build instructions should explain how to compile, flash, and recover the firmware.

---

## 25. FPGA RTL Architecture for the Diagnostics System

<sub>REQ-25 · [How it will be proven](VERIFICATION_MATRIX.md#engineering-process-and-physical-design-req-25req-28)</sub>

On the FPGA side, I want the new diagnostic features organized into separate SystemVerilog modules. The likely major components include a UART debug transport, packet receiver and transmitter, command decoder, debug bus master, bus-access arbitration, CPU debug control module, breakpoint controller, architectural register-access interface, trace buffer, performance counters, memory BIST engine, ALU test engine, and fault-injection controller.

These are logical components, not necessarily mandatory individual file names. The final module boundaries should be determined after inspecting the existing RTL. We should reuse existing modules where appropriate.

Every new hardware block must have a clearly defined interface. Control signals should be explicit and easy to verify. Avoid hidden dependencies between the UART engine, CPU pipeline, and diagnostic engines. The design must account for clock domains and reset behavior.

If the Tab5-facing UART runs asynchronously relative to the FPGA clock, its incoming signal requires appropriate synchronization and UART sampling logic. If future features introduce genuinely separate clock domains, use proper clock-domain crossing mechanisms. Do not introduce uncontrolled generated clocks or asynchronous combinational paths. The debug interface must not introduce latches, multiple drivers, or unsupported synthesis constructs.

The RTL must remain compatible with our Verilator-based verification environment and Vivado FPGA build flow. The original project rules regarding naming, module structure, self-checking testbenches, and reproducible builds should continue to apply.

We should also measure the FPGA resource cost of the debug infrastructure. The complete design must fit on the Basys 3 and meet timing. If a feature consumes too much block RAM or logic, evaluate a smaller initial implementation or a more resource-efficient architecture.

> [!IMPORTANT]
> Do not sacrifice processor correctness or timing merely to add a visually attractive debugging feature.

---

## 26. Verification and Testing Requirements

<sub>REQ-26 · [How it will be proven](VERIFICATION_MATRIX.md#engineering-process-and-physical-design-req-25req-28)</sub>

I want the Tab5 integration developed with the same verification discipline as the rest of the CPU project. Every important RTL component should have a self-checking testbench.

The communication protocol must be tested independently before connecting the physical Tab5. We should be able to simulate commands from a host testbench and verify the FPGA's responses. Test ordinary requests, invalid commands, invalid addresses, malformed packets, corrupted checksums, unexpected resets, timeouts, and interrupted transfers.

- The bus bridge must be tested for correct address, data, byte-enable, acknowledgment, and error handling.
- The CPU debug module must be tested for safe halt and resume.
- The single-step feature must be verified against architectural retirement behavior.
- Breakpoint tests should cover normal execution, branches, jumps, repeated breakpoints, and resuming from a breakpoint.
- Register-access tests should verify all general-purpose registers and enforce x0 behavior.
- Memory tests should cover byte, halfword, and word accesses where supported.
- Program-loading tests should verify complete transfers, corruption detection, memory bounds, entry-point behavior, and execution of newly loaded software.
- Trace tests should verify instruction ordering, circular-buffer wraparound, valid retirement records, and correct exclusion of flushed instructions.
- Performance-counter tests should verify event counts and snapshot consistency.
- BIST tests should verify that injected errors are actually detected.
- Fault-injection tests should verify that only the intended state changes.

> [!IMPORTANT]
> The original CPU regression suite must continue passing after every significant integration step. We must also verify that the debugger does not unintentionally alter processor behavior when it is inactive. A particularly important test is to run the same program with the debug infrastructure disabled or idle and verify that the architectural results remain unchanged.

The hardware tests should be supported by actual board-level verification. This should include checking UART communication, memory access, program loading, CPU control, trace retrieval, power cycling, and full standalone operation.

> [!IMPORTANT]
> Do not declare a feature complete merely because its user-interface button works. A feature is complete only when the underlying FPGA operation has been verified.

---

## 27. Power, Reliability, and Physical Design

<sub>REQ-27 · [How it will be proven](VERIFICATION_MATRIX.md#engineering-process-and-physical-design-req-25req-28)</sub>

The final system must be robust enough for repeated transportation and demonstrations. I want the Tab5 and Basys 3 connected securely. We should eventually use a properly designed cable or small adapter board rather than fragile loose jumper wires.

- The enclosure should provide access to power controls, the Tab5 screen, necessary FPGA indicators, and development connectors.
- The mounting design should avoid short circuits, exposed conductive hardware, and mechanical strain on connectors.
- The FPGA board must have adequate ventilation.

The power source must provide sufficient current to both devices under the actual application load. We should measure or estimate realistic operating power and verify it through testing.

> [!WARNING]
> If the Tab5 has a compatible battery installed, its battery can power the Tab5, but that does not automatically mean it can power the FPGA safely. We should verify the power path before considering a shared battery arrangement.

The system should include a sensible response to low battery or power interruption. The application should avoid beginning destructive memory tests or firmware operations under unstable conditions where practical. The final device should also have a clean shutdown or reset procedure.

I want a documented cold-start test and a demonstrated operating-runtime measurement. Reliability matters more than maximizing battery life at the expense of correct behavior.

---

## 28. Development Order and Integration Strategy

<sub>REQ-28 · [How it will be proven](VERIFICATION_MATRIX.md#engineering-process-and-physical-design-req-25req-28)</sub>

I want this functionality added incrementally, not as one enormous change. The existing CPU project must continue to follow its phase-gated development approach. We should not abandon the original processor milestones to work exclusively on the touchscreen. However, some Tab5 development can happen in parallel because it does not require a finished CPU.

1. The first integration milestone should be to verify the actual Tab5 hardware, its display, touch input, microSD storage, and a basic UART communication interface.
2. The second milestone should be to build a simulated CPU dashboard on the Tab5. This dashboard can use clearly labeled mock data during early development. Its purpose is to establish the user-interface framework before the real debug hardware exists.
3. The third milestone should be to develop and verify the communication protocol between a host and the FPGA. At this stage, we only need basic operations such as communication handshake, status retrieval, and simple read/write commands.
4. The fourth milestone should establish a working debug bus access path. The Tab5 should be able to read and write a safe test register or RAM location and verify the result.
5. The fifth milestone should make the system capable of loading and running software programs directly from the Tab5. This should include a program launcher and CPU output displayed through the Tab5 terminal. At this point, we should have the first major standalone demonstration.
6. The sixth milestone should implement safe CPU halt, resume, and architectural register inspection.
7. The seventh should implement single-stepping and hardware breakpoints.
8. The eighth should introduce pipeline snapshots and instruction trace capture.
9. The ninth should integrate performance counters and benchmark displays.
10. The tenth should implement memory BIST and other hardware self-tests.
11. The eleventh should introduce controlled fault injection.
12. The twelfth should implement automated architectural-result comparison and advanced diagnostic reporting.
13. The final milestones should involve presentation-mode polish, physical mounting, portable power, documentation, and complete cold-boot testing.

This is a proposed dependency sequence, not a demand to implement these features immediately in this exact order. You should adjust the order based on the actual codebase.

For example, if the UART already exists and works, use it rather than recreating it. If the pipeline is not yet finished, we can develop communication and interface components in parallel, but pipeline-specific debugging must wait until we have reliable retirement and pipeline-control signals.

If an intermediate feature exposes a fundamental issue in the CPU architecture, fix and verify that issue before moving on. The final roadmap must show the relationship between the original CPU development milestones and the new Tab5 milestones.

---

## 29. First Complete Standalone Demonstration

<sub>REQ-29 · [How it will be proven](VERIFICATION_MATRIX.md#demonstrations-req-29req-30)</sub>

Before we implement every advanced feature, I want a clearly defined first successful portable demonstration.

1. The system should be powered without a laptop.
2. The FPGA should load its configured bitstream automatically.
3. The Tab5 should launch its application and connect to the FPGA.
4. The Tab5 should identify the processor or hardware interface.
5. I should be able to select a compiled RISC-V program stored on the microSD card.
6. The program should load into FPGA RAM successfully.
7. I should be able to press RUN.
8. The program should execute on the actual RISC-V processor.
9. The Tab5 should show genuine output generated by that program.
10. I should be able to see meaningful execution information such as the current program, execution state, cycle count, and instructions retired.
11. If the implementation stage supports it, I should also be able to halt execution and inspect registers.

> [!IMPORTANT]
> The complete demonstration should work from power-on without using a computer. This is the first major system-level acceptance gate.

Advanced diagnostics should be built on top of this proven foundation.

---

## 30. Final Complete Demonstration

<sub>REQ-30 · [How it will be proven](VERIFICATION_MATRIX.md#demonstrations-req-29req-30)</sub>

The final version should support a much more sophisticated demonstration.

- I want to turn the system on and have both devices initialize automatically.
- I want the Tab5 to show the real hardware connection and processor information.
- I want to select and load a program from the microSD card.
- I want to execute the program and view its actual output.
- I want to see the CPU's performance counters and pipeline information.
- I want to set a hardware breakpoint and let the processor run until it stops.
- I want to inspect the program counter and architectural register values.
- I want to single-step through instructions and observe which registers change.
- I want to view the hardware instruction trace captured during execution.
- I want to run a memory diagnostic and receive a real pass/fail result.
- I want to inject a controlled fault and demonstrate that the diagnostic system can detect the incorrect state.
- I want to open a diagnostic report that clearly identifies the expected and observed behavior.
- Ideally, I also want to use a software reference model to demonstrate how the first incorrect architectural result can be identified.

All of these operations should be controlled through the Tab5. The laptop should not be involved. The FPGA should genuinely execute the code and provide the hardware observations. The Tab5 should serve as the portable interface for operating and analyzing the system.

---

## 31. Documentation and Portfolio Requirements

<sub>REQ-31 · [How it will be proven](VERIFICATION_MATRIX.md#documentation-extensions-constraints-and-vision-req-31req-35)</sub>

This project is intended to be one of my strongest portfolio projects for semiconductor engineering roles. Therefore, the integration must be documented professionally.

- I want an architecture document explaining the overall system, the roles of the FPGA and Tab5, the communication protocol, the debug access architecture, and the processor control mechanism.
- I want the documentation to distinguish between the processor core, bus interconnect, debug infrastructure, trace system, and diagnostic engines.
- We should maintain a clear memory map and command protocol specification.
- I want verification documentation showing which modules have been tested, how the tests work, and which requirements they prove.
- I also want synthesis and implementation reports describing FPGA resource utilization and achievable clock frequency.
- For performance monitoring, I want measured results rather than estimated or invented benchmark values.
- For diagnostic features, I want actual test results that can be reproduced.
- The repository should contain build instructions for both the FPGA design and the Tab5 firmware.
- It should also explain how to compile and prepare RISC-V programs for loading through the touchscreen.
- The final README should clearly explain what the project does and how someone can reproduce the demonstration.
- I would like a concise architecture explanation suitable for a career fair, along with more technical documentation for engineers who want to inspect the design.
- The system should eventually support a short demonstration video showing the portable setup booting, loading software, controlling the CPU, and running diagnostic tests.

> [!IMPORTANT]
> Any résumé claims must correspond to completed and verified functionality. We should not describe planned features as finished achievements.

---

## 32. Additional Features That Could Be Added Later

<sub>REQ-32 · [How it will be proven](VERIFICATION_MATRIX.md#documentation-extensions-constraints-and-vision-req-31req-35)</sub>

Once the fundamental system works, there are several optional enhancements worth considering.

- We could upgrade the physical communication interface from UART to SPI for faster data transfers. The high-level command protocol should be sufficiently transport-independent that this upgrade does not require redesigning the entire diagnostics architecture.
- We could add more hardware breakpoints and data watchpoints.
- We could implement triggered instruction tracing so that the FPGA captures execution history around a particular event.
- We could expand the performance-monitoring subsystem with additional event counters.
- We could add a more complete software reference model and improved mismatch reporting.
- We could allow the Tab5 to export diagnostic reports and benchmark data to the microSD card.
- We could build an interactive assembly disassembly and source-correlated debugging interface, provided suitable symbol and debug information is available.
- We could add an FPGA-controlled demonstration of external hardware peripherals.
- We could also explore using the Tab5 as an I/O coprocessor or specialized accelerator in a future version.

However, those additional roles should not compromise the primary debug-and-diagnostics architecture. I do not want to add unrelated complexity simply to increase the number of features. Every optional feature should strengthen the core project or demonstrate a meaningful engineering capability.

> [!IMPORTANT]
> The primary objective remains a reliable, portable processor bring-up and diagnostics platform.

---

## 33. Technical Constraints and Important Design Decisions

<sub>REQ-33 · [How it will be proven](VERIFICATION_MATRIX.md#documentation-extensions-constraints-and-vision-req-31req-35)</sub>

- Do not replace the custom FPGA CPU with the ESP32-P4's built-in processor.
- Do not simulate the FPGA's CPU execution on the Tab5 and present it as hardware execution.
- Do not treat the Tab5 as merely an HDMI-like monitor or framebuffer display.
- Do not replace genuine hardware debugging with a purely software-generated animation.
- Do not assume that UART communication alone automatically provides access to internal CPU registers.
- Do not assume that a Wishbone bridge automatically solves pipeline halt, register access, or instruction retirement.
- Do not assume that the existing dual-port RAM has an available third access port.
- Do not use unsafe clock gating to implement CPU halt or single-step.
- Do not implement single-stepping as simply enabling the CPU for one clock cycle.
- Do not allow debugger memory writes to race with uncontrolled CPU accesses.
- Do not call an ordinary software memory test a dedicated hardware BIST engine without explaining the distinction.
- Do not present fabricated performance measurements, instruction traces, or diagnostic results as real hardware data.
- Do not make the system depend on Wi-Fi, Bluetooth, cloud connectivity, or a laptop for its normal standalone demonstration.
- Do not remove existing CPU features merely because the Tab5 becomes the primary display.
- Do not unnecessarily replace working modules or invalidate existing tests.
- Do not introduce an enormous set of unverified RTL changes in a single step.
- Do not claim that the entire design is complete until the actual hardware acceptance tests have passed.

> [!IMPORTANT]
> The final system should prioritize correctness, testability, maintainability, and demonstrable engineering value.

---

## 34. What I Want You to Do With My Existing Codebase

<sub>REQ-34 · [How it will be proven](VERIFICATION_MATRIX.md#documentation-extensions-constraints-and-vision-req-31req-35)</sub>

You have already examined my project files and should understand the current repository. Use that context to determine how to integrate this feature.

**Inspect the current implementation**

- First, identify the exact current implementation status of the CPU, RAM, buses, UART, FPGA top-level module, clocking, reset system, and test infrastructure.
- Next, identify which existing modules can be reused for the Tab5 integration.
- Determine what new interfaces are required inside the processor and memory subsystem.
- Pay particular attention to architectural retirement signals, safe CPU halt behavior, debug register access, and memory arbitration.

**Propose the FPGA debug architecture**

- Then propose a clean FPGA debug architecture that fits the actual codebase.
- The architecture should explain how commands travel from the Tab5 through UART to the appropriate FPGA subsystem.
- It should also explain how processor status, memory contents, trace records, and diagnostic results return to the Tab5.
- Define the relationship between the existing CPU software UART and the dedicated debug communication path.
- Determine whether Wishbone should be introduced as a new debug interconnect, adapted to the existing bus, or integrated more broadly.
- Choose the approach with the best balance of correctness, technical value, and minimum unnecessary disruption.

**Define the firmware and system behavior**

- Define the firmware architecture for the Tab5.
- Select a suitable development framework after considering current hardware support and compatibility.
- Define how program files are stored, loaded, validated, and launched.
- Define how the two devices initialize and recover from communication failures.
- Explain which hardware resources are required and identify major FPGA utilization or timing risks.

**Update the roadmap**

- Then update our existing project roadmap to include this integration.
- Do not simply append a vague final phase called "Add Tab5."
- I want the feature broken into concrete, testable engineering milestones.
- Each milestone should identify the components involved, the intended behavior, how it will be verified, and what must pass before we proceed.
- Preserve the original CPU development gates.

**Choose the next task**

Finally, identify the smallest safe next implementation task based on what is already working. We should implement and verify that task before making larger changes.

> [!IMPORTANT]
> If the available codebase does not establish an important detail, mark it as unresolved rather than inventing it.

---

## 35. Final Vision

<sub>REQ-35 · [How it will be proven](VERIFICATION_MATRIX.md#documentation-extensions-constraints-and-vision-req-31req-35)</sub>

The project I want to build is a complete RISC-V computer with an integrated portable silicon debug and diagnostics platform.

The Basys 3 will contain the processor hardware that I personally designed, implemented, and verified in SystemVerilog. The M5Stack Tab5 will provide a self-contained interface for interacting with that hardware. Together, they should function as one complete embedded computing and diagnostic system.

I want to be able to carry the finished device into a career fair, turn it on, and demonstrate my RISC-V processor running real programs without opening a laptop.

- I want to explain the five-stage pipeline and show genuine internal processor activity.
- I want to demonstrate hardware halt, resume, single-step, and breakpoints.
- I want to inspect registers and memory.
- I want to load new programs directly from the touchscreen.
- I want to capture and analyze instruction traces.
- I want to measure execution performance.
- I want to run built-in self-tests and investigate controlled faults.
- Most importantly, I want to be able to explain how every major capability is implemented in hardware, how it was verified, and why the architecture works.

I want the finished project to demonstrate processor design, digital logic, SystemVerilog RTL, FPGA implementation, bus protocols, embedded firmware, hardware-software integration, processor validation, performance analysis, debugging infrastructure, and silicon diagnostics.

This should not be a collection of disconnected features. It should be one coherent, carefully engineered system with a clear architecture, reproducible tests, measured results, useful documentation, and a professional standalone demonstration.

The M5Stack Tab5 should become an essential part of the project, not an accessory added after everything else is finished. The primary career-fair story should be that I built both the RISC-V processor and the portable hardware infrastructure used to program, control, observe, test, and diagnose it. My ultimate goal is to produce a system that is technically impressive because it works, is deeply understood, can be demonstrated reliably, and is backed by genuine engineering evidence.

Please use this description, together with your existing understanding of my codebase, as the specification for the additional M5Stack Tab5 integration. Treat everything described here as intended functionality unless the actual code confirms it is already implemented. Preserve the existing project, extend it carefully, and organize the development so that every major new feature is independently verified before the next one is added.

---

**Related:** [Verification matrix](VERIFICATION_MATRIX.md) · [Build plan, Tab5 milestones](../BUILD_PLAN.md#10-tab5-milestones-portable-control-and-diagnostics) · [Integration architecture](TAB5_INTEGRATION.md) · [Debug protocol](DEBUG_PROTOCOL.md) · [Tab5 firmware](TAB5_FIRMWARE.md) · [Hardware checklist](HARDWARE_CHECKLIST.md) · [Docs index](../README.md)
