#!/usr/bin/env python3
"""Check the real board's greeting, increasing counter and exact UART echo.

Windows: build/host-venv/Scripts/python.exe scripts/uart_check.py COM8
Open this before programming, or press the centre button after 'Listening'.
Close PuTTY/Tera Term first: only one application may own the COM port.
Requires pyserial from requirements-host.txt; parser tests use no dependencies.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import re
import sys
import time

BANNER = b"hello, world\r\n"
COUNTER = re.compile(rb"\r\ncounter: ([0-9]{1,10})\r\n")
COUNTER_PREFIX = b"\r\ncounter: "
DEFAULT_MESSAGE = b"RISC-V UART echo: 0123456789 ABC xyz !?\r\n"


class CheckError(RuntimeError):
    pass


@dataclass
class CounterSample:
    value: int
    observed_at_seconds: float


def possible_counter_suffix(data: bytes) -> bytes:
    """Hold a fragmented counter record until it can be parsed, without
    confusing that fragment with a corrupt echo byte."""
    match = re.search(rb"\r\ncounter: [0-9]{0,10}\r?$", data)
    if match:
        return data[:match.start()]
    for size in range(min(len(data), len(COUNTER_PREFIX) - 1), 0, -1):
        if data.endswith(COUNTER_PREFIX[:size]):
            return data[:-size]
    return data


class ConsoleProbe:
    def __init__(self, port, *, clock=time.monotonic, capture_limit=65536):
        self.port, self.clock, self.capture_limit = port, clock, capture_limit
        self.started = clock()
        self.capture = bytearray()
        self.counters: list[CounterSample] = []
        self.counter_origin = 0
        self.track_counters = False

    def pump(self, deadline: float):
        if self.clock() >= deadline:
            raise CheckError("timeout waiting for board output")
        data = self.port.read(512)  # port timeout is bounded to 50 ms
        if len(self.capture) + len(data) > self.capture_limit:
            raise CheckError("board output exceeded the bounded capture limit")
        self.capture.extend(data)
        if not self.track_counters:
            return
        matches = list(COUNTER.finditer(self.capture[self.counter_origin:]))
        for match in matches[len(self.counters):]:
            value = int(match[1])
            if value > 0xffffffff:
                raise CheckError("counter exceeds the 32-bit software contract")
            if self.counters and value != ((self.counters[-1].value + 1) & 0xffffffff):
                raise CheckError("counter did not increase by one (or board reset during the check)")
            self.counters.append(CounterSample(value, self.clock() - self.started))

    def wait_for_startup(self, timeout: float):
        deadline = self.clock() + timeout
        while BANNER not in self.capture:
            self.pump(deadline)
        # A terminal may have been opened while older firmware was running.
        # Only the boot after this greeting belongs to the test session.
        self.counter_origin = bytes(self.capture).index(BANNER) + len(BANNER)
        self.counters.clear()

    def wait_for_counters(self, timeout: float):
        self.track_counters = True
        deadline = self.clock() + timeout
        while len(self.counters) < 2:
            self.pump(deadline)

    def check_echo(self, payload: bytes, timeout: float, quiet_seconds=0.15):
        if not payload:
            raise ValueError("echo payload must not be empty")
        self.track_counters = True
        start = len(self.capture)
        if self.port.write(payload) != len(payload):
            raise CheckError("short serial write; test was not retried")
        deadline = self.clock() + timeout
        complete_at = None
        while True:
            received = COUNTER.sub(b"", bytes(self.capture[start:]))
            if received == payload:
                if complete_at is None:
                    complete_at = self.clock()
                if self.clock() - complete_at >= quiet_seconds:
                    return
            elif not payload.startswith(received):
                prefix = possible_counter_suffix(received)
                if not payload.startswith(prefix):
                    raise CheckError(f"echo mismatch: expected {payload!r}, received {received!r}")
            self.pump(deadline)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("port", help="explicit COM port, for example COM8")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=10, help="counter/echo timeout in seconds")
    parser.add_argument("--startup-timeout", type=float, default=30, help="time to program/reset the board after listening")
    parser.add_argument("--all-bytes", action="store_true", help="also check binary values 0..255")
    parser.add_argument("--report", type=Path, help="optional JSON evidence, normally under build/phase4/")
    parser.add_argument("--capture", type=Path, help="optional raw received bytes")
    args = parser.parse_args()
    if args.baud <= 0 or not all(0 < t < float("inf") for t in (args.timeout, args.startup_timeout)):
        parser.error("baud and timeouts must be positive and finite")
    # Never leave a previous PASS report looking like this attempt's result.
    # An interrupted run, missing dependency or port-open failure stays failed.
    if args.report:
        try:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps({"passed": False, "port": args.port,
                                              "status": "check not completed"}, indent=2) + "\n", encoding="utf-8")
        except OSError as exc:
            print(f"FAIL: cannot prepare evidence report: {exc}", file=sys.stderr)
            return 1
    try:
        import serial
    except ImportError:
        print("Install the host dependency: python -m pip install -r scripts/requirements-host.txt", file=sys.stderr)
        return 2
    probe = None
    try:
        with serial.Serial(args.port, args.baud, bytesize=8, parity="N", stopbits=1,
                           timeout=0.05, write_timeout=2, xonxoff=False, rtscts=False, dsrdtr=False) as port:
            probe = ConsoleProbe(port)
            print(f"Listening on {args.port}: {args.baud} 8N1, no flow control. Program or reset the board now.", flush=True)
            probe.wait_for_startup(args.startup_timeout)
            print("Received: hello, world", flush=True)
            probe.wait_for_counters(args.timeout)
            first, second = probe.counters[:2]
            print(f"Live counter: {first.value} -> {second.value} ({second.observed_at_seconds - first.observed_at_seconds:.3f} s observed interval)", flush=True)
            probe.check_echo(DEFAULT_MESSAGE, args.timeout)
            print(f"Text echo: {len(DEFAULT_MESSAGE)}/{len(DEFAULT_MESSAGE)} bytes match", flush=True)
            binary_bytes = 0
            if args.all_bytes:
                probe.check_echo(bytes(range(256)), args.timeout)
                binary_bytes = 256
                print("Binary echo: all 256 byte values match", flush=True)
            report = {"passed": True, "port": args.port, "baud": args.baud, "format": "8N1",
                      "greeting": "hello, world", "counters": [asdict(c) for c in probe.counters],
                      "text_echo_bytes": len(DEFAULT_MESSAGE), "binary_echo_bytes": binary_bytes,
                      "elapsed_seconds": probe.clock() - probe.started}
            if args.report:
                args.report.parent.mkdir(parents=True, exist_ok=True)
                args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            print("PASS: board greeting, live counter and exact UART echo", flush=True)
            return 0
    except (CheckError, OSError, serial.SerialException) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        print("Close other serial terminals; check the COM port/115200 baud, and press the centre button after listening starts.", file=sys.stderr)
        return 1
    finally:
        if args.capture and probe is not None:
            args.capture.parent.mkdir(parents=True, exist_ok=True)
            args.capture.write_bytes(probe.capture)


if __name__ == "__main__":
    sys.exit(main())
