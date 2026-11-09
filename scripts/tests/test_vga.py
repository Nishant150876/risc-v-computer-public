"""Font provenance/conversion, VGA runner registration and actual C runtime contracts."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
import font2mem
import run_tests


class FontTests(unittest.TestCase):
    def test_pixel_font_header_reproducible(self):
        header = REPO/"sw/common/vga_font8x8.inc"
        self.assertEqual(header.read_bytes(),font2mem.c_header(font2mem.SOURCE.read_bytes()).encode("ascii"))

    def test_vendored_source_hash(self):
        self.assertEqual(hashlib.sha256(font2mem.SOURCE.read_bytes()).hexdigest(),
                         "49d8df366296b203ca3211bc0672cf2a762135bf12710735b6292756b19dffd5")
        self.assertIn("License: Public Domain", font2mem.SOURCE.read_text())

    def test_rom_reproducible_and_all_glyph_bits(self):
        image = font2mem.convert(font2mem.SOURCE.read_bytes())
        self.assertEqual(font2mem.TARGET.read_bytes(), image.encode("ascii"))
        rows = [int(line,16) for line in image.splitlines() if not line.startswith("//")]
        self.assertEqual(len(rows), 4096)
        source = font2mem.parse_font(font2mem.SOURCE.read_text())
        for code in range(128):
            for row in range(16):
                for col in range(8):
                    self.assertEqual((rows[code*16+row] >> (7-col)) & 1,
                                     (source[code][row//2] >> col) & 1)
        self.assertEqual(rows[128*16:], [0]*2048)

    def test_bad_input_is_rejected_without_execution(self):
        source = font2mem.SOURCE.read_text()
        for bad in ("", source.replace("[128]", "[127]"),
                    source.replace("0x00", "0x100", 1),
                    source.replace("0x00", "system('bad')", 1),
                    source.replace("0x00,", "", 1)):
            with self.subTest(prefix=bad[:30]), self.assertRaises(ValueError):
                font2mem.parse_font(bad)

    def test_check_does_not_rewrite_stale_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)/"font.mem"
            target.write_bytes(b"stale\n")
            result = subprocess.run([sys.executable,str(SCRIPTS/"font2mem.py"),
                                     str(font2mem.SOURCE),str(target),"--check"],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(target.read_bytes(),b"stale\n")
            result = subprocess.run([sys.executable,str(SCRIPTS/"font2mem.py"),
                                     str(font2mem.SOURCE),str(target)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotIn(b"\r",target.read_bytes())


class VgaIntegrationTests(unittest.TestCase):
    def test_demo_uses_only_full_board_harnesses(self):
        programs = [p for _,p in run_tests.find_programs(None) if p.source.parent.name == "vga_demo"]
        self.assertEqual({p.bench for p in programs},set(run_tests.VGA_BOARD_BENCHES))
        self.assertEqual(len(programs),3)
        self.assertEqual(run_tests.WRAPPED_BENCHES["vga_pipe_tb"],"vga_tb")
        self.assertEqual(run_tests.WRAPPED_BENCHES["board_vga_pipe_tb"],"board_vga_tb")
        self.assertEqual(run_tests.BENCH_CPU_HZ["board_vga_fast_tb"],62_500_000)

    def test_exact_official_vga_pins(self):
        import re
        xdc = (REPO/"fpga/basys3.xdc").read_text()
        pins = dict(re.findall(r"PACKAGE_PIN (\w+) IOSTANDARD LVCMOS33.*?get_ports \{?(vga\w+\[\d\]|Hsync|Vsync)\}?\]",xdc))
        expected = {}
        for channel, locations in {"Red":"G19 H19 J19 N19", "Blue":"N18 L18 K18 J18", "Green":"J17 H17 G17 D17"}.items():
            for bit,pin in enumerate(locations.split()): expected[pin] = f"vga{channel}[{bit}]"
        expected.update(P19="Hsync",R19="Vsync")
        self.assertEqual(pins,expected)
        all_pins = re.findall(r"PACKAGE_PIN (\w+) IOSTANDARD",xdc)
        self.assertEqual(len(all_pins),len(set(all_pins)))

    def test_configured_software_clock_and_rv32i_image(self):
        import json
        import build_software
        prefix = run_tests.find_gcc_prefix()
        self.assertIsNotNone(prefix, "complete RV32-capable toolchain required")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = REPO/"sw/programs/vga_demo/main.c"
            for invalid in (0, -1, 500_000_001):
                with self.assertRaises(ValueError):
                    build_software.build(source, root/"invalid", prefix, invalid)
                self.assertFalse((root/"invalid").exists())
            build_software.build(source, root/"valid", prefix, 50_000_000)
            meta = json.loads((root/"valid/vga_demo.json").read_text())
            self.assertEqual(meta["configured_cpu_hz"], 50_000_000)
            self.assertEqual((meta["isa"],meta["abi"],meta["entry_address"]),("rv32i","ilp32",0))
            self.assertLess(meta["image_padded_bytes"],0xd000)
            _, symbols = build_software.elf_symbols((root/"valid/vga_demo.elf").read_bytes())
            for helper in ("__mulsi3", "__udivsi3", "__divsi3", "__umodsi3"):
                self.assertNotIn(helper,symbols)

    @unittest.skipUnless(shutil.which("gcc"), "native GCC is required for the MMIO-model C test")
    def test_actual_c_library_under_sanitizers(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp)/"vga_runtime_test"
            command = ["gcc","-std=c11","-O2","-Wall","-Wextra","-Werror","-fno-builtin",
                       "-fsanitize=address,undefined","-include",str(SCRIPTS/"tests/vga_mmio_mock.h"),
                       "-I",str(REPO/"sw/common"),str(REPO/"sw/common/vga.c"),
                       str(SCRIPTS/"tests/vga_runtime_test.c"),"-o",str(binary)]
            result = subprocess.run(command,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            result = subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn("PASS:",result.stdout)


if __name__ == "__main__":
    unittest.main()
