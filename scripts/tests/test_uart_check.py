"""Adversarial host-console streams, using a deterministic clock and port."""
from pathlib import Path
import contextlib
import io
import json
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from uart_check import BANNER, CheckError, ConsoleProbe
import uart_check


class FakePort:
    def __init__(self, packets=(), echo=None):
        self.now = 0.0
        self.packets = list(packets)
        self.echo = echo
        self.short_write = False

    def clock(self):
        return self.now

    def read(self, size):
        self.now += 0.05
        if self.packets and self.packets[0][0] <= self.now:
            _, data = self.packets.pop(0)
            return data[:size]
        return b""

    def write(self, data):
        if self.short_write:
            return len(data) - 1
        echoed = self.echo(data) if self.echo else data
        # Split records and echoes across reads, as real USB serial does.
        for i in range(0, len(echoed), 3):
            self.packets.append((self.now + 0.01, echoed[i:i + 3]))
        return len(data)


class HostConsoleTests(unittest.TestCase):
    def probe(self, packets=(), echo=None, **kwargs):
        port = FakePort(packets, echo)
        return ConsoleProbe(port, clock=port.clock, **kwargs), port

    def test_fragmented_greeting_counters_and_exact_echo(self):
        probe, _ = self.probe([(0.05, BANNER[:4]), (0.1, BANNER[4:]),
                               (0.2, b"\r\ncounter: 0\r\n"), (1.2, b"\r\ncounter: 1\r\n")])
        probe.wait_for_startup(2)
        probe.wait_for_counters(2)
        probe.check_echo(b"keyboard text\r\n", 3)
        self.assertEqual([c.value for c in probe.counters], [0, 1])

    def test_counter_interleaved_inside_echo_is_removed(self):
        probe, _ = self.probe(echo=lambda b: b[:4] + b"\r\ncounter: 2\r\n" + b[4:])
        probe.capture.extend(b"\r\ncounter: 0\r\n\r\ncounter: 1\r\n")
        # Let pump parse already-buffered counter records first.
        probe.pump(2)
        probe.check_echo(b"abcdefghij", 3)
        self.assertEqual([c.value for c in probe.counters], [0, 1, 2])

    def test_corrupted_echo_fails(self):
        probe, _ = self.probe(echo=lambda b: b.replace(b"b", b"X"))
        with self.assertRaisesRegex(CheckError, "echo mismatch"):
            probe.check_echo(b"abc", 2)

    def test_extra_echo_bytes_fail(self):
        probe, _ = self.probe(echo=lambda b: b + b"EXTRA")
        with self.assertRaisesRegex(CheckError, "echo mismatch"):
            probe.check_echo(b"abc", 2)

    def test_missing_echo_byte_times_out(self):
        probe, _ = self.probe(echo=lambda b: b[:-1])
        with self.assertRaisesRegex(CheckError, "timeout"):
            probe.check_echo(b"abc", 1)

    def test_absent_banner_times_out(self):
        probe, _ = self.probe([(0.05, b"wrong firmware\r\n")])
        with self.assertRaisesRegex(CheckError, "timeout"):
            probe.wait_for_startup(0.5)

    def test_old_counter_before_reset_greeting_is_not_part_of_session(self):
        probe, _ = self.probe([(0.05, b"\r\ncounter: 99\r\n"), (0.1, BANNER),
                               (0.15, b"\r\ncounter: 0\r\n"), (0.2, b"\r\ncounter: 1\r\n")])
        probe.wait_for_startup(1)
        probe.wait_for_counters(1)
        self.assertEqual([c.value for c in probe.counters], [0, 1])

    def test_static_counter_fails(self):
        probe, _ = self.probe([(0.05, b"\r\ncounter: 9\r\n"), (0.1, b"\r\ncounter: 9\r\n")])
        with self.assertRaisesRegex(CheckError, "did not increase"):
            probe.wait_for_counters(1)

    def test_only_one_counter_times_out(self):
        probe, _ = self.probe([(0.05, b"\r\ncounter: 0\r\n")])
        with self.assertRaisesRegex(CheckError, "timeout"):
            probe.wait_for_counters(0.5)

    def test_counter_wrap_is_accepted(self):
        probe, _ = self.probe([(0.05, b"\r\ncounter: 4294967295\r\n"), (0.1, b"\r\ncounter: 0\r\n")])
        probe.wait_for_counters(1)
        self.assertEqual(probe.counters[-1].value, 0)

    def test_out_of_range_counter_fails(self):
        probe, _ = self.probe([(0.05, b"\r\ncounter: 4294967296\r\n")])
        with self.assertRaisesRegex(CheckError, "32-bit"):
            probe.wait_for_counters(1)

    def test_capture_is_bounded(self):
        probe, _ = self.probe([(0.05, b"x" * 33)], capture_limit=32)
        with self.assertRaisesRegex(CheckError, "capture limit"):
            probe.wait_for_startup(1)

    def test_short_write_fails_without_retry(self):
        probe, port = self.probe()
        port.short_write = True
        with self.assertRaisesRegex(CheckError, "short serial write"):
            probe.check_echo(b"abc", 1)
        self.assertEqual(port.packets, [])

    def test_failed_check_cannot_leave_previous_pass_report(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "result.json"
            report.write_text('{"passed": true}')
            serial = SimpleNamespace(Serial=Mock(side_effect=OSError("device missing")), SerialException=OSError)
            with patch.dict(sys.modules, {"serial": serial}), \
                 patch.object(sys, "argv", ["uart_check.py", "COM-test", "--report", str(report)]), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                result = uart_check.main()
            self.assertEqual(result, 1)
            self.assertFalse(json.loads(report.read_text())["passed"])


if __name__ == "__main__":
    unittest.main()
