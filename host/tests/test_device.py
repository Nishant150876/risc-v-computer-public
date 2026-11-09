"""Session, replay and retry rules, with expectations written by hand from DEBUG_PROTOCOL.md."""
import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dbglink import (CHANNEL, HELLO_RESPONSE, KIND, LIMITS, OPCODE, STATUS, STATUS_RESPONSE,
                     Client, DebugDevice, Frame, FrameError, OutcomeUnknown, SessionLost,
                     StreamDecoder, wire_frame)
from dbglink.schema import SESSION_STATE

A, B = 0xA1A2A3A4A5A6A7A8, 0xB1B2B3B4B5B6B7B8


def req(op, rid, sid, payload=b"", channel=CHANNEL.CONTROL, status=0):
    return Frame(channel, KIND.REQUEST, op, status, rid, sid, payload)


class DeviceRules(unittest.TestCase):
    def setUp(self):
        self.dev = DebugDevice()

    def st(self, frame, now=0):
        reply = self.dev.handle(frame, now)
        return None if reply is None else STATUS.name(reply.status)

    def test_discovery_is_read_only(self):
        reply = self.dev.handle(req(OPCODE.HELLO, 0, 0), 0)
        d = HELLO_RESPONSE.unpack(reply.payload)
        self.assertEqual((reply.status, d["protocol_version"], d["session_state"]), (0, 1, 0))
        self.assertEqual((d["max_payload"], d["capabilities"]), (256, 1))
        self.assertEqual(self.dev.owner, 0)
        self.assertEqual(self.st(req(OPCODE.HELLO, 0, A)), "BAD_ARGUMENT")
        self.assertEqual(self.dev.owner, 0)
        self.assertEqual(self.st(req(OPCODE.STATUS, 0, 0)), "BAD_SESSION")
        self.assertEqual(self.st(req(OPCODE.HELLO, 5, 0)), "BAD_ARGUMENT")
        self.assertEqual(self.st(req(OPCODE.HELLO, 0, 0, b"x")), "BAD_ARGUMENT")

    def test_claim_busy_and_lease_expiry(self):
        self.assertEqual(self.st(req(OPCODE.HELLO, 1, A)), "OK")
        d = HELLO_RESPONSE.unpack(self.dev.handle(req(OPCODE.HELLO, 0, 0), 10).payload)
        self.assertEqual((d["session_state"], d["lease_remaining_ms"]), (SESSION_STATE.OTHER, 1990))
        self.assertEqual(self.st(req(OPCODE.HELLO, 1, B), 100), "BUSY")
        self.assertEqual(self.st(req(OPCODE.PING, 2, B), 100), "BAD_SESSION")
        self.assertEqual(self.st(req(OPCODE.PING, 2, A), 1900), "OK")   # renews to 3900
        self.assertEqual(self.st(req(OPCODE.HELLO, 1, B), 3899), "BUSY")
        self.assertEqual(self.st(req(OPCODE.HELLO, 1, B), 3900), "OK")
        self.assertEqual(self.st(req(OPCODE.PING, 3, A), 3900), "BAD_SESSION")

    def test_repeating_same_hello_is_harmless(self):
        first = self.dev.handle(req(OPCODE.HELLO, 1, A), 0)
        self.assertEqual(self.dev.handle(req(OPCODE.HELLO, 1, A), 300), first)
        self.assertEqual(self.dev.executed, 1)

    def test_replay_conflict_stale(self):
        self.dev.handle(req(OPCODE.HELLO, 1, A), 0)
        r5 = self.dev.handle(req(OPCODE.PING, 5, A, b"abc"), 0)
        n = self.dev.executed
        self.assertEqual(self.dev.handle(req(OPCODE.PING, 5, A, b"abc"), 10), r5)
        self.assertEqual(self.dev.executed, n)
        self.assertEqual(self.st(req(OPCODE.PING, 5, A, b"abd")), "ID_CONFLICT")
        self.assertEqual(self.st(req(OPCODE.STATUS, 5, A)), "ID_CONFLICT")
        self.assertEqual(self.st(req(OPCODE.PING, 4, A)), "STALE_REQUEST")
        self.assertEqual(self.st(req(OPCODE.PING, 1, A)), "STALE_REQUEST")
        self.assertEqual(self.st(req(OPCODE.PING, 0, A)), "BAD_ARGUMENT")
        self.assertEqual(self.dev.executed, n)
        # Errors did not disturb the slot: the identical retry still replays.
        self.assertEqual(self.dev.handle(req(OPCODE.PING, 5, A, b"abc"), 20), r5)

    def test_id_wrap_needs_new_session(self):
        self.dev.handle(req(OPCODE.HELLO, 0xFFFFFFFF, A), 0)
        self.assertEqual(self.st(req(OPCODE.PING, 1, A)), "STALE_REQUEST")

    def test_typed_errors_are_stored_and_replayed(self):
        self.dev.handle(req(OPCODE.HELLO, 1, A), 0)
        self.assertEqual(self.st(req(OPCODE.STEP, 2, A)), "UNSUPPORTED")
        self.assertEqual(self.st(req(OPCODE.STEP, 2, A)), "UNSUPPORTED")
        self.assertEqual(self.st(req(OPCODE.PING, 3, A, b"x" * 33)), "BAD_ARGUMENT")
        self.assertEqual(self.st(req(OPCODE.STATUS, 4, A, b"x")), "BAD_ARGUMENT")
        self.assertEqual(self.st(req(OPCODE.PING, 5, A, channel=CHANNEL.CONSOLE)), "BAD_ARGUMENT")
        self.assertEqual(self.st(req(OPCODE.PING, 6, A, status=1)), "BAD_ARGUMENT")
        self.assertEqual(self.st(req(OPCODE.CONSOLE_READ, 7, A, channel=CHANNEL.CONSOLE)),
                         "UNSUPPORTED")

    def test_reset_clears_session(self):
        self.dev.handle(req(OPCODE.HELLO, 1, A), 0)
        self.dev.reset()
        self.assertEqual(self.st(req(OPCODE.PING, 2, A)), "BAD_SESSION")
        self.assertEqual(self.st(req(OPCODE.HELLO, 1, B)), "OK")

    def test_responses_sent_to_device_are_dropped(self):
        self.assertIsNone(self.dev.handle(Frame(0, KIND.RESPONSE, 1, 0, 1, A), 0))
        self.assertIsNone(self.dev.handle(Frame(2, KIND.EVENT, 1, 0, 0, 0), 0))
        self.assertEqual(self.dev.frames_rejected, 2)

    def test_status_layout(self):
        self.dev.handle(req(OPCODE.HELLO, 1, A), 0)
        s = STATUS_RESPONSE.unpack(self.dev.handle(req(OPCODE.STATUS, 2, A), 0).payload)
        self.assertEqual((s["cpu_state"], s["operation_state"], s["valid"]), (0, 0, 0))


