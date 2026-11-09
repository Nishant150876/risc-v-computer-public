"""Typed commands for the single-cycle FPGA debug profile.

No CPU execution is simulated here. The T2 --sim device still advertises only
BASE_STATUS. Mutations require negotiated capabilities and use Client's exact
wire retries. A lost terminal reply blocks further mutations until reconciled.
"""
import struct
import time

from .client import Client, DeviceError, LinkError, OutcomeUnknown, SessionLost
from .program import ProgramImage
from .schema import CAPABILITY, LIMITS, OPCODE, STATUS, STATUS_RESPONSE, Layout, OPERATION_STATE

L = {name: Layout(name) for name in (
    "REG_READ_REQUEST", "REG_WRITE_REQUEST", "REG_READ_RESPONSE", "REG_WRITE_RESPONSE",
    "MEM_REQUEST", "MEM_READ_RESPONSE", "MEM_WRITE_RESPONSE", "BREAK_SET_REQUEST", "BREAK_CLEAR_REQUEST",
    "LOAD_BEGIN_FIXED", "LOAD_CHUNK_FIXED", "LOAD_PROGRESS", "LOAD_RESULT", "OPERATION_REQUEST",
    "IMAGE_REQUEST", "CAPTURE_READ_REQUEST", "CAPTURE_READ_RESPONSE", "COUNTERS_RESPONSE",
    "TRACE_DESCRIPTOR", "TRACE_RECORD", "BIST_REQUEST", "BIST_RESULT", "INJECT_ARM_REQUEST",
    "INJECT_REQUEST", "INJECT_RESULT")}


class CapabilityError(LinkError):
    pass


class OperationFailed(LinkError):
    def __init__(self, result):
        self.result = result
        super().__init__(f"operation {result['operation_id']}: {STATUS.name(result['status'])}")


