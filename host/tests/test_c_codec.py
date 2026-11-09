"""Builds the Tab5 C codec natively and checks it against the golden vectors and against the
independent Python codec on seeded random and corrupted input."""
import random
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "host"))
from dbglink import Frame, FrameError, StreamDecoder, cobs_encode, decode_frame, wire_frame

COMPONENT = REPO / "firmware/tab5/components/dbglink"
FLAGS = ["-std=c99", "-O1", "-g", "-Wall", "-Wextra", "-Wpedantic", "-Wconversion", "-Werror",
         "-fsanitize=address,undefined", "-fno-sanitize-recover=all"]


def describe(item):
    if isinstance(item, FrameError):
        return f"err {item.name}"
    f = item
    return (f"ok {f.version} {f.channel} {f.kind} {f.flags} {f.opcode:04x} {f.status:04x} "
            f"{f.request_id:08x} {f.session_id:016x} {f.payload.hex() or '-'}")


def py_decode(enc):
    try:
        return describe(decode_frame(enc))
    except FrameError as err:
        return describe(err)


def random_frame(rng):
    n = rng.choice((0, 1, 4, 32, 253, 254, 255, 256, rng.randrange(257)))
    payload = bytes(rng.choice((0, 0xFF, rng.randrange(256))) for _ in range(n))
    return Frame(rng.randrange(3), rng.randrange(3), rng.randrange(0x10000), rng.randrange(0x10000),
                 rng.getrandbits(32), rng.getrandbits(64), payload)


def mutate(rng, enc):
    b = bytearray(enc)
    choice = rng.randrange(7)
    if choice == 0 and b:
        b[rng.randrange(len(b))] ^= 1 << rng.randrange(8)
    elif choice == 1 and b:
        del b[rng.randrange(len(b)):]
    elif choice == 2:
        b.insert(rng.randrange(len(b) + 1), rng.randrange(1, 256))
    elif choice == 3 and b:
        del b[rng.randrange(len(b))]
    elif choice == 4:
        b = bytearray(rng.randrange(1, 256) for _ in range(rng.randrange(1, 300)))
    elif choice == 5 and len(b) > 30:
        # Re-encode with a corrupted header byte so the CRC check is what catches it.
        from dbglink.codec import cobs_decode
        raw = bytearray(cobs_decode(bytes(b)))
        raw[rng.randrange(24)] ^= 1 << rng.randrange(8)
        b = bytearray(cobs_encode(bytes(raw)))
    return bytes(x if x else 1 for x in b)   # an encoded frame never holds a zero


@unittest.skipUnless(shutil.which("gcc"), "native GCC required")
class CCodec(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.temp.name) / "host_test"
        cmd = ["gcc", *FLAGS, "-I", str(COMPONENT / "include"), str(COMPONENT / "dbglink.c"),
               str(COMPONENT / "dbglink_client.c"), str(COMPONENT / "test/host_test.c"),
               "-o", str(cls.binary)]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_c(self, *args, stdin=""):
        r = subprocess.run([str(self.binary), *args], input=stdin, capture_output=True,
                           text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def test_golden_vectors_and_unit_tests(self):
        out = self.run_c("vectors", str(REPO / "protocol/vectors/frames.txt"),
                         str(REPO / "protocol/vectors/sessions.txt"))
        self.assertIn("PASS:", out)

    def test_decode_matches_python_on_random_and_corrupt_frames(self):
        rng = random.Random(0xC0DE)
        cases = []
        for _ in range(4000):
            enc = wire_frame(random_frame(rng))[:-1]
            cases.append(enc if rng.random() < 0.25 else mutate(rng, enc))
        out = self.run_c("decode", stdin="".join(c.hex() + "\n" for c in cases))
        got = out.splitlines()
        want = [py_decode(c) for c in cases]
        self.assertEqual(len(got), len(want))
        for i, (g, w) in enumerate(zip(got, want)):
            self.assertEqual(g, w, f"case {i}: {cases[i].hex()}")
        kinds = {w.split()[1] if w.startswith("err") else "ok" for w in want}
        for name in ("ok", "BAD_CRC", "COBS_INVALID", "BAD_LENGTH", "TOO_LONG"):
            self.assertIn(name, kinds)

    def test_stream_matches_python_with_timing(self):
        rng = random.Random(0x57EA)
        lines, rx, want, now = [], StreamDecoder(), [], 0
        for _ in range(1500):
            chunk = wire_frame(random_frame(rng))
            r = rng.random()
            if r < 0.1:
                chunk = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 400)))
            elif r < 0.25:
                chunk = mutate(rng, chunk[:-1]) + b"\0"
            elif r < 0.3:
                chunk = chunk[:rng.randrange(1, len(chunk))]   # truncated, no delimiter
            pieces = sorted(rng.sample(range(1, len(chunk)), min(2, len(chunk) - 1))) if len(chunk) > 2 else []
            for part in (chunk[a:b] for a, b in zip([0] + pieces, pieces + [len(chunk)])):
                now += rng.choice((0, 1, 5, 99, 100, 101, 400))
                lines.append(f"{now} {part.hex()}")
                want += [describe(x) for x in rx.feed(part, now)]
        out = self.run_c("stream", stdin="\n".join(lines) + "\n").splitlines()
        self.assertEqual(out, want)
        self.assertTrue(any(w == "err TIMEOUT" for w in want))
        self.assertGreater(sum(w.startswith("ok") for w in want), 300)


if __name__ == "__main__":
    unittest.main()
