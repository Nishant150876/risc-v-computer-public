#!/usr/bin/env python3
"""Convert a VGA testbench's actual P6 pin capture to PNG, using only stdlib.

Usage: python3 scripts/vga_preview.py build/phase6/frames/mode0.ppm output.png
Captures come from board_vga_tb, life_tb or snake_tb (including wrappers) with
+frames=<existing-directory>; they are simulated FPGA output, not photographs
or evidence of a physical monitor gate.
"""
import argparse
from pathlib import Path
import struct
import sys
import zlib


def convert(data: bytes) -> bytes:
    header = b"P6\n640 480\n255\n"
    if not data.startswith(header) or len(data) != len(header) + 640 * 480 * 3:
        raise ValueError("expected a complete 640x480 RGB capture from board_vga_tb")
    pixels = data[len(header):]

    def chunk(kind, payload):
        return (struct.pack(">I",len(payload)) + kind + payload +
                struct.pack(">I",zlib.crc32(kind+payload) & 0xffffffff))

    scanlines = b"".join(b"\0" + pixels[y*1920:(y+1)*1920] for y in range(480))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR",struct.pack(">IIBBBBB",640,480,8,2,0,0,0)) +
            chunk(b"IDAT",zlib.compress(scanlines,9)) + chunk(b"IEND",b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source",type=Path)
    parser.add_argument("target",type=Path)
    args = parser.parse_args()
    try:
        image = convert(args.source.read_bytes())
        args.target.write_bytes(image)
    except (ValueError,OSError) as exc:
        print(f"vga_preview: {exc}",file=sys.stderr)
        return 1
    print(f"Saved simulated VGA output: {args.target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
