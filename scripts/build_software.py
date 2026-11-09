#!/usr/bin/env python3
"""Build a freestanding RV32I C program and derive image metadata from its ELF.

Usage (WSL): python3 scripts/build_software.py fib --output-dir build/software/fib
Outputs: <name>.elf/.bin/.mem/.map/.dump/.json. The JSON is Phase 3 build
metadata; the versioned, validated Tab5 loader manifest remains T5 work.
"""
from __future__ import annotations

import argparse
import binascii
import hashlib
import json
from pathlib import Path
import shlex
import struct
import subprocess
import sys

from bin2mem import convert

REPO = Path(__file__).resolve().parent.parent
COMMON = REPO / "sw" / "common"
PROGRAM_LIMIT = 0xD000


class BuildError(RuntimeError):
    pass


def elf_symbols(data: bytes) -> tuple[int, dict[str, int]]:
    """Read only the ELF32 little-endian executable/symbol format emitted here."""
    if len(data) < 52:
        raise ValueError("truncated ELF header")
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", data)
    ident, kind, machine, version, entry, _, shoff, flags, ehsize, _, _, shsize, shnum, _ = header
    if ident[:7] != b"\x7fELF\x01\x01\x01" or kind != 2 or machine != 243 or version != 1:
        raise ValueError("expected a little-endian ELF32 RISC-V executable")
    if flags & 0xF or ehsize != 52 or shsize != 40 or shnum == 0:
        raise ValueError("unsupported ELF flags or section-header format (RV32I/soft-float required)")
    if shoff + shsize * shnum > len(data):
        raise ValueError("truncated ELF section table")
    sections = [struct.unpack_from("<IIIIIIIIII", data, shoff + i * shsize) for i in range(shnum)]

    def contents(section):
        offset, size = section[4:6]
        if offset + size > len(data):
            raise ValueError("truncated ELF section")
        return data[offset:offset + size]

    symbols = {}
    for section in sections:
        if section[1] != 2:  # SHT_SYMTAB
            continue
        if section[9] != 16 or section[5] % 16 or section[6] >= len(sections):
            raise ValueError("invalid ELF symbol table")
        string_section = sections[section[6]]
        if string_section[1] != 3:
            raise ValueError("symbol names do not reference a string table")
        names = contents(string_section)
        table = contents(section)
        for offset in range(0, len(table), 16):
            name, value, _, _, _, index = struct.unpack_from("<IIIBBH", table, offset)
            if index == 0:
                continue
            end = names.find(b"\0", name)
            if end < 0:
                raise ValueError("invalid ELF symbol name")
            symbols[names[name:end].decode("utf-8")] = value
    return entry, symbols


def image_metadata(elf: bytes, binary: bytes, name: str) -> dict:
    entry, symbols = elf_symbols(elf)
    required = ["_start", "__image_end", "__bss_start", "__bss_end", "__heap_start", "__heap_end",
                "__scratch_start", "__scratch_end", "__stack_bottom", "__stack_top"]
    if any(key not in symbols for key in required):
        raise ValueError("ELF lacks required startup/layout symbols")
    if entry != 0 or symbols["_start"] != 0:
        raise ValueError("reset entry must be zero")
    padded_size = (len(binary) + 3) & ~3
    if not binary or padded_size > PROGRAM_LIMIT or symbols["__image_end"] > PROGRAM_LIMIT:
        raise ValueError("initialized image is empty or overlaps diagnostic scratch")
    if padded_size != symbols["__image_end"]:
        raise ValueError("binary length does not match the ELF initialized-image bound")
    bss_start, bss_end = symbols["__bss_start"], symbols["__bss_end"]
    if not len(binary) <= bss_start <= bss_end <= symbols["__heap_start"] <= PROGRAM_LIMIT:
        raise ValueError("invalid image/BSS/heap bounds")
    if (bss_start | bss_end) & 3:
        raise ValueError("BSS bounds must be word aligned")
    if (symbols["__heap_end"], symbols["__scratch_start"], symbols["__scratch_end"],
            symbols["__stack_bottom"], symbols["__stack_top"]) != (0xD000, 0xD000, 0xE000, 0xE000, 0x10000):
        raise ValueError("ELF reservations differ from the Phase 3 RAM map")
    return {
        "schema_version": 1, "name": name, "isa": "rv32i", "abi": "ilp32",
        "load_address": 0, "entry_address": entry, "image_bytes": len(binary),
        "image_padded_bytes": padded_size,
        "image_crc32": f"{binascii.crc32(binary) & 0xffffffff:08x}",
        "image_sha256": hashlib.sha256(binary).hexdigest(),
        "bss": {"start": bss_start, "end": bss_end},
        "heap": {"start": symbols["__heap_start"], "end": symbols["__heap_end"]},
        "scratch": {"start": 0xD000, "end": 0xE000},
        "stack": {"start": 0xE000, "end": 0x10000},
    }