class LossyLink:
    """Simulated UART pair joining a Client and a DebugDevice on a virtual clock.

    Each direction can drop, corrupt or duplicate whole wire frames, and the device can be
    reset between frames.
    """

    def __init__(self, dev, seed, drop=0.0, corrupt=0.0, dup=0.0, latency_ms=5):
        self.dev, self.rng = dev, random.Random(seed)
        self.drop, self.corrupt, self.dup, self.latency = drop, corrupt, dup, latency_ms
        self.now = 0.0
        self.dev_rx = StreamDecoder()
        self.to_host = []      # (deliver_at_ms, bytes)
        self.reset_at = set()

    def clock(self):
        return self.now / 1000

    def _mangle(self, wire):
        if self.rng.random() < self.drop:
            return []
        if self.rng.random() < self.corrupt:
            b = bytearray(wire)
            b[self.rng.randrange(len(b) - 1)] ^= 1 << self.rng.randrange(8)
            wire = bytes(b)
        return [wire] * (2 if self.rng.random() < self.dup else 1)

    def write(self, wire):
        self.now += self.latency
        if int(self.now) in self.reset_at:
            self.dev.reset()
        for copy in self._mangle(wire):
            for item in self.dev_rx.feed(copy, int(self.now)):
                if isinstance(item, FrameError):
                    self.dev.frames_rejected += 1
                    continue
                reply = self.dev.handle(item, int(self.now))
                if reply is not None:
                    for out in self._mangle(wire_frame(reply)):
                        self.to_host.append((self.now + self.latency, out))

    def read(self, n, timeout_s):
        ready = [p for p in self.to_host if p[0] <= self.now + timeout_s * 1000]
        if not ready:
            self.now += timeout_s * 1000
            return b""
        at, data = ready[0]
        self.to_host.remove(ready[0])
        self.now = max(self.now, at)
        return data


