#!/usr/bin/env python3
"""Convert a raw binary (objcopy -O binary) into a $readmemh image for ram.sv.

Output: one 32-bit word per line, 8 hex digits, word 0 (address 0) first.
Bytes are little-endian within a word, matching RISC-V and ram.sv's lanes.

Usage:
    python3 scripts/bin2mem.py program.bin program.mem [--size 65536]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def convert(data: bytes) -> str:
    if len(data) % 4:
        data += b"\0" * (4 - len(data) % 4)
    words = (int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4))
    return "".join(f"{w:08x}\n" for w in words)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("binary", type=Path)
    ap.add_argument("mem", type=Path)
    ap.add_argument("--size", type=int, default=64 * 1024,
                    help="RAM size in bytes; larger images are rejected (default 65536)")
    args = ap.parse_args()

    if args.size <= 0 or args.size % 4:
        ap.error("--size must be a positive multiple of four bytes")
    try:
        if args.binary.resolve() == args.mem.resolve() or (
                args.mem.exists() and args.binary.samefile(args.mem)):
            ap.error("binary input and memory output must be different files")
        # Read at most one byte beyond the limit, even for a malformed huge input.
        with args.binary.open("rb") as source:
            data = source.read(args.size + 1)
        if len(data) > args.size:
            print(f"{args.binary}: image does not fit in {args.size} bytes of RAM", file=sys.stderr)
            return 1
        with args.mem.open("w", encoding="ascii", newline="\n") as target:
            target.write(convert(data))
    except OSError as exc:
        print(f"bin2mem: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
