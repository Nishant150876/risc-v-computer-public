[Project README](../../README.md) › [Docs index](../README.md) › **Phase 7 demos**

# Phase 7: Demos and polish

Three freestanding C programs show the computer working: a prime sieve over the USB
console, Conway's Game of Life on the VGA framebuffer, and a playable Snake game on the
board buttons. This page records what was built, how to run it, the evidence collected
so far and the acceptance that remains.

> [!NOTE]
> **Status (November 8, 2026): 🚧 4 / 6 tasks implemented and verified in simulation and
> routed timing; the gate is not passed.** All three demos pass full-board simulation on
> both CPUs, and six Vivado builds meet timing with zero DRC violations. Nothing has been
> programmed onto the board or observed on a monitor for this phase. The demos need no new
> hardware, so they were built ahead of the pending Phase 6 monitor gate. The board owner
> has a Tab5 but no VGA monitor yet.

<details>
<summary><b>On this page</b></summary>

1. [What changed](#1-what-changed)
2. [Controls and rendering](#2-controls-and-rendering)
3. [Build and simulate](#3-build-and-simulate)
4. [FPGA builds and later board execution](#4-fpga-builds-and-later-board-execution)
5. [Previews and presentation material](#5-previews-and-presentation-material)
6. [Acceptance that remains](#6-acceptance-that-remains)

</details>

## 1. What changed

| Component | Implementation |
| --- | --- |
| [Prime sieve](../../sw/programs/primes/README.md) | Bit-packed sieve through 10,000; all 1,229 primes, count and measured cycles/instructions/CPI on the existing console UART |
| [Life](../../sw/programs/life/README.md) | Two 160 x 120 bit grids, B3/S23 with dead finite edges, word-parallel neighbor counting, four starting patterns, timed/manual steps |
| [Snake](../../sw/programs/snake/README.md) | 40 x 26 playfield, ring/occupancy state, bounded food search, button controls, score, pause, game-over/win and restart |
| Shared C helpers | Direction-button edges, explicit-state xorshift32, BCD display conversion, clipped packed-word rectangles and a pixel-font HUD |
| Font conversion | Generates both the existing hardware ROM and a reproducible C 8 x 8 header from the same pinned public-domain source |
| Software builder | Compiles program-local C translation units alongside main and the shared runtime; unchanged RV32I/ILP32 flags, linker bounds and image checks |
| Verification | Six full-board demo profiles, native sanitized engine/library checks, exact UART capture checker and optional simulation evidence export |
| Presentation material | [Architecture sheet](../ARCHITECTURE.md), simulated frame previews, rebuild instructions and a factual technical bug note below |

No RTL, pin, clock, reset, CPU ISA or MMIO interface changed. The single-cycle CPU is
still the default. Tab5 firmware, loader/debug/diagnostic RTL, flash programming and
the optional ROM bootloader remain separate work.

## 2. Controls and rendering

Life: SW0 glider, SW1 Gosper gun, SW2 R-pentomino, SW3 random. The lowest enabled pattern
switch wins; none means glider. BTNU restarts and applies the selection. SW15 enables
manual mode, where each new BTNR press advances one generation. Otherwise it targets
four steps per second using the configured CPU frequency. HEX shows generation modulo
10,000 in BCD; LED bit 15 records a redraw that finished outside blank.

Snake: U/L/R/D turn, SW0 pauses, SW1 slows from eight to four ticks/s. BTNU restarts after
game over or a win. SW12 selects a reproducible training seed at restart, placing first
food directly ahead. SW15 selects manual mode; a SW14 rising edge advances one tick.
One direction can be queued per tick, reversals are rejected, and held inputs do not
repeat. The score appears in the pixel HUD and BCD hex register. LED bits are documented
in the program README. Simultaneous direction presses use U/L/R/D priority.

**BTNC remains CPU reset in every program.** There is no new button-reset contract.

The VGA block selects text OR pixels, so Snake draws its HUD into pixels using the
public-domain 8 x 8 glyphs. Its two HUD rows leave 26 playfield rows. Life's two state
grids occupy 4,800 bytes, separate from the 9,600-byte framebuffer. A lookup table
expands each eight-cell group into a packed 32-bit framebuffer word.

Initial drawing/restarts select BLACK and reveal the completed image at a frame boundary.
Ordinary drawing waits for a fresh displayed-vblank edge. Life writes 2,400 full words;
Snake redraws only changed squares and the HUD. Both keep a sticky overrun diagnostic.
The display is single buffered; blank is 1.44 ms, and a status observation reserves
nothing. Compiler/clock/render changes require this budget to be checked again.

## 3. Build and simulate

From the repository root in **WSL: Ubuntu**:

```bash
python3 scripts/font2mem.py --check --c-header sw/common/vga_font8x8.inc
python3 scripts/build_software.py primes
python3 scripts/build_software.py life
python3 scripts/build_software.py snake
python3 scripts/run_tests.py primes
python3 scripts/run_tests.py life
python3 scripts/run_tests.py snake
python3 -m unittest discover -s scripts/tests -v
```

The custom benches use the actual board top, MMCM functional model, bus, RAM,
peripherals and compiled C. Single-cycle profiles run at 25 MHz; pipeline profiles
run at 62.5 MHz. Software delay constants and UART bit divisors follow the CPU clock;
VGA pixels stay at 25 MHz. Images must not be reused at another CPU clock.

To save actual simulated output while running tests:

```bash
python3 scripts/run_tests.py --evidence-dir build/phase7/simulation
python3 scripts/vga_preview.py build/phase7/simulation/snake_tb/snake/snake-game-over.ppm build/phase7/snake-game-over.png
python3 scripts/primes_check.py --capture-file build/phase7/simulation/primes_tb/primes/uart.bin
```

Evidence is separated by bench/program. Each run starts with a false/incomplete result
record and changes to PASS only after the bench succeeds. A PPM or UART file by itself
does not mean a test passed. Captures are simulation, never physical-monitor evidence.

### Validation coverage

| Check | Oracle / failure conditions |
| --- | --- |
| Sieve native C | Independent trial division at every n from 0 through 10,000 |
| Sieve board | All 6,000+ TX-pin bytes against the fixed fixture; separate parse, arithmetic and exact zero-padded format checks for measured CPI, normal EBREAK, LED/HEX signature |
| Life native C | Naive cell-by-cell model for every pattern over 32 generations, glider displacement, word boundaries, all four finite edges, eight-neighbor case, deterministic seeds |
| Life board | Real quarter-second timer, four glider steps, held-button nonrepeat, restart/selection, canonical RLE gun, R-pentomino; four full 307,200-pixel pin comparisons per CPU; every 2,400-store redraw spans less than the 1.44 ms blank |
| Snake native C | RNG, edge helpers, growth, direction/reversal guard, walls, self collision, legal departing-tail entry, 5,000 ticks of ring wrapping, full-board win |
| Snake board | Real 125 ms timer, first food/growth/score, two queued presses, reversal rejection, pause, wall death, frozen terminal state, restart; six full frames per CPU |
| VGA C library | ASan/UBSan; all 256 bit expansions, clipped/extreme rectangles, neighboring pixels, every printable pixel glyph, invalid coordinates/colors and existing console behavior |
| Host checker | Independent prime generation, bounded capture, exact output/CPI, corruption/truncation/extra data and stale-PASS rejection; no physical COM-port check performed |

The Snake oracle uses a simple deque of linear cells, distinct from the C ring and
packed coordinates. Its bounded food oracle avoids a Verilator 5.020 compiler issue:
an early-return foreach function used as a while condition generated a hoisted increment
and stalled at time zero. Explicit loop updates and a bounded search fix the bench.
This was a testbench/tool issue; the freestanding engine passed the independent native tests.

### Recorded results

- Focused full-board programs: **6/6 passed** (three demos, two CPUs).
- Complete Python/native suite: **80/80 passed**, including ASan/UBSan.
- Complete regression: **277/277 passed** (32 unit cases and 245 program runs across
  48 elaborated benches).
- Separate `--lint-only --timing --assert -Wall`: **48/48 clean**.
- Six FPGA builds: **6/6 timing/DRC passed**, single 25 MHz and pipe 62.5 MHz for
  primes, Life and Snake. No physical programming was performed.
- Clean-source self-check: all **6/6 RV32I images** rebuilt from a 296-file source-only
  export with no Git metadata or copied generated outputs; every image hash matches
  its previously tested/built counterpart. Font reproduction also passed. This checks
  the C build flow, not an independent human or full FPGA/ISA rebuild.
- Both saved TX-pin captures pass the Windows host checker offline, with warnings
  treated as errors. Ten PNG previews come from passing complete-frame comparisons.

The checked-in [verification summary](../reports/phase7/verification.json),
[clean-source record](../reports/phase7/source-rebuild.json) and
[FPGA reports](../reports/phase7/README.md) preserve the results. Raw full logs,
PPMs, UART bytes and compiled outputs remain under ignored `build/phase7/` and
the WSL test cache. Hosted CI for these local changes is unrun.

| Life CPU | First-to-last store span | Time | Available blank |
| --- | ---: | ---: | ---: |
| Single, 25 MHz | 22,783 cycles | 0.911 ms | 36,000 cycles / 1.44 ms |
| Pipe, 62.5 MHz | 27,581 cycles | 0.441 ms | 90,000 cycles / 1.44 ms |

These spans cover the framebuffer stores; the independent end-of-redraw status check
also passes with no sticky overrun on either game. They do not certify other clocks or
future compiler/render changes.

| Program | Loaded image | BSS (includes alignment) | End of BSS |
| --- | ---: | ---: | --- |
| primes | 4,512 bytes | 1,252 bytes | `0x1684` |
| life | 3,028 bytes | 5,844 bytes | `0x22A8` |
| snake | 5,536 bytes | 3,168 bytes | `0x2200` |

The sizes match at the two configured clocks; bytes containing timing constants can
differ. All programs remain well below the linker-enforced `0xD000` program/heap
boundary, leaving diagnostic scratch and the 8 KiB stack reserved.

Prime performance includes the MMIO read overhead around initialization/sieving/counting;
it excludes all UART formatting and transmission. Reads are separate, not atomic, so
the observed retired-instruction counts can differ slightly between implementations.

| CPU | Configured clock | Sieve cycles | Instructions | CPI | Interval |
| --- | ---: | ---: | ---: | ---: | ---: |
| Single-cycle | 25 MHz | 258,432 | 258,429 | 1.000 | 10.337 ms |
| Pipeline | 62.5 MHz | 315,458 | 258,430 | 1.221 | 5.047 ms |

This workload is about **2.05x faster** on the pipeline at its tested clock. These are
simulation measurements and two configured clocks, not a fresh Fmax sweep or physical
counter observation. UART transfer time dominates the full prime demonstration and
does not belong in the sieve interval.

## 4. FPGA builds and later board execution

The reviewed build directories are under ignored `build/phase7/vivado-<program>-<profile>/`.
The existing fifth Tcl argument isolates each output from older bitstreams. For example,
in **Windows PowerShell with Vivado on PATH**:

```powershell
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc life pipe 62.5 build/phase7/vivado-life-pipe62p5
```

Use primes, life or snake; profiles are single 25 and pipe 62.5. Each build independently
compiles its software, infers BRAM, routes, checks timing/DRC/clocks and emits a bitstream.
Reviewed timing/utilization/DRC/clock/check-timing reports belong in
`docs/reports/phase7/`. No new frequency sweep or power measurement is claimed.

| CPU (all three demo images) | WNS / WHS | LUT / FF | RAMB36 / DSP |
| --- | --- | --- | --- |
| single 25 MHz | +0.396 / +0.074 ns | 1,682 / 570 | 22 / 0 |
| pipe 62.5 MHz | +0.313 / +0.024 ns | 1,585 / 940 | 22 / 0 |

All six builds have zero DRC violations and zero unconstrained internal endpoints.
Bitstream hashes and source fingerprints are in the reviewed report folder.

**Programming selects a different path:** the unchanged `program.tcl` always uses
`build/vivado/basys3_soc.bit`. It does not automatically select an isolated Phase 7 build.
In a later authorized hardware session, select the exact isolated bitstream in Vivado
Hardware Manager, or rebuild the intended demo into the default location before using
the programmer:

```powershell
vivado -mode batch -nojournal -nolog -source scripts/vivado/build.tcl -tclargs basys3_soc snake pipe 62.5
vivado -mode batch -nojournal -nolog -source scripts/vivado/program.tcl
```

Life/Snake require a real VGA display path; Tab5 currently has no framebuffer mirroring
or game-control firmware. For primes, close other serial terminals, start
`python scripts/primes_check.py --port COM8` (substitute the current board port), then
load the primes bitstream or press BTNC. See the program READMEs for detailed controls.

JTAG configuration is volatile and disappears at power-off. The existing scripts alone
do not prove unattended cold-power boot. `scripts/vivado/flash.tcl` writes a bitstream into
the configuration flash instead:

```powershell
vivado -mode batch -nojournal -nolog -source scripts/vivado/flash.tcl -tclargs list
vivado -mode batch -nojournal -nolog -source scripts/vivado/flash.tcl -tclargs <flash_part> build/phase7/vivado-primes-single25/basys3_soc.bit
```

Vivado reads the chip's ID before erasing and refuses a mismatched part, so a wrong guess
is harmless. This board's flash identified itself as a **Macronix MX25L3273F** (JEDEC ID
`c2 20 16`), Vivado part `mx25l3273f-spi-x1_x2_x4`. JP1 is the 4-pin column labeled MODE,
left of the PROG button; the cap on the top pair (beside the printed "1") selects QSPI.
Vivado is not on PATH by default; first run `$env:Path += ";C:\AMDDesignTools\2025.2\Vivado\bin"`.

> [!NOTE]
> **Primes cold boot passed on November 8, 2026.** The single-cycle 25 MHz primes bitstream
> (WNS +0.396 ns, WHS +0.074 ns, 0 DRC) was erased, programmed and verified into the
> MX25L3273F with JP1 on QSPI. After a reset, `primes_check.py` on COM8 reported
> `PASS: 1229 exact primes; cycles=258432 instret=258429 CPI=1.000` over 6,094 bytes,
> matching the simulation exactly. The board was then switched off and on with no laptop
> action; DONE lit and the display showed 1229 again.

## 5. Previews and presentation material

The frame previews linked from the root README are decoded **simulated FPGA RGB output**,
not mockups or photos. The bench compares every physical pixel before recording PASS.
The [architecture sheet](../ARCHITECTURE.md) is complete. Photos of the actual board and
screen, the 60-second video, and the personal hardest-bug write-up are still pending.

A suggested 60-second recording sequence, once hardware is verified: 0-10 s identify
the Basys/CPU and controls; 10-25 s show primes and measured counters; 25-40 s restart
Life with two patterns; 40-55 s steer/pause Snake and show its score; 55-60 s point to
the architecture sheet and repository. Each program is a separate bitstream today:
record distinct cuts and label them honestly. There is no portable multi-program
launcher yet.

### Hardest-bug candidate

Phase 6's REQP-1839 failure is a useful technical candidate. Automatic BRAM power
optimization inserted look-ahead enables influenced by asynchronous reset logic on the
VGA memories. The fix retained deliberate synchronous memory controls and excluded only
the six VGA BRAMs from that optimization in the build Tcl. Timing/DRC then passed without
waiving severity or replacing synchronous reads. The [Phase 6 record](PHASE6_VGA.md)
contains the evidence. The personal write-up (what it felt like to debug, what was tried
first) still needs to be written.

## 6. Acceptance that remains

- [ ] Phase 6 color bars, text and pixels observed on a physical VGA display.
- [ ] Each Phase 7 demo observed after a genuine cold power-on with its boot/configuration
  method recorded. **Primes passed** from QSPI flash (November 8, 2026); Life and Snake
  need a monitor.
- [x] Physical primes capture checked: board PASS on COM8, identical counters to simulation.
- [ ] Life controls and Snake playability observed on the board/display.
- [ ] Actual board/screen photos and a recorded 60-second video.
- [ ] Personal hardest-bug write-up.
- [ ] Another person follows the README alone and records versions, commands, hashes,
  results and any missing steps. An automated/source-only self-check is preparation,
  not this independent human acceptance.
- [ ] Hosted CI on these changes once they are pushed.

**The Phase 7 gate is not passed.** Local code, simulations, reports and presentation
assets do not substitute for the physical and independent-rebuild observations.
