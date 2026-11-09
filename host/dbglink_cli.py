#!/usr/bin/env python3
"""Talk to the FPGA debug endpoint over a serial port, or to the in-process model with --sim.

    python3 host/dbglink_cli.py --sim hello status ping soak
    python3 host/dbglink_cli.py --port COM10 hello status

Commands run in order in one session. --script accepts a JSON command list with
per-command parameters. Advanced commands require FPGA capabilities; --sim is
the T2 BASE_STATUS model and does not pretend to execute CPU instructions.
Needs pyserial for --port. See host/README.md for load/step/BIST examples.
"""
import argparse
import os
import json
from pathlib import Path
import sys
import time

from dbglink import (CAPABILITY, Debugger, DebugDevice, FrameError, LinkError, StreamDecoder,
                     ProgramImage, wire_frame)
from dbglink.schema import CPU_STATE, OPERATION_STATE, SESSION_STATE


class SimTransport:
    """Loops requests through DebugDevice; replies are read back like a UART."""

    def __init__(self):
        self.dev, self.rx, self.pending = DebugDevice(), StreamDecoder(), b""

    def write(self, data):
        now = int(time.monotonic() * 1000)
        for item in self.rx.feed(data, now):
            if not isinstance(item, FrameError) and (reply := self.dev.handle(item, now)):
                self.pending += wire_frame(reply)

    def read(self, n, timeout_s):
        data, self.pending = self.pending[:n], self.pending[n:]
        return data


class SerialTransport:
    def __init__(self, port, baud):
        import serial  # pyserial, see scripts/requirements-host.txt
        self.port = serial.Serial(port, baud, timeout=0)

    def write(self, data):
        if self.port.write(data) != len(data):
            raise LinkError("incomplete serial write")

    def read(self, n, timeout_s):
        self.port.timeout = max(timeout_s, 0.001)
        first = self.port.read(1)
        self.port.timeout = 0
        return first + self.port.read(min(n - len(first), self.port.in_waiting))

    def close(self):
        self.port.close()


def show(title, fields, names=None):
    print(title)
    for k, v in fields.items():
        if k.startswith("reserved"):
            continue
        hexy = any(t in k for t in ("_id", "pc", "flags", "capabilities", "supported"))
        label = names[k].name(v) if names and k in names else (f"0x{v:X}" if hexy else v)
        print(f"  {k:28} {label}")


COMMANDS = ("hello", "status", "ping", "soak", "halt", "resume", "step", "reset", "regs", "reg-write",
            "mem-read", "mem-write", "load", "run", "restart", "break-set", "break-clear", "break-list",
            "counters", "trace-arm", "trace", "bist-memory", "bist-alu", "bist-abort", "op-result",
            "inject-arm", "inject-fire", "inject-clear", "inject-result")