def build(source: Path, output_dir: Path, prefix: str, cpu_hz: int = 25_000_000) -> tuple[Path, str]:
    if not 0 < cpu_hz <= 500_000_000:
        raise ValueError("configured CPU clock must be 1..500000000 Hz")
    source, output_dir = source.resolve(), output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    name = source.parent.name
    elf, binary, mem, map_file, dump, meta = [output_dir / f"{name}.{suffix}"
                                            for suffix in ("elf", "bin", "mem", "map", "dump", "json")]
    # A failed rebuild must not leave an older image beside the new error.
    for stale in (elf, binary, mem, map_file, dump, meta):
        stale.unlink(missing_ok=True)
    commands = [
        [prefix + "gcc", "-march=rv32i", "-mabi=ilp32", "-O2", "-ffreestanding", "-fno-builtin",
         "-fno-pic", "-ffunction-sections", "-fdata-sections", "-msmall-data-limit=0",
         "-Wall", "-Wextra", "-Werror", "-nostdlib", "-nostartfiles", f"-DRVC_CPU_HZ={cpu_hz}u",
         "-T", str(COMMON / "link.ld"), "-I", str(COMMON),
         "-Wl,--gc-sections,--no-relax,--build-id=none,-Map," + str(map_file),
         str(COMMON / "crt0.S"), str(source),
         *[str(p) for p in sorted(source.parent.glob("*.c")) if p.resolve() != source],
         str(COMMON / "uart.c"),
         str(COMMON / "printf.c"), str(COMMON / "vga.c"),
         str(COMMON / "buttons.c"), str(COMMON / "rand.c"), "-lgcc", "-o", str(elf)],
        [prefix + "objcopy", "-O", "binary", str(elf), str(binary)],
        [prefix + "objdump", "-d", str(elf)],
    ]
    log = ""
    for command in commands:
        log += "$ " + shlex.join(command) + "\n"
        result = subprocess.run(command, cwd=REPO, capture_output=True, text=True)
        log += result.stdout + result.stderr
        if result.returncode:
            raise BuildError(log)
    dump.write_text(result.stdout, encoding="utf-8")
    data = binary.read_bytes()
    metadata = image_metadata(elf.read_bytes(), data, name)
    metadata["configured_cpu_hz"] = cpu_hz
    with mem.open("w", encoding="ascii", newline="\n") as target:
        target.write(convert(data))
    meta.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return mem, log


def main() -> int:
    from run_tests import find_gcc_prefix
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("program", nargs="?", default="fib", help="folder under sw/programs")
    parser.add_argument("--output-dir", type=Path, help="default: build/software/<program>")
    parser.add_argument("--cpu-hz", type=int, default=25_000_000, help="configured CPU frequency for software delays")
    args = parser.parse_args()
    source = REPO / "sw" / "programs" / args.program / "main.c"
    if not source.is_file():
        parser.error(f"no C program at {source}")
    prefix = find_gcc_prefix()
    if prefix is None:
        parser.error("RV32-capable GCC, objcopy and objdump required; install gcc-riscv64-unknown-elf")
    try:
        mem, _ = build(source, args.output_dir or REPO / "build" / "software" / args.program, prefix, args.cpu_hz)
    except (BuildError, ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"Built {args.program}: {mem} (ELF, map, disassembly and metadata alongside)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
