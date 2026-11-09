#!/usr/bin/env python3
"""Build and run every Verilator testbench and print a pass/fail table.

Discovery rules:
  * every tb/**/<name>_tb.sv is one test; its top module must be <name>_tb
  * every rtl/**/*.sv file is compiled with each test (packages, *_pkg.sv,
    go first so later files can import them)

A test passes only when Verilator builds it, the simulation exits with
status 0 within the timeout, and its output contains a line starting with
"PASS:". A bench that finishes without saying PASS is treated as a failure,
so a missing $display cannot hide a test that checked nothing.

CPU programs (Phases 2-7): tb/system/cpu_tb.sv is built once and run once per program:
  * directed tests: sw/tests/**/*.S (isa/ and faults/)
  * official rv32ui tests: sw/riscv-tests/isa/rv32ui/*.S (git submodule),
    except those listed in RV32UI_SKIP
  * Phase 3 C fixtures: the actual board Fibonacci image at 23 switch
    inputs, plus the freestanding ABI/data/libgcc/counter smoke program
  * Phase 4 hello/echo prefix and formatting/input tests on actual UART pins
Board C image (Phase 3): tb/system/board_c_tb.sv is also built once and runs the
same Fibonacci image on the complete basys3_soc top, changing the switches
while it runs and checking the LEDs, hex register and scanned display pins.
Board UART (Phase 4): board_uart_tb runs hello on the same full top with
the real one-second counter interval, typed input and CPU-only reset.
Board VGA (Phase 6): board_vga_tb and its pipeline wrapper run the actual
vga_demo and compare a complete text, pixel and color-bar frame on the pins.
Phase 7: primes_tb checks the full sieve UART stream and measured CPI; life_tb
and snake_tb drive real board inputs and compare independently modeled frames.
Their pipeline wrappers use the separately verified 62.5 MHz CPU clock.
Assembly programs use sw/tests/env/; C programs use sw/common/ and the checked
build_software.py flow. Both use RISC-V GCC (-march=rv32i -mabi=ilp32), link at
address 0 and convert with scripts/bin2mem.py.
A line "// cpu_tb: +arg ..." in a program adds plusargs for its run.
The GCC prefix is found automatically or set with RISCV_PREFIX
(e.g. RISCV_PREFIX=riscv64-unknown-elf-). A missing toolchain or submodule
is reported as a failure, never silently skipped.

Usage (WSL, from anywhere):
    python3 scripts/run_tests.py                # all tests
    python3 scripts/run_tests.py counter        # tests whose name contains "counter"
    python3 scripts/run_tests.py -v             # show each test's output
    python3 scripts/run_tests.py --list         # list tests without running
    python3 scripts/run_tests.py rv32ui         # only the official CPU tests
    python3 scripts/run_tests.py cpu_tb:directed/fib -v   # one program, with output
    python3 scripts/run_tests.py --evidence-dir build/simulation  # VGA PPM / UART captures
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RTL_DIR = REPO / "rtl"
TB_DIR = REPO / "tb"
# Keep generated files off the Windows/OneDrive mount (see docs/phases/PHASE0_SMOKE_TEST.md).
DEFAULT_BUILD = Path(os.environ.get(
    "RVC_BUILD_DIR", Path.home() / ".cache" / "risc-v-computer" / "tests"))

VERILATOR_FLAGS = ["--binary", "--timing", "--assert", "-Wall"]
# Extra flags per bench: cpu_tb can dump waveforms with +vcd=<file>.
BENCH_FLAGS = {"cpu_tb": ["--trace"], "cpu_pipe_tb": ["--trace"]}
# Wrappers rerun a bench with another CPU, bus-edge or clock parameter.
# Each wrapper is compiled together with the bench it parameterizes.
WRAPPED_BENCHES = {
    "dbg_ram_arbiter_rise_tb": "dbg_ram_arbiter_tb",
    "soc_pipe_tb": "soc_tb",
    "vga_pipe_tb": "vga_tb",
    "board_vga_pipe_tb": "board_vga_tb",
    "board_vga_fast_tb": "board_vga_tb",
    "primes_pipe_tb": "primes_tb",
    "life_pipe_tb": "life_tb",
    "snake_pipe_tb": "snake_tb",
    "clock_gen_62mhz_tb": "clock_gen_fast_tb",
    "basys3_soc_pipe_tb": "basys3_soc_tb",
    "board_c_pipe_tb": "board_c_tb",
    "board_uart_pipe_tb": "board_uart_tb",
}

SW_DIR = REPO / "sw"
ENV_DIR = SW_DIR / "tests" / "env"
RISCV_TESTS = SW_DIR / "riscv-tests"
RV32UI_DIR = RISCV_TESTS / "isa" / "rv32ui"
# Official tests outside this project's contract (documented in
# docs/phases/PHASE2_SINGLE_CYCLE.md):
#   fence_i  needs FENCE.I (Zifencei), which is not part of RV32I
#   ma_data  needs misaligned loads/stores to work or trap; this CPU stops
RV32UI_SKIP = {"fence_i", "ma_data"}
# Inventory at the pinned submodule revision. A partial checkout must not
# silently turn a 40-program regression into a smaller passing suite.
RV32UI_NAMES = set("""
    add addi and andi auipc beq bge bgeu blt bltu bne fence_i jal jalr
    lb lbu ld_st lh lhu lui lw ma_data or ori sb sh simple sll slli
    slt slti sltiu sltu sra srai srl srli st_ld sub sw xor xori