def action(client, cmd, p, context):
    """Small explicit command vocabulary; batch files contain data, never executable Python."""
    if cmd == "regs": return client.registers(p.get("start", 0), p.get("count", 32))
    if cmd == "reg-write": return client.write_register(p["index"], p["value"])
    if cmd == "mem-read": return {"address": p["address"], "hex": client.read_memory(p["address"], p.get("length", 64), p.get("size", 1)).hex()}
    if cmd == "mem-write": return client.write_memory(p["address"], bytes.fromhex(p["hex_bytes"]), p.get("size", 1))
    if cmd == "break-set": client.set_breakpoint(p["address"], p.get("slot", 0)); return {"set": p["address"]}
    if cmd == "break-clear": client.clear_breakpoint(p.get("slot", 0)); return {"cleared": p.get("slot", 0)}
    if cmd == "break-list": return client.breakpoints()
    if cmd == "counters": return client.counters()
    if cmd == "trace-arm": return {"generation": client.arm_trace(), "cleared": True}
    if cmd == "trace": return client.trace()
    if cmd == "load":
        image = ProgramImage.from_manifest(p["manifest"])
        client.halt()
        result = client.load(image)
        context["image_id"] = result["image_id"]
        return result
    if cmd in ("run", "restart"):
        return client.run(p.get("image_id", context.get("image_id")), restart=cmd == "restart")
    if cmd in ("halt", "resume", "step", "reset"): return getattr(client, cmd)()
    if cmd in ("bist-memory", "bist-alu"):
        return client.bist("alu" if cmd == "bist-alu" else "memory", p.get("address", 0xD000), p.get("length", 4096))
    if cmd == "bist-abort":
        r = client.abort_bist(p["operation_id"]); return {"status": r.status}
    if cmd == "op-result": return client.operation_result(p["operation_id"])
    if cmd == "inject-arm":
        context["arm_id"] = client.arm_injection(p["address"], p["value"])
        return {"arm_id": context["arm_id"], "fired": False}
    if cmd == "inject-result": return client.injection_result(p.get("arm_id", context.get("arm_id", 0)))
    if cmd in ("inject-fire", "inject-clear"):
        arm_id = p.get("arm_id", context.get("arm_id"))
        if arm_id is None: raise ValueError("supply --arm-id, or inject-arm earlier in this session")
        r = client.fire_injection(arm_id) if cmd == "inject-fire" else client.clear_injection(arm_id)
        return {"arm_id": arm_id, "status": r.status}
    raise ValueError(f"unknown action {cmd}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--port")
    src.add_argument("--sim", action="store_true")
    src.add_argument("--rtl-sim", action="store_true", help="Linux/WSL: drive the actual FPGA RTL through Verilator")
    ap.add_argument("--baud", type=int, default=115200)
    number = lambda value: int(value, 0)
    ap.add_argument("--manifest", help="build_software.py JSON; matching .bin is validated before loading")
    ap.add_argument("--script", type=Path, help='JSON list, for example [{"command":"halt"},{"command":"regs"}]')
    ap.add_argument("--address", type=number, default=0xD000)
    ap.add_argument("--length", type=number)
    ap.add_argument("--size", type=int, choices=(1, 2, 4), default=1)
    ap.add_argument("--index", type=int, default=1)
    ap.add_argument("--value", type=number, default=0)
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--image-id", type=number)
    ap.add_argument("--operation-id", type=number)
    ap.add_argument("--arm-id", type=number)
    ap.add_argument("--hex-bytes")
    ap.add_argument("commands", nargs="*", choices=COMMANDS)
    args = ap.parse_args()
    entries = [{"command": cmd} for cmd in args.commands]
    if args.script:
        try:
            batch=json.loads(args.script.read_text(encoding="utf-8"))
            if not isinstance(batch,list): raise ValueError("script must contain a JSON list")
            entries.extend(batch)
        except (ValueError,OSError) as err:
            ap.error(str(err))
    if not entries or any(not isinstance(e, dict) or e.get("command") not in COMMANDS for e in entries):
        ap.error("provide commands or a JSON list of supported commands")
    parameters={"address","length","size","index","value","slot","image_id","operation_id","arm_id",
                "hex_bytes","manifest","start","count"}
    if any(set(e)-parameters-{"command"} for e in entries):
        ap.error("unknown script parameter; use the documented command field names")
    integers=parameters-{"manifest","hex_bytes"}
    if any(type(v) is not int for e in entries for k,v in e.items() if k in integers):
        ap.error("script numeric parameters must be JSON integers (use decimal values)")
    if any(not isinstance(v,str) for e in entries for k,v in e.items() if k in {"manifest","hex_bytes"}):
        ap.error("script manifest and hex_bytes parameters must be strings")
    defaults = {k: v for k, v in vars(args).items() if v is not None}
    transport = None
    names = {"cpu_state": CPU_STATE, "operation_state": OPERATION_STATE,
             "session_state": SESSION_STATE}
    try:
        if args.rtl_sim:
            from dbglink.rtl_transport import RtlTransport
            print("SIMULATED FPGA: actual Verilator RTL; no physical board or real-time timing claim")
            transport=RtlTransport()
        else:
            transport = SimTransport() if args.sim else SerialTransport(args.port, args.baud)
        if args.sim: print("SIMULATED TRANSPORT: T2 protocol model; no CPU execution")
        client = Debugger(transport)
        context = {}
        for entry in entries:
            cmd = entry["command"]
            if cmd != "hello" and not client.session_id:
                client.connect()
            if cmd == "hello":
                show("discovery", client.discover(), names)
                d = client.connect(int.from_bytes(os.urandom(8), "little") | 1)
                caps = [n for n, bit in vars(CAPABILITY).items()
                        if not n.startswith("_") and d["capabilities"] >> bit & 1]
                print(f"session 0x{client.session_id:016X} claimed; capabilities: "
                      f"{', '.join(caps) or 'none'}")
            elif cmd == "status":
                show("status", client.status(), names)
            elif cmd == "ping":
                t = time.perf_counter()
                client.ping(b"ping")
                print(f"ping ok, {1000 * (time.perf_counter() - t):.1f} ms")
            elif cmd == "soak":
                t = time.perf_counter()
                for i in range(200):
                    client.ping(bytes([i & 0xFF]) * (i % 33))
                dt = time.perf_counter() - t
                print(f"soak: 200 pings in {dt:.2f} s, stats {client.stats}")
            else:
                result = action(client, cmd, {**defaults, **entry}, context)
                print(cmd + ": " + json.dumps(result, sort_keys=True))
    except (LinkError, ValueError, KeyError, OSError) as err:
        print(f"link error: {err}", file=sys.stderr)
        return 1
    finally:
        if transport is not None and hasattr(transport, "close"):
            transport.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
