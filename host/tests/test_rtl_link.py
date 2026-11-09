"""The actual Python debugger talks to the actual SoC RTL through framed bytes."""
from pathlib import Path
import shutil
import struct
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from dbglink import Debugger, DeviceError, ProgramImage, STATUS, OPCODE
from dbglink.rtl_transport import RtlTransport


class DropOneReply:
    def __init__(self,transport): self.transport=transport; self.drop=False; self.dropped=0
    def write(self,data): return self.transport.write(data)
    def read(self,n,timeout):
        data=self.transport.read(n,timeout)
        if self.drop and data:
            self.drop=False; self.dropped+=1; return b""
        return data


@unittest.skipUnless(shutil.which("verilator") and shutil.which("g++"),"Verilator and native C++ required (Linux/WSL)")
class ActualRtlLink(unittest.TestCase):
    def test_load_break_edit_step_retry_trace_bist_fault_and_second_program(self):
        with RtlTransport() as transport:
            lossy=DropOneReply(transport)
            client=Debugger(lossy)
            descriptor=client.connect(0x1234567887654321)
            self.assertEqual((descriptor["build_id"],descriptor["clock_hz"],descriptor["breakpoint_count"]),(0x44330001,25000000,2))
            with self.assertRaises(DeviceError): client.run(1)
            # Independent hand-encoded RV32I fixture: ADDI, ADDI, SW, LW, NOP, JAL-to-self.
            data=struct.pack("<6I",0x00100093,0x00208113,0x10202023,0x10002183,0x00000013,0x0000006F)
            loaded=client.load(ProgramImage(data,"π rtl-link A",0x200,16))
            self.assertEqual(loaded["observed_crc"],ProgramImage(data,"x",0x200,16).crc32)
            self.assertEqual(client.read_memory(0x200,16),bytes(16))
            client.set_breakpoint(8); client.arm_trace(); client.run(loaded["image_id"])
            self.assertEqual(client.status()["next_pc"],8)
            self.assertEqual(client.registers()["values"][2],3)
            client.write_register(2,0x12345678)
            # Lose the terminal reply. Client resends the identical ID/frame;
            # the real hardware endpoint must replay without a second store/step.
            lossy.drop=True; client.timeout_ms=100; client.step()
            self.assertEqual((lossy.dropped,client.stats["retries"]),(1,1))
            self.assertEqual(client.status()["next_pc"],12)
            self.assertEqual(client.read_memory(0x100,4),bytes.fromhex("78563412"))
            counter=client.counters()
            self.assertEqual(counter["instructions"],3)
            frozen=client.request(OPCODE.COUNTERS_READ,struct.pack("<IIHH",counter["generation"],8,16,0))
            self.assertEqual(frozen.payload[:12],struct.pack("<IIHH",counter["generation"],8,16,1))
            self.assertEqual(frozen.payload[12:],struct.pack("<QQ",counter["cycles"],counter["instructions"]))
            client.step(); self.assertEqual(client.registers()["values"][3],0x12345678)
            client.step(); self.assertEqual(client.status()["next_pc"],20)
            # Exercise every byte of consecutive GPR words and the final index.
            expected={i: 0xA1020304 ^ (i*0x01010101) for i in (*range(7,16),31)}
            for index,value in expected.items(): client.write_register(index,value)
            registers=client.registers()["values"]
            self.assertEqual({i:registers[i] for i in expected},expected)
            self.assertEqual(client.registers(7,9)["values"],[expected[i] for i in range(7,16)])
            self.assertEqual(client.registers(31,1)["values"],[expected[31]])
            client.set_breakpoint(20,slot=1); client.resume(); client.resume()
            trace=client.trace(); self.assertEqual(len(trace["records"]),6)
            self.assertEqual([r["pc"] for r in trace["records"]],[0,4,8,12,16,20])
            self.assertEqual(trace["records"][2]["pc"],8)
            self.assertEqual(trace["records"][2]["memory_data"],0x12345678)
            self.assertTrue(trace["complete_history"])
            self.assertEqual(client.bist("alu")["completed"],16)
            client.write_memory(0xD010,bytes.fromhex("2301cefa"))
            arm=client.arm_injection(0xD010,4); client.fire_injection(arm)
            failure=client.bist("memory",0xD000,32)
            self.assertEqual((failure["status"],failure["first_address"],failure["expected"],failure["observed"]),
                             (STATUS.VERIFY_FAILED,0xD010,0,4))
            evidence=client.injection_result(arm)
            self.assertEqual((evidence["trigger_count"],evidence["detection_status"],evidence["saved_value"]),(1,0,0xFACE0123))
            client.clear_injection(arm)
            self.assertEqual(client.read_memory(0xD010,4),bytes.fromhex("2301cefa"))
            # Replace program A with B over the link, without recompiling/restarting the FPGA simulation.
            second=struct.pack("<3I",0x00900093,0x10102023,0x00100073)
            b=client.load(ProgramImage(second,"rtl-link B",0x200,8))
            self.assertNotEqual(b["image_id"],loaded["image_id"])
            client.clear_breakpoint(0); client.clear_breakpoint(1); client.run(b["image_id"])
            self.assertEqual(client.read_memory(0x100,4),bytes.fromhex("09000000"))
            self.assertEqual(client.counters()["instructions"],3)
            self.assertEqual(client.status()["cpu_state"],6) # TERMINATED after actual EBREAK


if __name__=="__main__": unittest.main()
