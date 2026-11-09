"""Typed host workflow and failure tests; CPU execution is tested in SV, not mocked here."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dbglink import (CAPABILITY, Debugger, CapabilityError, DeviceError, Frame, KIND, LinkError,
                     OPCODE, OutcomeUnknown, ProgramImage, STATUS, STATUS_RESPONSE, StreamDecoder, wire_frame)
from dbglink.debugger import L, OperationFailed


def packed(layout, **fields):
    definition = L[layout] if layout in L else STATUS_RESPONSE
    values = {f: 0 for f in definition.fields}
    return definition.pack(**{**values, **fields})


class ScriptTransport:
    """A reply tape: validates payload bytes but contains no CPU/memory implementation."""
    def __init__(self, test, steps):
        self.test, self.steps, self.pending, self.requests = test, list(steps), b"", []
        self.decoder = StreamDecoder()
        self.now = 0.0

    def write(self, wire):
        self.requests.append(wire)
        frames = self.decoder.feed(wire, int(self.now * 1000))
        self.test.assertEqual(len(frames), 1)
        request = frames[0]
        self.test.assertTrue(self.steps, "unexpected extra command")
        op, payload, status, reply = self.steps.pop(0)
        self.test.assertEqual((request.opcode, request.payload), (op, payload))
        if reply is not None:
            self.pending += wire_frame(Frame(request.channel, KIND.RESPONSE, request.opcode, status,
                                              request.request_id, request.session_id, reply))

    def read(self, n, timeout):
        self.now += min(timeout, 0.001)
        data, self.pending = self.pending[:n], self.pending[n:]
        return data


class TypedCommands(unittest.TestCase):
    def client(self, steps):
        transport = ScriptTransport(self, steps)
        c = Debugger(transport, clock=lambda: transport.now, timeout_ms=2, retries=1)
        c.session_id = 7
        c.descriptor = {"capabilities": 0xFFFF, "breakpoint_count": 2, "max_chunk": 192, "trace_depth": 256}
        return c

    def test_capabilities_block_before_any_io(self):
        c = self.client([]); c.descriptor["capabilities"] = 1
        with self.assertRaises(CapabilityError): c.step()
        with self.assertRaises(CapabilityError): c.load(ProgramImage(b"1234", "x", 4, 0))
        self.assertEqual(c.transport.requests, [])

    def test_registers_and_x0_validation(self):
        c = self.client([(OPCODE.REG_READ, bytes.fromhex("01020000"), STATUS.OK,
            bytes.fromhex("090000000102000078563412efcdab90"))])
        self.assertEqual(c.registers(1, 2)["values"], [0x12345678, 0x90ABCDEF])
        with self.assertRaises(ValueError): c.write_register(0, 1)
        with self.assertRaises(ValueError): c.registers(31, 2)

    def test_register_write_requires_actual_readback_value(self):
        c = self.client([(OPCODE.REG_WRITE, bytes.fromhex("0200000007000000"), STATUS.OK,
                          packed("REG_WRITE_RESPONSE", generation=1, value=8))])
        with self.assertRaisesRegex(LinkError, "readback"): c.write_register(2, 7)

    def test_memory_chunking_and_byte_order(self):
        data = bytes(range(200)); steps = []
        for off, n in ((0, 192), (192, 8)):
            h = struct.pack("<IBBH", 0xD000 + off, 4, 0, n // 4)
            steps.append((OPCODE.MEM_WRITE, h + data[off:off+n], STATUS.OK,
                          packed("MEM_WRITE_RESPONSE", completed=n//4, size=4)))
        c = self.client(steps)
        self.assertEqual(c.write_memory(0xD000, data, 4)["written"], 200)
        self.assertFalse(c.transport.steps)

    def test_memory_preflight_and_failed_write_stop(self):
        c = self.client([])
        for address, data, size in ((0x80000000, b"1", 1), (0xFFFF, b"12", 1), (1, b"12", 2)):
            with self.assertRaises(ValueError): c.write_memory(address, data, size)
        c = self.client([(OPCODE.MEM_WRITE, struct.pack("<IBBH", 0, 1, 0, 192) + b"x"*192,
            STATUS.VERIFY_FAILED, packed("MEM_WRITE_RESPONSE", completed=2, size=1, address=2))])
        with self.assertRaises(DeviceError) as err: c.write_memory(0, b"x"*200)
        self.assertEqual(L["MEM_WRITE_RESPONSE"].unpack(err.exception.frame.payload)["completed"], 2)
        self.assertEqual(len(c.transport.requests), 1)

    def load_steps(self, data, observed=None):
        image = ProgramImage(data, "π", (len(data)+3)&~3, 8)
        header = L["LOAD_BEGIN_FIXED"].pack(address=0, entry=0, image_bytes=len(data), crc32=image.crc32,
            bss_address=image.bss_address, bss_bytes=8, stack_bottom=0xE000, stack_top=0x10000,
            isa=1, abi=1, flags=0, name_bytes=2)
        steps = [(OPCODE.LOAD_BEGIN, header + "π".encode(), STATUS.OK, struct.pack("<I", 11))]
        for off in range(0, len(data), 192):
            chunk = data[off:off+192]
            steps.append((OPCODE.LOAD_CHUNK, struct.pack("<IIHH", 11, off, len(chunk), 0)+chunk,
                          STATUS.OK, struct.pack("<II", 11, off+len(chunk))))
        steps += [(OPCODE.LOAD_COMMIT, struct.pack("<I", 11), STATUS.ACCEPTED, struct.pack("<Q", 3)),
                  (OPCODE.STATUS, b"", STATUS.OK, packed("STATUS_RESPONSE", operation_id=3, operation_state=6)),
                  (OPCODE.DIAG_RESULT, struct.pack("<Q", 3), STATUS.OK,
                   packed("LOAD_RESULT", operation_id=3, kind=1, state=6, completed=len(data),
                          expected_crc=image.crc32, observed_crc=image.crc32 if observed is None else observed, image_id=11))]
        return image, steps

    def test_ordered_loader_three_chunks_crc_then_no_implicit_run(self):
        image, steps = self.load_steps(b"abcd"*98)
        c = self.client(steps)
        self.assertEqual(c.load(image)["image_id"], 11)
        self.assertFalse(c.transport.steps)
        self.assertNotIn(OPCODE.RUN, [x.opcode for wire in c.transport.requests for x in StreamDecoder().feed(wire, 0)])

    def test_loader_rejects_mismatched_actual_crc(self):
        image, steps = self.load_steps(b"abcd", observed=0)
        with self.assertRaisesRegex(LinkError, "actual RAM"): self.client(steps).load(image)

    def test_loader_failed_operation_never_runs(self):
        image, steps = self.load_steps(b"abcd")
        op, p, status, result = steps[-1]
        fields = L["LOAD_RESULT"].unpack(result); fields["state"] = 7; fields["status"] = STATUS.VERIFY_FAILED
        steps[-1] = (op, p, status, L["LOAD_RESULT"].pack(**fields))
        with self.assertRaises(OperationFailed): self.client(steps).load(image)

    def test_invalid_chunk_descriptor_is_rejected_before_begin(self):
        c = self.client([]); c.descriptor["max_chunk"] = 0
        with self.assertRaises(LinkError): c.load(ProgramImage(b"1234", "x", 4, 0))
        self.assertFalse(c.transport.requests)

    def test_lost_mutation_retries_identical_then_requires_reconciliation(self):
        c = self.client([(OPCODE.STEP,b"",0,None), (OPCODE.STEP,b"",0,None),
                         (OPCODE.STATUS,b"",0,packed("STATUS_RESPONSE")),
                         (OPCODE.STEP,b"",0,packed("STATUS_RESPONSE"))])
        with self.assertRaises(OutcomeUnknown): c.step()
        self.assertEqual(c.transport.requests[0], c.transport.requests[1])
        with self.assertRaises(OutcomeUnknown): c.step()
        self.assertEqual(len(c.transport.requests), 2)
        c.status(); c.acknowledge_uncertain(); c.step()
        self.assertFalse(c.transport.steps)

    def test_counter_event_definition(self):
        c = self.client([(OPCODE.COUNTERS_LATCH,b"",0,packed("COUNTERS_RESPONSE",
            definition_version=1,width=64,count=6,generation=2,cycles=2**40,instructions=100,loads=9))])
        self.assertEqual(c.counters()["cycles"], 2**40)

    def test_device_unknown_write_completion_also_locks_mutations(self):
        evidence = packed("MEM_WRITE_RESPONSE", completed=1, size=1, address=1, outcome_unknown=1)
        for checked in (True, False):
            with self.subTest(check=checked):
                c = self.client([(OPCODE.MEM_WRITE, b"partial", STATUS.OUTCOME_UNKNOWN, evidence),
                                 (OPCODE.STATUS, b"", STATUS.OK, packed("STATUS_RESPONSE"))])
                with self.assertRaises(OutcomeUnknown) as error:
                    c.request(OPCODE.MEM_WRITE, b"partial", check=checked)
                self.assertEqual(error.exception.frame.payload, evidence)
                with self.assertRaises(OutcomeUnknown): c.step()
                c.status()
                self.assertFalse(c.transport.steps)

    def test_trace_overwritten_prefix_and_gap_are_explicit(self):
        desc = packed("TRACE_DESCRIPTOR", generation=4,format=1,record_bytes=32,count=2,depth=256,
                      flags=3,first_order=2**32+4,last_order=2**32+5,overwritten=4)
        records = b"".join(packed("TRACE_RECORD", order_low=i+4,pc=i*4) for i in range(2))
        steps = [(OPCODE.TRACE_FREEZE,b"",0,desc), (OPCODE.TRACE_READ,struct.pack("<IIHH",4,0,2,0),0,
                  struct.pack("<IIHH",4,0,2,32)+records)]
        result = self.client(steps).trace()
        self.assertFalse(result["complete_history"])
        self.assertEqual(result["records"][1]["order"], 2**32+5)
        steps[1] = (*steps[1][:3], struct.pack("<IIHH",4,0,2,32)+bytes(64))
        with self.assertRaisesRegex(LinkError,"inconclusive"): self.client(steps).trace()

    def test_scratch_and_injection_confinement(self):
        c = self.client([])
        with self.assertRaises(ValueError): c.bist("memory", 0, 4)
        with self.assertRaises(ValueError): c.arm_injection(0xE000, 1)
        with self.assertRaises(ValueError): c.arm_injection(0xD001, 1)
        with self.assertRaises(ValueError): c.arm_injection(0xD000, 0)
        self.assertFalse(c.transport.requests)

    def test_alu_request_uses_actual_hardware_test_id(self):
        c = self.client([(OPCODE.BIST_START,struct.pack("<B3xII",2,0,0),STATUS.ACCEPTED,struct.pack("<Q",9))])
        with patch.object(c,"wait_operation",return_value={"status":0,"completed":16}) as waiting:
            self.assertEqual(c.bist("alu")["completed"],16); waiting.assert_called_once_with(9)


class ManifestTests(unittest.TestCase):
    def test_existing_manifest_hash_architecture_and_ranges(self):
        data = bytes.fromhex("13000000")
        m = {"schema_version":1,"name":"demo","isa":"rv32i","abi":"ilp32","load_address":0,"entry_address":0,
             "image_bytes":4,"image_padded_bytes":4,"image_crc32":f"{zlib.crc32(data):08x}",
             "image_sha256":hashlib.sha256(data).hexdigest(),"bss":{"start":4,"end":8},
             "heap":{"start":8,"end":0xD000},"scratch":{"start":0xD000,"end":0xE000},"stack":{"start":0xE000,"end":0x10000}}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/"demo.json"; path.with_suffix(".bin").write_bytes(data)
            path.write_text(json.dumps(m)); self.assertEqual(ProgramImage.from_manifest(path).data,data)
            for key,value in (("isa","rv32im"),("entry_address",4),("image_sha256","0"*64),("stack",{"start":0,"end":0x10000})):
                path.write_text(json.dumps({**m,key:value}))
                with self.assertRaises(ValueError): ProgramImage.from_manifest(path)
            path.write_text(json.dumps(m)); path.with_suffix(".bin").write_bytes(b"XXXX")
            with self.assertRaises(ValueError): ProgramImage.from_manifest(path)

    def test_raw_image_bounds_names_and_bss(self):
        for args in ((b"","x",0,0),(b"1234","x",0,0),(b"1234","x",5,0),(b"1234","x",0xD000,4),
                     (b"1234","é"*25,4,0),(b"1234","x\0y",4,0)):
            with self.assertRaises(ValueError): ProgramImage(*args)

    def test_cli_sim_does_not_fake_advanced_capabilities(self):
        cli = Path(__file__).resolve().parents[1]/"dbglink_cli.py"
        p = subprocess.run([sys.executable,str(cli),"--sim","step"],capture_output=True,text=True)
        self.assertEqual(p.returncode,1); self.assertIn("does not advertise STEP",p.stderr)


if __name__ == "__main__": unittest.main()