""".split())
PROGRAM_BENCH = "cpu_tb"
# Phase 5: the same programs on the pipeline, and both CPUs in lockstep.
PIPE_BENCH = "cpu_pipe_tb"
LOCKSTEP_BENCH = "lockstep_tb"
CPU_BENCHES = (PROGRAM_BENCH, PIPE_BENCH, LOCKSTEP_BENCH)
# Runs the board C image on the complete basys3_soc top (no per-instruction
# checks; cpu_tb provides those). Built once, then run with that image.
BOARD_BENCH = "board_c_tb"
UART_BOARD_BENCH = "board_uart_tb"
BOARD_PIPE_BENCH = "board_c_pipe_tb"
UART_BOARD_PIPE_BENCH = "board_uart_pipe_tb"
UART_BOARD_BENCHES = (UART_BOARD_BENCH, UART_BOARD_PIPE_BENCH)
VGA_BOARD_BENCH = "board_vga_tb"
VGA_BOARD_PIPE_BENCH = "board_vga_pipe_tb"
VGA_BOARD_FAST_BENCH = "board_vga_fast_tb"
VGA_BOARD_BENCHES = (VGA_BOARD_BENCH, VGA_BOARD_PIPE_BENCH, VGA_BOARD_FAST_BENCH)
DEMO_BENCHES = {name: (f"{name}_tb",f"{name}_pipe_tb") for name in ("primes","life","snake")}
DEMO_BOARD_BENCHES = tuple(bench for benches in DEMO_BENCHES.values() for bench in benches)
BENCH_CPU_HZ = {VGA_BOARD_FAST_BENCH: 62_500_000,
                **{benches[1]: 62_500_000 for benches in DEMO_BENCHES.values()}}
PROGRAM_BENCHES = (*CPU_BENCHES, BOARD_BENCH, UART_BOARD_BENCH, BOARD_PIPE_BENCH,
                   UART_BOARD_PIPE_BENCH, *VGA_BOARD_BENCHES, *DEMO_BOARD_BENCHES)
# Lockstep plusargs for programs that never halt or that read the console:
# compare a fixed retirement window and feed scripted UART input.
LOCKSTEP_ARGS = {
    "hello": ("+max_retire=20000", "+rx=52495343"),
    "printf_smoke": ("+rx=4b",),
    "runtime_smoke": (),
    "pipe_mmio": ("+rx=4b",),
    "cpi_bench": (),
    "cpi_report": ("+max_retire=45000",),
}
LOCKSTEP_FIB_INPUTS = (0, 1, 5, 20, 21, 65535)
GCC_PREFIXES = ["riscv64-unknown-elf-", "riscv32-unknown-elf-",
                "riscv-none-elf-", "riscv64-linux-gnu-"]


@dataclass
class Result:
    name: str
    status: str  # PASS, FAIL, BUILD, TIMEOUT
    seconds: float
    detail: str
    log: str


def rtl_sources() -> list[Path]:
    files = sorted(RTL_DIR.rglob("*.sv"))
    pkgs = [f for f in files if f.stem.endswith("_pkg")]
    return pkgs + [f for f in files if f not in pkgs]


def find_tests(pattern: str | None) -> list[Path]:
    tests = sorted(TB_DIR.rglob("*_tb.sv"))
    if pattern:
        # A program bench also runs when the pattern names one of its programs.
        tests = [t for t in tests if pattern in t.stem
                 or (t.stem in PROGRAM_BENCHES and pattern_targets_programs(pattern, t.stem))]
    return tests


def pattern_targets_programs(pattern: str, bench: str = PROGRAM_BENCH) -> bool:
    if any(pattern in label for label, p in find_programs(None) if p.bench == bench):
        return True
    return bench in CPU_BENCHES and (pattern in ("rv32ui", "directed") or any(
        pattern in f"{bench}:rv32ui/{name}" for name in RV32UI_NAMES - RV32UI_SKIP))


@dataclass
class Program:
    suite: str
    name: str
    source: Path
    args: tuple[str, ...] = ()
    bench: str = PROGRAM_BENCH

    @property
    def label(self) -> str:
        return f"{self.bench}:{self.suite}/{self.name}"


def find_programs(pattern: str | None) -> list[tuple[str, Program]]:
    progs = [Program("directed", p.stem, p)
             for p in sorted((SW_DIR / "tests").rglob("*.S"), key=lambda p: p.name)]
    if RV32UI_DIR.is_dir():
        progs += [Program("rv32ui", p.stem, p) for p in sorted(RV32UI_DIR.glob("*.S"))
                  if p.stem not in RV32UI_SKIP]
    # The unchanged board ELF is exercised at multiple switch values. The
    # expected table is independent of the C loop and includes invalid inputs.
    fib = SW_DIR / "programs" / "fib" / "main.c"
    if fib.is_file():
        values = [0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233,
                  377, 610, 987, 1597, 2584, 4181, 6765]
        for n in [*range(21), 21, 65535]:
            expected = values[n] if n <= 20 else 0xffff
            progs.append(Program("c", f"fib_{n:02d}", fib,
                                 (f"+switches={n:04x}", f"+expect_leds={n:04x}",
                                  f"+expect_display={expected:04x}")))
        # The same image on the physical top, with live switch changes.
        progs.append(Program("c", "fib_board", fib, bench=BOARD_BENCH))
    runtime = SW_DIR / "programs" / "runtime_smoke" / "main.c"
    if runtime.is_file():
        progs.append(Program("c", "runtime_smoke", runtime,
                             ("+expect_leds=600d", "+expect_display=4924")))
    # Phase 5 CPI workload; the checksum is computed independently in Python.
    cpi = SW_DIR / "programs" / "cpi_bench" / "main.c"
    if cpi.is_file():
        progs.append(Program("c", "cpi_bench", cpi, ("+expect_leds=600d", "+expect_display=991d")))
    for name in ("hello", "printf_smoke", "cpi_report"):
        source = SW_DIR / "programs" / name / "main.c"
        if source.is_file():
            progs.append(Program("c", name, source))
            if name == "hello":
                progs.append(Program("c", "hello_board", source, bench=UART_BOARD_BENCH))
    # Phase 5: every cpu_tb program also runs on cpu_pipe_tb with the same
    # plusargs, and in lockstep against the single-cycle reference.
    base = [p for p in progs if p.bench == PROGRAM_BENCH]
    progs += [Program(p.suite, p.name, p.source, p.args, PIPE_BENCH) for p in base]
    for p in base:
        if p.suite != "c":
            progs.append(Program(p.suite, p.name, p.source, LOCKSTEP_ARGS.get(p.name, ()),
                                 LOCKSTEP_BENCH))
        elif p.name.startswith("fib_") and int(p.name[4:]) in LOCKSTEP_FIB_INPUTS:
            progs.append(Program("c", p.name, p.source,
                                 (f"+switches={int(p.name[4:]):04x}", "+max_retire=3000"),
                                 LOCKSTEP_BENCH))
        elif p.name in LOCKSTEP_ARGS:
            progs.append(Program("c", p.name, p.source, LOCKSTEP_ARGS[p.name], LOCKSTEP_BENCH))
    if fib.is_file():
        progs.append(Program("c", "fib_board", fib, bench=BOARD_PIPE_BENCH))
    hello = SW_DIR / "programs" / "hello" / "main.c"
    if hello.is_file():
        progs.append(Program("c", "hello_board", hello, bench=UART_BOARD_PIPE_BENCH))
    # The VGA demo runs only on the full physical top; legacy instruction
    # harnesses deliberately tie the optional display interface off.
    vga_demo = SW_DIR / "programs" / "vga_demo" / "main.c"
    if vga_demo.is_file():
        for bench in VGA_BOARD_BENCHES:
            progs.append(Program("c", "vga_demo", vga_demo, bench=bench))
    for name,benches in DEMO_BENCHES.items():
        source = SW_DIR/"programs"/name/"main.c"
        if source.is_file():
            for bench in benches:
                progs.append(Program("c",name,source,("+trace",) if name != "primes" else (),bench=bench))
    out = [(p.label, p) for p in progs]
    if pattern:
        out = [(l, p) for l, p in out if pattern in l]
    return out


def find_gcc_prefix() -> str | None:
    env = os.environ.get("RISCV_PREFIX")
    for prefix in ([env] if env else GCC_PREFIXES):
        if all(shutil.which(prefix + tool) for tool in ("gcc", "objcopy", "objdump")):
            return prefix
    return None


def rv32ui_problem() -> str:
    if not RV32UI_DIR.is_dir():
        return "sw/riscv-tests not checked out: git submodule update --init sw/riscv-tests"
    actual = {p.stem for p in RV32UI_DIR.glob("*.S")}
    missing, extra = RV32UI_NAMES - actual, actual - RV32UI_NAMES
    if missing or extra:
        return ("rv32ui inventory differs from the pinned suite: "
                f"missing={','.join(sorted(missing)) or 'none'}; "
                f"unexpected={','.join(sorted(extra)) or 'none'}")
    return ""


def plusargs_for(source: Path) -> list[str]:
    args = []
    for line in source.read_text().splitlines():
        line = line.strip()
        if line.startswith("// cpu_tb:"):
            args += shlex.split(line[len("// cpu_tb:"):])
    return args


def build_program(prog: Program, prefix: str, out_dir: Path) -> tuple[Path | None, str]:
    """Assemble, link and convert one program. Returns (mem path, log)."""
    if prog.source.suffix == ".c":
        from build_software import BuildError, build
        try:
            cpu_hz = BENCH_CPU_HZ.get(prog.bench, 25_000_000)
            return build(prog.source, out_dir / prog.source.parent.name, prefix, cpu_hz)
        except (BuildError, OSError, ValueError) as exc:
            return None, str(exc)
    out_dir.mkdir(parents=True, exist_ok=True)
    elf = out_dir / f"{prog.name}.elf"
    binf = out_dir / f"{prog.name}.bin"
    mem = out_dir / f"{prog.name}.mem"
    steps = [
        [prefix + "gcc", "-march=rv32i", "-mabi=ilp32", "-static", "-nostdlib",
         "-nostartfiles", "-T", str(ENV_DIR / "link.ld"),
         "-I", str(ENV_DIR), "-I", str(RISCV_TESTS / "isa" / "macros" / "scalar"),
         str(prog.source), "-o", str(elf)],
        [prefix + "objcopy", "-O", "binary", str(elf), str(binf)],
        [sys.executable, str(REPO / "scripts" / "bin2mem.py"), str(binf), str(mem)],
        [prefix + "objdump", "-d", str(elf)],
    ]
    log = ""
    for cmd in steps:
        log += "$ " + shlex.join(cmd) + "\n"
        try:
            r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
        except OSError as exc:
            return None, log + f"cannot run {cmd[0]}: {exc}\n"
        log += r.stdout + r.stderr
        if r.returncode != 0:
            return None, log
    (out_dir / f"{prog.name}.dump").write_text(r.stdout)
    return mem, log


def run_programs(binary: Path, build_root: Path, pattern: str | None,
                 timeout: float, verbose: bool, bench: str = PROGRAM_BENCH,
                 evidence_dir: Path | None = None) -> list[Result]:
    results = []
    programs = [(label, p) for label, p in find_programs(pattern) if p.bench == bench]
    wants_rv32ui = bench in CPU_BENCHES and (
        not pattern or pattern == bench or pattern == "rv32ui" or any(
            pattern in f"{bench}:rv32ui/{name}" for name in RV32UI_NAMES - RV32UI_SKIP))
    if wants_rv32ui and (problem := rv32ui_problem()):
        results.append(Result(f"{bench}:rv32ui", "FAIL", 0.0, problem, ""))
        programs = [(label, p) for label, p in programs if p.suite != "rv32ui"]
    if not programs and not results:
        return [Result(f"{bench}:programs", "FAIL", 0.0, "no CPU programs found", "")]
    prefix = find_gcc_prefix()
    if prefix is None:
        results.append(Result(f"{bench}:programs", "FAIL", 0.0,
                              "no complete RISC-V toolchain (gcc, objcopy, objdump); "
                              "install gcc-riscv64-unknown-elf or set RISCV_PREFIX", ""))
        return results
    built = {}
    for label, prog in programs:
        print(f"  running {label} ...", end="", flush=True)
        start = time.monotonic()
        if prog.source not in built:
            built[prog.source] = build_program(prog, prefix, build_root / "programs" / prog.suite)
        mem, log = built[prog.source]
        if mem is None:
            r = Result(label, "BUILD", time.monotonic() - start, first_error(log), log)
        else:
            try:
                cmd = [str(binary), f"+program={mem}"]
                if bench in (PROGRAM_BENCH, PIPE_BENCH):
                    cmd += ["+quiet", *plusargs_for(prog.source)]
                elif bench == LOCKSTEP_BENCH:
                    # cpu_tb-only options are ignored; +max_cycles still applies.
                    cmd += plusargs_for(prog.source)
                cmd += prog.args
                evidence = None
                if evidence_dir is not None and bench in (*VGA_BOARD_BENCHES,*DEMO_BOARD_BENCHES):
                    evidence = evidence_dir.resolve()/bench/prog.name
                    evidence.mkdir(parents=True,exist_ok=True)
                    (evidence/"result.json").write_text(json.dumps({"passed":False,"provenance":"Verilator simulation","status":"run not completed"})+"\n")
                    cmd += [f"+capture={evidence}/uart.bin"] if prog.name == "primes" else [f"+frames={evidence}"]
                sim = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                                     timeout=timeout)
                elapsed = time.monotonic() - start
                r = simulation_result(label, sim, elapsed)
                if evidence is not None:
                    (evidence/"result.json").write_text(json.dumps({"passed":r.status == "PASS","provenance":"Verilator simulation",
                        "test":label,"cpu_hz":BENCH_CPU_HZ.get(bench,25_000_000),"status":r.detail},indent=2)+"\n")
                if r.status == "PASS":
                    r.detail = r.detail.split(" ", 2)[-1][:DETAIL_WIDTH]
                else:
                    r.log += "\nrerun with a trace:\n  " + shlex.join(cmd + ["+trace"])
            except subprocess.TimeoutExpired as exc:
                r = Result(label, "TIMEOUT", time.monotonic() - start,
                           f"no exit after {timeout:g} s", timeout_output(exc))
            except OSError as exc:
                r = Result(label, "FAIL", time.monotonic() - start, str(exc), str(exc))
            except ValueError as exc:
                r = Result(label, "BUILD", time.monotonic() - start, f"invalid program options: {exc}", str(exc))
        print(f" {r.status}")
        if verbose or r.status != "PASS":
            print("    " + "\n    ".join(r.log.strip().splitlines()[-40:]))
        results.append(r)
    return results


DETAIL_WIDTH = 160


def timeout_output(exc: subprocess.TimeoutExpired) -> str:
    def decode(value: str | bytes | None) -> str:
        return value.decode(errors="replace") if isinstance(value, bytes) else (value or "")
    return decode(exc.stdout) + decode(exc.stderr)


def simulation_result(name: str, sim: subprocess.CompletedProcess, seconds: float) -> Result:
    log = sim.stdout + sim.stderr
    pass_line = next((line for line in sim.stdout.splitlines() if line.startswith("PASS:")), "")
    fail_line = next((line for line in log.splitlines() if line.startswith("FAIL:")), "")
    if sim.returncode == 0 and pass_line and not fail_line:
        return Result(name, "PASS", seconds, pass_line[:DETAIL_WIDTH], log)
    detail = fail_line or first_error(log) or "exited without a PASS: result"
    return Result(name, "FAIL", seconds, f"exit {sim.returncode}: {detail}"[:DETAIL_WIDTH], log)


def last_line(text: str) -> str:
    lines = [l.strip() for l in text.strip().splitlines() if l.strip()]
    return lines[-1][:DETAIL_WIDTH] if lines else ""


def first_error(text: str) -> str:
    """Return the most useful failure line.

    A failed assertion prints "[time] %Fatal: ... message" and is followed by
    a generic "%Error: ... Verilog $stop" line, so %Fatal is searched first.
    """
    text = text.replace(str(REPO) + os.sep, "")
    lines = [l.strip() for l in text.splitlines()]
    for marker in ("%Fatal", "%Error", "%Warning"):
        for line in lines:
            if marker in line:
                return line[:DETAIL_WIDTH]
    return last_line(text)


def run_one(tb: Path, build_root: Path, jobs: int, timeout: float) -> Result:
    name = tb.stem
    mdir = build_root / name
    if mdir.exists():
        shutil.rmtree(mdir)
    mdir.mkdir(parents=True)
    start = time.monotonic()

    cmd = ["verilator", *VERILATOR_FLAGS, *BENCH_FLAGS.get(name, []), "-j", str(jobs),
           "--top-module", name, "--Mdir", str(mdir),
           *[str(s) for s in rtl_sources()],
           *([str(next(TB_DIR.rglob(f"{WRAPPED_BENCHES[name]}.sv")))] if name in WRAPPED_BENCHES else []),
           str(tb)]
    try:
        build = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    except OSError as exc:
        return Result(name, "BUILD", time.monotonic() - start, str(exc), str(exc))
    build_log = build.stdout + build.stderr
    if build.returncode != 0:
        return Result(name, "BUILD", time.monotonic() - start,
                      first_error(build_log), build_log)

    if name in PROGRAM_BENCHES:
        # Built here; run once per program by run_programs().
        return Result(name, "BUILT", time.monotonic() - start, str(mdir / f"V{name}"), build_log)

    try:
        sim = subprocess.run([str(mdir / f"V{name}")], cwd=REPO,
                             capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        return Result(name, "TIMEOUT", time.monotonic() - start,
                      f"no exit after {timeout:g} s", timeout_output(exc))
    except OSError as exc:
        return Result(name, "FAIL", time.monotonic() - start, str(exc), str(exc))
    return simulation_result(name, sim, time.monotonic() - start)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("pattern", nargs="?", help="only run tests whose name contains this")
    ap.add_argument("-v", "--verbose", action="store_true", help="print every test's output")
    ap.add_argument("--list", action="store_true", help="list tests and exit")
    ap.add_argument("--build-dir", type=Path, default=DEFAULT_BUILD,
                    help=f"where generated files go (default {DEFAULT_BUILD})")
    ap.add_argument("--evidence-dir", type=Path,
                    help="optional VGA/Phase 7 pin captures and simulation result records")
    ap.add_argument("-j", "--jobs", type=int, default=max(1, min(4, os.cpu_count() or 1)),
                    help="Verilator compile jobs per test")
    ap.add_argument("--timeout", type=float,
                    help="simulation seconds (default: 60, or 180 for full-board UART/VGA demos)")
    args = ap.parse_args()
    if args.jobs < 1 or (args.timeout is not None and not 0 < args.timeout < float("inf")):
        ap.error("--jobs must be positive and --timeout must be positive and finite")
    args.build_dir = args.build_dir.expanduser().resolve()

    tests = find_tests(args.pattern)
    if args.list:
        for t in tests:
            print(t.relative_to(REPO))
            if t.stem in PROGRAM_BENCHES:
                for label, p in find_programs(args.pattern):
                    if p.bench == t.stem:
                        print(f"  {label}")
        return 0
    if not tests:
        print(f"No testbenches found in {TB_DIR.relative_to(REPO)}/"
              + (f" matching '{args.pattern}'" if args.pattern else ""))
        return 1
    if shutil.which("verilator") is None:
        print("verilator not found on PATH (run this from WSL)")
        return 1

    ver = subprocess.run(["verilator", "--version"], capture_output=True, text=True)
    print(f"{ver.stdout.strip()}  |  {len(tests)} test(s)  |  build: {args.build_dir}\n")

    results = []
    for tb in tests:
        default_timeout = 180.0 if tb.stem in (*UART_BOARD_BENCHES, *VGA_BOARD_BENCHES, *DEMO_BOARD_BENCHES) else 60.0
        timeout = args.timeout if args.timeout is not None else default_timeout
        print(f"  running {tb.stem} ...", end="", flush=True)
        r = run_one(tb, args.build_dir, args.jobs, timeout)
        print(f" {r.status}")
        if r.status == "BUILT":
            results += run_programs(Path(r.detail), args.build_dir, args.pattern,
                                    timeout, args.verbose, tb.stem, args.evidence_dir)
            continue
        results.append(r)
        if args.verbose or r.status != "PASS":
            print("    " + "\n    ".join(r.log.strip().splitlines()[-40:]))

    w = max([len("Test"), *(len(r.name) for r in results)])
    print(f"\n{'Test':<{w}}  {'Result':<7}  {'Time':>6}  Detail")
    print(f"{'-' * w}  {'-' * 7}  {'-' * 6}  {'-' * 40}")
    for r in results:
        print(f"{r.name:<{w}}  {r.status:<7}  {r.seconds:5.1f}s  {r.detail}")
    passed = sum(r.status == "PASS" for r in results)
    print(f"\n{passed}/{len(results)} passed")
    return 0 if results and passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
