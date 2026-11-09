#!/usr/bin/env python3
"""Check the Phase 7 board sieve at 115200 8N1 (Windows, pyserial).

Start this before loading the primes bitstream, or press CPU reset after
Listening. Close other terminals first. It never programs or resets the board.
Offline: --capture-file <raw.bin> validates a saved capture without serial.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
import time

BANNER = b"primes <= 10000\r\n"
PERFORMANCE = re.compile(rb"cycles ([0-9]{1,10}) instret ([0-9]{1,10}) CPI ([0-9]{1,10})\.([0-9]{3})\r\n")
CAPTURE_LIMIT = 16384


def expected_output() -> bytes:
    # Independent trial division, rather than the C sieve or a changed fixture.
    primes = [n for n in range(2,10001) if all(n%d for d in range(2,int(n**0.5)+1))]
    lines = ["primes <= 10000"]
    lines += [" ".join(map(str,primes[i:i+16])) for i in range(0,len(primes),16)]
    return ("\r\n".join([*lines,"count 1229",""])).encode("ascii")


def validate(data: bytes) -> dict:
    if len(data) > CAPTURE_LIMIT: raise ValueError("capture exceeds 16384-byte bound")
    start = data.find(BANNER)
    if start < 0: raise ValueError("missing sieve banner")
    output = data[start:]
    fixed = expected_output()
    if not output.startswith(fixed): raise ValueError("prime output mismatch or incomplete capture")
    match = PERFORMANCE.fullmatch(output[len(fixed):])
    if not match: raise ValueError("missing, malformed or extra performance output")
    cycles,instructions,whole,fraction = map(int,match.groups())
    if not (0 < instructions <= cycles <= 0xffffffff): raise ValueError("invalid cycle/instruction counts")
    milli = (cycles*1000+instructions//2)//instructions
    if whole*1000+fraction != milli: raise ValueError("CPI does not match the measured counters")
    return {"passed":True,"prime_count":1229,"cycles":cycles,"instret":instructions,
            "cpi_milli":milli,"output_bytes":len(output)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--port",help="explicit Windows serial port, e.g. COM8")
    source.add_argument("--capture-file",type=Path,help="validate an existing raw capture offline")
    parser.add_argument("--timeout",type=float,default=30,help="seconds to program/reset and finish output")
    parser.add_argument("--report",type=Path,help="optional JSON evidence; normally under build/phase7/")
    parser.add_argument("--save-capture",type=Path)
    args = parser.parse_args()
    if not 0 < args.timeout < float("inf"): parser.error("timeout must be positive and finite")
    report = {"passed":False,"source":args.port or str(args.capture_file),"status":"check not completed"}
    capture = bytearray()
    save_failed = False
    try:
        # A failure or interruption cannot leave a previous PASS looking fresh.
        if args.report:
            args.report.parent.mkdir(parents=True,exist_ok=True)
            args.report.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        if args.capture_file:
            if args.capture_file.stat().st_size > CAPTURE_LIMIT: raise ValueError("capture too large")
            capture.extend(args.capture_file.read_bytes())
        else:
            import serial
            with serial.Serial(args.port,115200,bytesize=8,parity="N",stopbits=1,timeout=0.05,
                               xonxoff=False,rtscts=False,dsrdtr=False) as port:
                port.reset_input_buffer()
                print("Listening at 115200 8N1; now load primes or press the center CPU-reset button.",flush=True)
                deadline = time.monotonic()+args.timeout
                while True:
                    if time.monotonic() >= deadline: raise ValueError("timeout waiting for complete sieve output")
                    capture.extend(port.read(512))
                    if len(capture) > CAPTURE_LIMIT: raise ValueError("capture exceeds bound")
                    if PERFORMANCE.search(capture): break
        report.update(validate(bytes(capture)))
        report.pop("status",None)
        print(f"PASS: 1229 exact primes; cycles={report['cycles']} instret={report['instret']} CPI={report['cpi_milli']/1000:.3f}")
    except (ImportError,OSError,ValueError) as exc:
        report["status"] = str(exc)
        print(f"FAIL: {exc}",file=sys.stderr)
        if isinstance(exc,ImportError): print("Install scripts/requirements-host.txt in your Windows Python environment.",file=sys.stderr)
    finally:
        try:
            if args.save_capture:
                args.save_capture.parent.mkdir(parents=True,exist_ok=True)
                args.save_capture.write_bytes(capture)
            if args.report: args.report.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        except OSError as exc:
            print(f"FAIL: cannot save evidence: {exc}",file=sys.stderr)
            save_failed = True
    return 0 if report["passed"] and not save_failed else 1


if __name__ == "__main__": sys.exit(main())