class ClientOverLossyLink(unittest.TestCase):
    def make(self, seed, **kw):
        dev = DebugDevice()
        link = LossyLink(dev, seed, **kw)
        return dev, link, Client(link, clock=link.clock)

    def test_clean_link(self):
        dev, link, c = self.make(0)
        self.assertEqual(c.discover()["session_state"], 0)
        self.assertEqual(c.connect(A)["session_state"], SESSION_STATE.YOURS)
        c.ping(b"hello")
        self.assertEqual(c.status()["cpu_state"], 0)
        self.assertEqual((c.stats["retries"], dev.executed), (0, 3))

    def test_no_duplicate_side_effects_on_a_bad_link(self):
        for seed in range(40):
            with self.subTest(seed=seed):
                dev, link, c = self.make(seed, drop=0.15, corrupt=0.1, dup=0.1)
                done = unknown = 0
                session = A + seed * 100
                for i in range(60):
                    try:
                        if not c.session_id:
                            session += 1
                            c.connect(session)
                            continue
                        c.ping(bytes([i]) * (i % 33))
                        done += 1
                    except (OutcomeUnknown, SessionLost):
                        unknown += 1
                # Each request ran at most once; every acknowledged one ran exactly once.
                pings = dev.executed_by_op.get(OPCODE.PING, 0)
                self.assertGreaterEqual(pings, done)
                self.assertLessEqual(pings, done + unknown)
                self.assertGreater(c.stats["retries"], 0)

    def test_reset_mid_session_is_reported(self):
        dev, link, c = self.make(1)
        c.connect(A)
        dev.reset()
        with self.assertRaises(SessionLost):
            c.ping()
        self.assertEqual(c.connect(B)["session_state"], SESSION_STATE.YOURS)

    def test_dead_link_gives_outcome_unknown_after_three_retries(self):
        dev, link, c = self.make(2, drop=1.0)
        c.session_id, c.last_id = A, 0
        with self.assertRaises(OutcomeUnknown):
            c.ping()
        self.assertEqual((c.stats["sent"], c.stats["retries"]), (4, 3))
        self.assertGreaterEqual(link.now, 4 * LIMITS.response_timeout_ms)

    def test_stale_reply_is_ignored(self):
        dev, link, c = self.make(3)
        c.connect(A)
        old = Frame(0, KIND.RESPONSE, OPCODE.PING, 0, 1, A, b"")
        link.to_host.append((0, wire_frame(old)))
        c.ping(b"z")
        self.assertEqual(c.stats["stale_replies"], 1)


class Cli(unittest.TestCase):
    def test_sim_session(self):
        import subprocess
        cli = Path(__file__).resolve().parents[1] / "dbglink_cli.py"
        r = subprocess.run([sys.executable, str(cli), "--sim", "hello", "status", "ping", "soak"],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("capabilities: BASE_STATUS", r.stdout)
        self.assertIn("'retries': 0", r.stdout)


if __name__ == "__main__":
    unittest.main()
