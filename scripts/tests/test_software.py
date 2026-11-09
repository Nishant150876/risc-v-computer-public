"""Real linker/image checks for the freestanding C build and console (WSL)."""
import binascii
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import build_software as software
import run_tests as runner


class SoftwareTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="rvc-software-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        cls.prefix = runner.find_gcc_prefix()
        if cls.prefix is None:
            raise AssertionError("complete RISC-V toolchain required")
        for name in ("fib", "runtime_smoke", "hello", "printf_smoke"):
            software.build(software.REPO / "sw/programs" / name / "main.c", cls.directory / name, cls.prefix)

    def test_metadata_matches_actual_image(self):
        for name in ("fib", "runtime_smoke", "hello", "printf_smoke"):
            with self.subTest(program=name):
                base = self.directory / name / name
                meta = json.loads(base.with_suffix(".json").read_text())
                data = base.with_suffix(".bin").read_bytes()
                self.assertEqual(meta["image_bytes"], len(data))
                self.assertEqual(meta["image_crc32"], f"{binascii.crc32(data) & 0xffffffff:08x}")
                self.assertEqual(meta["image_sha256"], hashlib.sha256(data).hexdigest())
                rebuilt = b"".join(int(word, 16).to_bytes(4, "little")
                                   for word in base.with_suffix(".mem").read_text().splitlines())
                self.assertEqual(rebuilt[:len(data)], data)
                self.assertEqual(len(rebuilt), meta["image_padded_bytes"])

    def test_linker_reservations_and_startup_symbols(self):
        base = self.directory / "runtime_smoke/runtime_smoke"
        entry, symbols = software.elf_symbols(base.with_suffix(".elf").read_bytes())
        self.assertEqual(entry, 0)
        self.assertEqual(symbols["_start"], 0)
        self.assertGreater(symbols["__bss_end"], symbols["__bss_start"])
        self.assertLessEqual(symbols["__heap_start"], 0xd000)
        self.assertEqual(symbols["__scratch_start"], 0xd000)
        self.assertEqual(symbols["__scratch_end"], 0xe000)
        self.assertEqual(symbols["__stack_bottom"], 0xe000)
        self.assertEqual(symbols["__stack_top"], 0x10000)
        self.assertEqual(symbols["__stack_top"] % 16, 0)
        self.assertIn("__udivsi3", symbols)
        self.assertIn("__mulsi3", symbols)

    def test_console_decimal_does_not_link_arithmetic_helpers(self):
        for name in ("hello", "printf_smoke"):
            _, symbols = software.elf_symbols((self.directory / name / f"{name}.elf").read_bytes())
            for helper in ("__udivsi3", "__divsi3", "__umodsi3", "__mulsi3"):
                self.assertNotIn(helper, symbols)

    def test_oversized_bss_is_rejected_by_real_linker(self):
        directory = self.directory / "overflow"
        directory.mkdir()
        source = directory / "main.c"
        source.write_text("volatile unsigned char large[0xd001]; int main(void) { return large[0]; }\n")
        with self.assertRaises(software.BuildError) as caught:
            software.build(source, directory / "out", self.prefix)
        self.assertRegex(str(caught.exception), r"will not fit|overflowed|program/BSS overlaps")
        self.assertFalse((directory / "out/overflow.mem").exists())

    def test_failed_rebuild_removes_previous_outputs(self):
        output = self.directory / "rebuild"
        software.build(software.REPO / "sw/programs/fib/main.c", output, self.prefix)
        self.assertTrue((output / "fib.mem").is_file())
        broken = self.directory / "broken" / "fib"
        broken.mkdir(parents=True)
        (broken / "main.c").write_text("volatile unsigned char large[0xd001]; int main(void) { return large[0]; }\n")
        with self.assertRaises(software.BuildError):
            software.build(broken / "main.c", output, self.prefix)
        for suffix in ("elf", "bin", "mem", "json"):
            self.assertFalse((output / f"fib.{suffix}").exists(), suffix)

    def test_wrong_or_truncated_elf_is_rejected(self):
        valid = (self.directory / "fib/fib.elf").read_bytes()
        for blob in (b"", b"not an ELF", valid[:51], valid[:52], bytes(52)):
            with self.subTest(length=len(blob)):
                with self.assertRaises(ValueError):
                    software.elf_symbols(blob)

    def test_compressed_or_nonzero_entry_elf_is_rejected(self):
        base = self.directory / "fib/fib"
        original = base.with_suffix(".elf").read_bytes()
        binary = base.with_suffix(".bin").read_bytes()
        for offset, value in ((36, 1), (24, 4)):
            bad = bytearray(original)
            bad[offset:offset + 4] = value.to_bytes(4, "little")
            with self.subTest(offset=offset):
                with self.assertRaises(ValueError):
                    software.image_metadata(bytes(bad), binary, "bad")

    def test_out_of_bounds_binary_is_rejected(self):
        elf = (self.directory / "fib/fib.elf").read_bytes()
        for binary in (b"", bytes(4), bytes(0xd001)):
            with self.subTest(length=len(binary)):
                with self.assertRaises(ValueError):
                    software.image_metadata(elf, binary, "bad")


if __name__ == "__main__":
    unittest.main()
