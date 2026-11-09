"""Run adversarial images against the real cpu_tb and board_c_tb; no external
Python packages.

Each bench is built once in a temporary native directory. These tests prove
that broken program results and expectation files cannot produce a green run.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from bin2mem import convert
import run_tests as runner

# Initialize a RAM guard and report pass. Only initialized registers are read.
PASS_PREFIX = [
    0x000032b7,  # lui t0, 0x3       (guard at 0x3000)
    0x05500313,  # li t1, 0x55
    0x0062a023,  # sw t1, 0(t0)
    0xf00003b7,  # lui t2, 0xf0000   (result at 0xF0000000)
    0x00100e13,  # li t3, 1
    0x01c3a023,  # sw t3, 0(t2)
]


class CpuHarnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="rvc-cpu-harness-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        result = runner.run_one(runner.TB_DIR / "system" / "cpu_tb.sv", cls.directory, 2, 10)
        if result.status != "BUILT":
            raise AssertionError("cpu_tb build failed:\n" + result.log)
        cls.binary = Path(result.detail)

    def run_image(self, words, *args, expectation=None):
        image = self.directory / "probe.mem"
        image.write_text(convert(b"".join(word.to_bytes(4, "little") for word in words)))
        command = [str(self.binary), f"+program={image}", "+quiet", *args]
        if expectation is not None:
            expect_file = self.directory / "probe.expect"
            expect_file.write_text(expectation)
            command.append(f"+expect={expect_file}")
        # Verilator's $fatal may abort. Keep any core/output in the temp directory.
        return subprocess.run(command, cwd=self.directory, capture_output=True, text=True, timeout=10)

    def assert_failure(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("PASS:", result.stdout)
        self.assertIn(message, result.stdout + result.stderr)

    def test_failure_cannot_be_overwritten_by_pass(self):
        words = [0xf00002b7, 0x00300313, 0x0062a023,  # result = 3 (fail)
                 0x00100313, 0x0062a023, 0x00000073]  # result = 1, ECALL
        self.assert_failure(self.run_image(words), "result word 00000003")

    def test_store_load_and_register_instructions_after_both_halts_stay_idle(self):
        for stop in (0x00000073, 0x00100073):  # ECALL, EBREAK
            for tail in (0x0002a023, 0x0002a503, 0x00130313):  # SW, LW, ADDI
                with self.subTest(stop=hex(stop), tail=hex(tail)):
                    result = self.run_image(PASS_PREFIX + [stop, tail],
                                            expectation="00003000 00000055\n")
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("PASS:", result.stdout)

    def test_malformed_expectation_after_valid_row_fails(self):
        for bad_row in ("THIS IS NOT AN EXPECTATION\n", "00003004\n",
                        "00003000 00000055 extra\n"):
            with self.subTest(row=bad_row):
                result = self.run_image(PASS_PREFIX + [0x00000073],
                                        expectation="00003000 00000055\n" + bad_row)
                self.assert_failure(result, "malformed expect file")

    def test_empty_expectation_fails(self):
        result = self.run_image(PASS_PREFIX + [0x00000073], expectation="\n  \n")
        self.assert_failure(result, "has no entries")

    def test_incorrect_or_invalid_expectation_fails(self):
        for row, message in (("00003000 deadbeef\n", "expected deadbeef"),
                             ("00003001 00000055\n", "bad expect address"),
                             ("00010000 00000055\n", "bad expect address")):
            with self.subTest(row=row):
                self.assert_failure(self.run_image(PASS_PREFIX + [0x00000073], expectation=row), message)

    def test_unwritten_ram_is_not_assumed_zero(self):
        result = self.run_image(PASS_PREFIX + [0x00000073], expectation="00003004 00000000\n")
        self.assert_failure(result, "got a5a5a5a5")

    def test_halt_without_result_fails(self):
        self.assert_failure(self.run_image([0x00000073]), "halted without writing a result")

    def test_wrong_stop_cause_fails(self):
        result = self.run_image(PASS_PREFIX + [0x00100073], "+expect_stop=ECALL")
        self.assert_failure(result, "expected stop ECALL, got EBREAK")

    def test_bad_stop_name_and_zero_cycle_limit_fail(self):
        for argument, message in (("+expect_stop=TYPO", "unknown expect_stop"),
                                  ("+max_cycles=0", "max_cycles must be positive")):
            with self.subTest(argument=argument):
                self.assert_failure(self.run_image([0x00000073], argument), message)

    def test_nonterminating_program_times_out(self):
        self.assert_failure(self.run_image([0x0000006f], "+max_cycles=12"), "timeout after 12 cycles")

    def test_halt_on_last_permitted_cycle_is_accepted(self):
        words = PASS_PREFIX + [0x00000073]
        result = self.run_image(words, f"+max_cycles={len(words)}")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_failure(self.run_image(words, f"+max_cycles={len(words) - 1}"), "timeout after 6 cycles")

    def test_board_mode_requires_both_expected_outputs(self):
        result = self.run_image(PASS_PREFIX + [0x00000073], "+board_io")
        self.assert_failure(result, "board_io requires expect_leds and expect_display")

    def test_board_mode_checks_actual_writes_and_values(self):
        result = self.run_image([0x00000073], "+board_io", "+expect_leds=0000", "+expect_display=0000")
        self.assert_failure(result, "did not write both LED and display")
        words = [0x800002b7, 0x05500313, 0x0062a023, 0x0062a223, 0x00100073]
        result = self.run_image(words, "+board_io", "+expect_leds=0055", "+expect_display=0066")
        self.assert_failure(result, "board outputs expected")

    def test_running_board_program_is_observed_without_a_fake_halt(self):
        words = [0x800002b7, 0x05500313, 0x0062a023, 0x0062a223, 0x0000006f]
        result = self.run_image(words, "+board_io", "+observe_io", "+expect_leds=0055", "+expect_display=0055")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("running LED=0055 display=0055", result.stdout)

    def test_uart_mode_requires_expectation_and_correct_options(self):
        self.assert_failure(self.run_image([0x00100073], "+uart_console"), "requires uart_expect")
        self.assert_failure(self.run_image([0x00100073], "+uart_observe"), "require uart_console")

    def test_uart_empty_or_unwritten_stream_fails(self):
        expected = self.directory / "uart.expect"
        expected.write_text("")
        args = ("+uart_console", f"+uart_expect={expected}", "+expect_stop=EBREAK")
        self.assert_failure(self.run_image([0x00100073], *args), "empty UART expectation")
        expected.write_text("X")
        self.assert_failure(self.run_image([0x00100073], *args), "UART expected 1 bytes, observed 0")

    def test_uart_checker_decodes_real_pin_and_rejects_wrong_byte(self):
        # Send 'A' through the real MMIO/UART, wait an entire serial frame,
        # return zero and EBREAK. No simulated output or fabricated PASS word.
        words = [0x800002b7, 0x04100313, 0x0062a823] + [0x00000013] * 2200 + [0x00000513, 0x00100073]
        expected = self.directory / "uart.expect"
        args = ("+uart_console", f"+uart_expect={expected}", "+expect_stop=EBREAK")
        expected.write_text("A")
        result = self.run_image(words, *args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected.write_text("X")
        self.assert_failure(self.run_image(words, *args), "UART byte 0 expected 58, got 41")


class BoardBenchTests(unittest.TestCase):
    """board_c_tb must reject a missing image and one that ignores the switches."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="rvc-board-bench-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        result = runner.run_one(runner.TB_DIR / "system" / "board_c_tb.sv", cls.directory, 2, 10)
        if result.status != "BUILT":
            raise AssertionError("board_c_tb build failed:\n" + result.log)
        cls.binary = Path(result.detail)

    def run_bench(self, *args):
        return subprocess.run([str(self.binary), *args], cwd=self.directory,
                              capture_output=True, text=True, timeout=10)

    def test_missing_program_fails(self):
        result = self.run_bench()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PASS:", result.stdout)
        self.assertIn("needs +program", result.stdout)

    def test_image_that_ignores_switches_fails(self):
        # Shows 1A6D on the LED/hex registers once, then spins: right for the
        # gate input 20 only, so the first live switch change must fail.
        words = [0x800002b7,  # lui  t0, 0x80000
                 0x01400313,  # li   t1, 20
                 0x0062a023,  # sw   t1, 0(t0)    LEDs
                 0x000023b7,  # lui  t2, 0x2
                 0xa6d38393,  # addi t2, t2, -1427  (0x1a6d)
                 0x0072a223,  # sw   t2, 4(t0)    hex display
                 0x0000006f]  # j    .
        image = self.directory / "static.mem"
        image.write_text(convert(b"".join(word.to_bytes(4, "little") for word in words)))
        result = self.run_bench(f"+program={image}", "+max_cycles=2000")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("PASS:", result.stdout)
        self.assertIn("outputs never reached LED=0000 display=0000", result.stdout)


if __name__ == "__main__":
    unittest.main()