class Debugger(Client):
    READ_ONLY = {OPCODE.HELLO, OPCODE.PING, OPCODE.STATUS, OPCODE.REG_READ, OPCODE.MEM_READ,
                 OPCODE.BREAK_LIST, OPCODE.COUNTERS_READ, OPCODE.TRACE_READ, OPCODE.SNAP_READ,
                 OPCODE.DIAG_RESULT, OPCODE.INJECT_RESULT, OPCODE.CONSOLE_READ, OPCODE.CONSOLE_STATUS}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.descriptor = None
        self.uncertain_opcode = None

    def connect(self, session_id=None):
        self.descriptor = super().connect(session_id)
        return self.descriptor

    def require(self, capability):
        if not self.session_id or self.descriptor is None:
            raise SessionLost("connect and negotiate capabilities first")
        if not self.descriptor["capabilities"] & (1 << getattr(CAPABILITY, capability)):
            raise CapabilityError(f"device does not advertise {capability}")

    def request(self, opcode, *args, **kwargs):
        mutation = opcode not in self.READ_ONLY
        if mutation and self.uncertain_opcode is not None:
            raise OutcomeUnknown("previous mutation has an uncertain outcome; inspect STATUS/results before explicitly acknowledging it")
        try:
            reply = super().request(opcode, *args, **kwargs)
        except OutcomeUnknown:
            if mutation:
                self.uncertain_opcode = opcode
            raise
        except DeviceError as error:
            if not mutation or error.frame.status != STATUS.OUTCOME_UNKNOWN:
                raise
            reply = error.frame
        if mutation and reply.status == STATUS.OUTCOME_UNKNOWN:
            self.uncertain_opcode = opcode
            error = OutcomeUnknown(f"{OPCODE.name(opcode)}: device reports uncertain completion; reconcile before another mutation")
            error.frame = reply  # Preserve the device's partial-completion evidence.
            raise error
        return reply

    def acknowledge_uncertain(self):
        """Explicit caller acknowledgement after reconciling actual device state; never retries."""
        self.uncertain_opcode = None

    def _control(self, opcode):
        self.require("STEP" if opcode == OPCODE.STEP else "HALT_RESUME")
        frame = self.request(opcode)
        if frame.status == STATUS.ACCEPTED:
            return {"operation_id": L["OPERATION_REQUEST"].unpack(frame.payload)["operation_id"], "accepted": True}
        return STATUS_RESPONSE.unpack(frame.payload)

    def halt(self): return self._control(OPCODE.HALT)
    def resume(self): return self._control(OPCODE.RESUME)
    def step(self): return self._control(OPCODE.STEP)
    def reset(self): return self._control(OPCODE.CPU_RESET)

    def registers(self, start=0, count=32):
        self.require("REG_ACCESS")
        if not 0 <= start < 32 or not 1 <= count <= 32 - start:
            raise ValueError("register range must fit x0..x31")
        frame = self.request(OPCODE.REG_READ, L["REG_READ_REQUEST"].pack(start=start, count=count))
        header = L["REG_READ_RESPONSE"].unpack(frame.payload[:8])
        if header["start"] != start or header["count"] != count or len(frame.payload) != 8 + count * 4:
            raise LinkError("REG_READ response range/length mismatch")
        return {**header, "values": list(struct.unpack(f"<{count}I", frame.payload[8:]))}

    def write_register(self, index, value):
        self.require("REG_ACCESS")
        if not 1 <= index < 32 or not 0 <= value <= 0xFFFFFFFF:
            raise ValueError("write x1..x31 with a 32-bit unsigned value; x0 is immutable")
        response = self.request(OPCODE.REG_WRITE, L["REG_WRITE_REQUEST"].pack(index=index, value=value))
        result = L["REG_WRITE_RESPONSE"].unpack(response.payload)
        if result["value"] != value:
            raise LinkError("register write readback mismatch")
        return result

    @staticmethod
    def _memory_range(address, length, size):
        if size not in (1, 2, 4) or not length or length % size or address % size:
            raise ValueError("memory size/alignment/length must use 1, 2 or 4-byte elements")
        if address < 0 or length < 0 or address + length > 0x10000:
            raise ValueError("typed memory commands address only the 64-KiB RAM")

    def read_memory(self, address, length, size=1):
        self.require("RAM_ACCESS")
        self._memory_range(address, length, size)
        output = bytearray()
        while len(output) < length:
            n = min(LIMITS.max_mem_data, length - len(output))
            frame = self.request(OPCODE.MEM_READ, L["MEM_REQUEST"].pack(
                address=address + len(output), size=size, flags=0, count=n // size))
            h = L["MEM_READ_RESPONSE"].unpack(frame.payload[:8])
            if h["completed"] != n // size or h["size"] != size or len(frame.payload) != n + 8:
                raise LinkError("RAM read range/length mismatch")
            output.extend(frame.payload[8:])
        return bytes(output)

    def write_memory(self, address, data, size=1):
        self.require("RAM_ACCESS")
        data = bytes(data)
        self._memory_range(address, len(data), size)
        for offset in range(0, len(data), LIMITS.max_mem_data):
            chunk = data[offset:offset + LIMITS.max_mem_data]
            frame = self.request(OPCODE.MEM_WRITE, L["MEM_REQUEST"].pack(
                address=address + offset, size=size, flags=0, count=len(chunk) // size) + chunk)
            result = L["MEM_WRITE_RESPONSE"].unpack(frame.payload)
            if result["completed"] != len(chunk) // size or result["size"] != size or result["outcome_unknown"]:
                raise LinkError("RAM write did not verify every element")
        return {"written": len(data), "verified_by_fpga_readback": True}

    def set_breakpoint(self, pc, slot=0, enabled=True):
        self.require("BREAKPOINTS")
        if not 0 <= slot < self.descriptor["breakpoint_count"] or pc % 4 or not 0 <= pc < 0x10000:
            raise ValueError("breakpoint slot/PC is outside this device")
        self.request(OPCODE.BREAK_SET, L["BREAK_SET_REQUEST"].pack(slot=slot, enabled=int(enabled), pc=pc))

    def clear_breakpoint(self, slot=0):
        self.require("BREAKPOINTS")
        if not 0 <= slot < self.descriptor["breakpoint_count"]:
            raise ValueError("invalid breakpoint slot")
        self.request(OPCODE.BREAK_CLEAR, L["BREAK_CLEAR_REQUEST"].pack(slot=slot))

    def breakpoints(self):
        self.require("BREAKPOINTS")
        p = self.request(OPCODE.BREAK_LIST).payload
        if len(p) < 12 or len(p) != 12 + 8 * p[9]:
            raise LinkError("invalid breakpoint descriptor")
        return {"generation": int.from_bytes(p[:4], "little"), "next_pc": int.from_bytes(p[4:8], "little"),
                "triggered_slot": None if p[8] == 255 else p[8],
                "slots": [{"enabled": bool(p[12 + i * 8]), "pc": int.from_bytes(p[16 + i * 8:20 + i * 8], "little")}
                          for i in range(p[9])]}

    def counters(self):
        self.require("PERF64")
        result = L["COUNTERS_RESPONSE"].unpack(self.request(OPCODE.COUNTERS_LATCH).payload)
        if (result["definition_version"], result["width"], result["count"]) != (1, 64, 6):
            raise LinkError("unsupported counter event definition")
        return result

    def arm_trace(self):
        self.require("RETIRE_TRACE")
        return int.from_bytes(self.request(OPCODE.TRACE_ARM, struct.pack("<I", 1)).payload, "little")

    def trace(self):
        self.require("RETIRE_TRACE")
        descriptor = L["TRACE_DESCRIPTOR"].unpack(self.request(OPCODE.TRACE_FREEZE).payload)
        if descriptor["format"] != 1 or descriptor["record_bytes"] != 32 or not descriptor["flags"] & 1:
            raise LinkError("unsupported or unfrozen trace descriptor")
        records = []
        for offset in range(0, descriptor["count"], 6):
            count = min(6, descriptor["count"] - offset)
            response = self.request(OPCODE.TRACE_READ, L["CAPTURE_READ_REQUEST"].pack(
                generation=descriptor["generation"], offset=offset, count=count)).payload
            h = L["CAPTURE_READ_RESPONSE"].unpack(response[:12])
            if (h["generation"], h["offset"], h["count"], h["record_bytes"], len(response)) != (
                    descriptor["generation"], offset, count, 32, 12 + count * 32):
                raise LinkError("trace range/generation mismatch; comparison is inconclusive")
            for i in range(count):
                record = L["TRACE_RECORD"].unpack(response[12 + 32 * i:44 + 32 * i])
                order = descriptor["first_order"] + len(records)
                if record["order_low"] != (order & 0xFFFFFFFF):
                    raise LinkError("trace sequence gap; comparison is inconclusive")
                records.append({**record, "order": order})
        return {"provenance": "CAPTURED", "descriptor": descriptor,
                "complete_history": descriptor["overwritten"] == 0, "records": records}

    def operation_result(self, operation_id):
        p = self.request(OPCODE.DIAG_RESULT, L["OPERATION_REQUEST"].pack(operation_id=operation_id)).payload
        if len(p) < 12 or p[8] not in (1, 2, 3):
            raise LinkError("unknown operation result kind")
        return L["LOAD_RESULT" if p[8] == 1 else "BIST_RESULT"].unpack(p)

    def wait_operation(self, operation_id, timeout=15, poll_seconds=0.02):
        deadline = self.clock() + timeout
        while self.clock() < deadline:
            s = self.status()  # also renews the lease; no mutation is reissued
            if s["operation_id"] != operation_id:
                raise LinkError("operation changed/reset; reconcile before any further mutation")
            if s["operation_state"] in (OPERATION_STATE.DONE, OPERATION_STATE.FAILED):
                return self.operation_result(operation_id)
            time.sleep(poll_seconds)
        raise OutcomeUnknown(f"operation {operation_id} still pending; poll STATUS/DIAG_RESULT, do not restart it blindly")

    def load(self, image: ProgramImage):
        if not isinstance(image, ProgramImage):
            raise TypeError("load requires a validated ProgramImage")
        self.require("LOADER")
        chunk_size = min(LIMITS.max_chunk, self.descriptor["max_chunk"])
        if not 1 <= chunk_size <= LIMITS.max_chunk:
            raise LinkError("invalid negotiated loader chunk size")
        name = image.name.encode("utf-8")
        begin = L["LOAD_BEGIN_FIXED"].pack(address=0, entry=0, image_bytes=len(image.data), crc32=image.crc32,
            bss_address=image.bss_address, bss_bytes=image.bss_bytes, stack_bottom=0xE000, stack_top=0x10000,
            isa=1, abi=1, flags=0, name_bytes=len(name)) + name
        response = self.request(OPCODE.LOAD_BEGIN, begin)
        if len(response.payload) != 4:
            raise LinkError("invalid LOAD_BEGIN id")
        image_id = int.from_bytes(response.payload, "little")
        for offset in range(0, len(image.data), chunk_size):
            chunk = image.data[offset:offset + chunk_size]
            response = self.request(OPCODE.LOAD_CHUNK, L["LOAD_CHUNK_FIXED"].pack(
                load_id=image_id, offset=offset, count=len(chunk)) + chunk)
            progress = L["LOAD_PROGRESS"].unpack(response.payload)
            if progress != {"load_id": image_id, "received": offset + len(chunk)}:
                raise LinkError("loader did not acknowledge verified ordered progress")
        response = self.request(OPCODE.LOAD_COMMIT, L["IMAGE_REQUEST"].pack(image_id=image_id))
        if response.status != STATUS.ACCEPTED:
            raise LinkError("LOAD_COMMIT did not return an asynchronous operation")
        operation_id = L["OPERATION_REQUEST"].unpack(response.payload)["operation_id"]
        result = self.wait_operation(operation_id)
        if result["status"] != STATUS.OK:
            raise OperationFailed(result)
        if result["image_id"] != image_id or result["observed_crc"] != image.crc32 or result["completed"] != len(image.data):
            raise LinkError("actual RAM verification result does not match the image")
        return result

    def run(self, image_id=None, restart=False):
        self.require("LOADER")
        if image_id is None:
            s = self.status()
            if not s["valid"] & 4:
                raise LinkError("device has no verified image")
            image_id = s["image_id"]
        response = self.request(OPCODE.RESTART if restart else OPCODE.RUN,
                                L["IMAGE_REQUEST"].pack(image_id=image_id))
        return STATUS_RESPONSE.unpack(response.payload)

    def bist(self, test="memory", address=0xD000, length=4096):
        if test not in ("memory", "alu"):
            raise ValueError("BIST test must be memory or alu")
        self.require("MEM_BIST" if test == "memory" else "ALU_BIST")
        if test == "alu": address, length = 0, 0
        elif address % 4 or length % 4 or not 0xD000 <= address < address + length <= 0xE000:
            raise ValueError("memory BIST is confined to aligned reserved scratch")
        response = self.request(OPCODE.BIST_START, L["BIST_REQUEST"].pack(
            test_id=1 if test == "memory" else 2, address=address, bytes=length))
        return self.wait_operation(L["OPERATION_REQUEST"].unpack(response.payload)["operation_id"])

    def abort_bist(self, operation_id):
        return self.request(OPCODE.BIST_ABORT, L["OPERATION_REQUEST"].pack(operation_id=operation_id))

    def arm_injection(self, address, mask):
        self.require("FAULT_INJECT")
        if address % 4 or not 0xD000 <= address <= 0xDFFC or not 0 < mask <= 0xFFFFFFFF:
            raise ValueError("read XOR is confined to one aligned scratch word and a nonzero 32-bit mask")
        p = L["INJECT_ARM_REQUEST"].pack(kind=1, trigger=1, duration=1, address=address, mask=mask, flags=0)
        return int.from_bytes(self.request(OPCODE.INJECT_ARM, p).payload, "little")

    def fire_injection(self, arm_id):
        self.require("FAULT_INJECT")
        return self.request(OPCODE.INJECT_FIRE, L["INJECT_REQUEST"].pack(arm_id=arm_id))

    def clear_injection(self, arm_id):
        self.require("FAULT_INJECT")
        return self.request(OPCODE.INJECT_CLEAR, L["INJECT_REQUEST"].pack(arm_id=arm_id))

    def injection_result(self, arm_id=0):
        self.require("FAULT_INJECT")
        return L["INJECT_RESULT"].unpack(self.request(OPCODE.INJECT_RESULT, L["INJECT_REQUEST"].pack(arm_id=arm_id)).payload)
