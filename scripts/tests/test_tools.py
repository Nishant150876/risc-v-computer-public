"""Failure-path tests for the regression runner and image converter (stdlib only)."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import bin2mem
import run_tests as runner


class ConverterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "input.bin"
        self.target = Path(self.temp.name) / "output.mem"

    def convert_cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPTS / "bin2mem.py"),
                               str(self.source), str(self.target), *args],
                              capture_output=True, text=True)

    def test_little_endian_and_partial_word(self):
        self.assertEqual(bin2mem.convert(bytes.fromhex("0123456789abcd")),
                         "67452301\n00cdab89\n")
        self.assertEqual(bin2mem.convert(b""), "")

    def test_all_tail_lengths_and_lf_output(self):
        for size in range(1, 9):
            with self.subTest(size=size):
                data = bytes(range(size))
                self.source.write_bytes(data)
                self.assertEqual(self.convert_cli().returncode, 0)
                text = self.target.read_bytes()
                self.assertNotIn(b"\r", text)
                restored = b"".join(int(word, 16).to_bytes(4, "little")
                                    for word in text.splitlines())
                self.assertEqual(restored[:size], data)
                self.assertEqual(restored[size:], b"\0" * (-size % 4))

    def test_exact_ram_limit_and_oversize_preserves_output(self):
        self.source.write_bytes(b"\xff" * 65536)
        self.assertEqual(self.convert_cli().returncode, 0)
        self.assertEqual(len(self.target.read_text().splitlines()), 16384)
        before = self.target.read_bytes()
        self.source.write_bytes(b"\xff" * 65537)
        self.assertNotEqual(self.convert_cli().returncode, 0)
        self.assertEqual(self.target.read_bytes(), before)

    def test_size_must_accommodate_whole_words(self):
        self.source.write_bytes(b"abc")
        for size in ("0", "-4", "3"):
            with self.subTest(size=size):
                self.assertNotEqual(self.convert_cli("--size", size).returncode, 0)
                self.assertFalse(self.target.exists())
        self.assertEqual(self.convert_cli("--size", "4").returncode, 0)

    def test_input_cannot_be_overwritten(self):
        self.source.write_bytes(b"original")
        self.target = self.source
        self.assertNotEqual(self.convert_cli().returncode, 0)
        self.assertEqual(self.source.read_bytes(), b"original")

    def test_hard_link_cannot_overwrite_input(self):
        self.source.write_bytes(b"original")
        os.link(self.source, self.target)
        self.assertNotEqual(self.convert_cli().returncode, 0)
        self.assertEqual(self.source.read_bytes(), b"original")

    def test_missing_input_is_a_clear_failure(self):
        result = self.convert_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bin2mem:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.target.exists())


class RunnerTests(unittest.TestCase):
    def test_verdict_requires_exact_pass_and_successful_exit(self):
        cases = [(0, "PASS: checked\n", "", "PASS"),
                 (0, "PASSING without a verdict\n", "", "FAIL"),
                 (0, "", "", "FAIL"),
                 (1, "PASS: checked\n", "", "FAIL"),
                 (0, "FAIL: bad\nPASS: later\n", "", "FAIL"),
                 (0, "PASS: checked\n", "FAIL: bad\n", "FAIL")]
        for code, out, err, expected in cases:
            with self.subTest(code=code, out=out, err=err):
                process = subprocess.CompletedProcess([], code, out, err)
                self.assertEqual(runner.simulation_result("test", process, 0).status, expected)

    def test_timeout_preserves_both_output_streams(self):
        error = subprocess.TimeoutExpired("sim", 1, output=b"last trace\n", stderr=b"diagnostic\n")
        self.assertEqual(runner.timeout_output(error), "last trace\ndiagnostic\n")

    def test_missing_or_partial_official_suite_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / "rv32ui"
            with patch.object(runner, "RV32UI_DIR", directory):
                self.assertIn("not checked out", runner.rv32ui_problem())
                directory.mkdir()
                self.assertIn("missing=", runner.rv32ui_problem())
                for name in runner.RV32UI_NAMES:
                    (directory / f"{name}.S").touch()
                self.assertEqual(runner.rv32ui_problem(), "")
                (directory / "add.S").unlink()
                self.assertIn("missing=add;", runner.rv32ui_problem())
                (directory / "unknown.S").touch()
                self.assertIn("unexpected=unknown", runner.rv32ui_problem())

    def test_named_official_program_is_not_silently_skipped_when_missing(self):
        with patch.object(runner, "find_programs", return_value=[]):
            self.assertTrue(runner.pattern_targets_programs("rv32ui/add"))

    def test_toolchain_requires_gcc_objcopy_and_objdump(self):
        with patch.dict(os.environ, {"RISCV_PREFIX": "chosen-"}):
            with patch.object(runner.shutil, "which", side_effect=lambda tool: tool if tool.endswith("gcc") else None):
                self.assertIsNone(runner.find_gcc_prefix())
            with patch.object(runner.shutil, "which", return_value="/tools/present"):
                self.assertEqual(runner.find_gcc_prefix(), "chosen-")

    def test_disassembly_failure_is_a_build_failure(self):
        success = subprocess.CompletedProcess([], 0, "", "")
        failure = subprocess.CompletedProcess([], 1, "", "disassembly failed")
        program = runner.Program("directed", "sample", Path("sample.S"))
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(runner.subprocess, "run", side_effect=[success, success, success, failure]):
                mem, log = runner.build_program(program, "chosen-", Path(temp))
            self.assertIsNone(mem)
            self.assertIn("disassembly failed", log)
            self.assertFalse((Path(temp) / "sample.dump").exists())

    def test_unavailable_build_tool_reports_failure_without_traceback(self):
        program = runner.Program("directed", "sample", Path("sample.S"))
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(runner.subprocess, "run", side_effect=FileNotFoundError("missing gcc")):
                mem, log = runner.build_program(program, "chosen-", Path(temp))
            self.assertIsNone(mem)
            self.assertIn("cannot run chosen-gcc", log)

    def test_quoted_program_arguments_preserve_spaces(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "sample.S"
            source.write_text('// cpu_tb: +expect="path with spaces/words.expect" +trace\n')
            self.assertEqual(runner.plusargs_for(source),
                             ["+expect=path with spaces/words.expect", "+trace"])

    def test_board_image_is_selected_only_for_the_board_bench(self):
        board = [label for label, p in runner.find_programs(None) if p.bench == runner.BOARD_BENCH]
        self.assertEqual(board, ["board_c_tb:c/fib_board"])
        self.assertTrue(runner.pattern_targets_programs("fib", runner.BOARD_BENCH))
        self.assertFalse(runner.pattern_targets_programs("rv32ui", runner.BOARD_BENCH))
        self.assertTrue(runner.pattern_targets_programs("rv32ui", runner.PROGRAM_BENCH))
        tests = [t.stem for t in runner.find_tests("board_c")]
        # Phase 5 adds the same board bench with the pipelined CPU.
        self.assertEqual(tests, ["board_c_pipe_tb", "board_c_tb"])
        pipe_board = [label for label, p in runner.find_programs(None)
                      if p.bench == runner.BOARD_PIPE_BENCH]
        self.assertEqual(pipe_board, ["board_c_pipe_tb:c/fib_board"])
        uart = [label for label, p in runner.find_programs(None) if p.bench == runner.UART_BOARD_BENCH]
        self.assertEqual(uart, ["board_uart_tb:c/hello_board"])
        self.assertTrue(runner.pattern_targets_programs("hello", runner.UART_BOARD_BENCH))
        self.assertFalse(runner.pattern_targets_programs("rv32ui", runner.UART_BOARD_BENCH))

    def test_every_cpu_tb_program_also_runs_on_the_pipeline(self):
        programs = runner.find_programs(None)
        single = {(p.suite, p.name, p.args) for _, p in programs if p.bench == runner.PROGRAM_BENCH}
        pipe = {(p.suite, p.name, p.args) for _, p in programs if p.bench == runner.PIPE_BENCH}
        self.assertEqual(single, pipe)
        lockstep = {(p.suite, p.name) for _, p in programs if p.bench == runner.LOCKSTEP_BENCH}
        for suite, name, _ in single:
            if suite != "c":
                self.assertIn((suite, name), lockstep)
        for name in ("hazard_zoo", "pipe_mmio"):
            self.assertIn(("directed", name), lockstep)
        for name in ("runtime_smoke", "hello", "printf_smoke", "fib_20"):
            self.assertIn(("c", name), lockstep)
        self.assertTrue(runner.pattern_targets_programs("rv32ui", runner.PIPE_BENCH))
        self.assertTrue(runner.pattern_targets_programs("rv32ui", runner.LOCKSTEP_BENCH))
        self.assertEqual(runner.WRAPPED_BENCHES["board_uart_pipe_tb"], "board_uart_tb")

    def test_empty_cpu_program_selection_is_a_failure(self):
        with patch.object(runner, "find_programs", return_value=[]):
            results = runner.run_programs(Path("unused"), Path("unused"), "directed", 1, False)
        self.assertEqual([result.status for result in results], ["FAIL"])
        self.assertIn("no CPU programs", results[0].detail)


if __name__ == "__main__":
    unittest.main()
