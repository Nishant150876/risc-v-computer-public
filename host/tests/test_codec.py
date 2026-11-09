"""Codec checks against independent anchors: zlib, published COBS examples and hand-built headers."""
import random
import struct
import sys
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dbglink import (FRAME_ERROR, LIMITS, Frame, FrameError, StreamDecoder, cobs_decode,
                     cobs_encode, crc32, decode_frame, encode_frame, parse_frame, wire_frame)

# Published COBS examples (Cheshire and Baker; also listed on the Wikipedia COBS page).
COBS_EXAMPLES = [
    ("00", "0101"), ("0000", "010101"), ("001100", "01021101"), ("11220033", "0311220233"),
    ("11223344", "0511223344"), ("11000000", "0211010101"),
    (bytes(range(1, 255)).hex(), "ff" + bytes(range(1, 255)).hex()),
    (bytes(range(0, 255)).hex(), "01ff" + bytes(range(1, 255)).hex()),
    (bytes(range(1, 256)).hex(), "ff" + bytes(range(1, 255)).hex() + "02ff"),
    ((bytes(range(2, 256)) + b"\0").hex(), "ff" + bytes(range(2, 256)).hex() + "0101"),
    ((bytes(range(3, 256)) + b"\0\1").hex(), "fe" + bytes(range(3, 256)).hex() + "0201"),
]


class CrcTests(unittest.TestCase):
    def test_check_value(self):
        self.assertEqual(crc32(b"123456789"), 0xCBF43926)

    def test_matches_zlib(self):
        rng = random.Random(1)
        for n in (0, 1, 2, 3, 255, 256, 284):
            data = bytes(rng.randrange(256) for _ in range(n))
            self.assertEqual(crc32(data), zlib.crc32(data))


class CobsTests(unittest.TestCase):
    def test_published_examples(self):
        for raw, enc in COBS_EXAMPLES:
            with self.subTest(raw=raw[:16]):
                self.assertEqual(cobs_encode(bytes.fromhex(raw)).hex(), enc)
                self.assertEqual(cobs_decode(bytes.fromhex(enc)).hex(), raw)

    def test_doc_example(self):
        self.assertEqual(cobs_encode(bytes.fromhex("11220033")) + b"\0",
                         bytes.fromhex("031122023300"))

    def test_round_trip_random(self):
        rng = random.Random(2)
        for _ in range(2000):
            data = bytes(rng.choice((0, 1, 255, rng.randrange(256)))
                         for _ in range(rng.randrange(600)))
            enc = cobs_encode(data)
            self.assertNotIn(0, enc)
            self.assertLessEqual(len(enc), len(data) + len(data) // 254 + 1)
            self.assertEqual(cobs_decode(enc), data)

    def test_worst_case_overhead_fits_bound(self):
        self.assertEqual(len(cobs_encode(b"\x01" * LIMITS.max_frame)), LIMITS.max_encoded)

    def test_invalid(self):
        for bad in ("00", "0311", "0211" "00", "05112233"):
            with self.subTest(bad=bad), self.assertRaises(FrameError) as ctx:
                cobs_decode(bytes.fromhex(bad))
            self.assertEqual(ctx.exception.code, FRAME_ERROR.COBS_INVALID)


class FrameTests(unittest.TestCase):
    def frame(self, **kw):
        base = dict(channel=0, kind=0, opcode=2, request_id=0x11223344,
                    session_id=0x0102030405060708, payload=b"\x00\xAA")
        base.update(kw)
        return Frame(**base)

    def test_header_bytes_by_hand(self):
        raw = encode_frame(self.frame())
        expected = bytes([1, 0, 0, 0, 2, 0, 0, 0, 0x44, 0x33, 0x22, 0x11,
                          8, 7, 6, 5, 4, 3, 2, 1, 2, 0, 0, 0, 0x00, 0xAA])
        self.assertEqual(raw[:26], expected)
        self.assertEqual(raw[26:], struct.pack("<I", zlib.crc32(expected)))

    def test_round_trip_limits(self):
        for n in (0, 1, 255, 256):
            f = self.frame(payload=bytes(range(256))[:n])
            wire = wire_frame(f)
            self.assertLessEqual(len(wire), LIMITS.max_wire)
            self.assertEqual(wire.count(0), 1)
            self.assertEqual(decode_frame(wire[:-1]), f)

    def test_oversize_payload_refused_on_send(self):
        with self.assertRaises(ValueError):
            encode_frame(self.frame(payload=b"x" * 257))

    def corrupt(self, raw, offset, value):
        b = bytearray(raw)
        b[offset] = value
        body = bytes(b[:-4])
        return body + struct.pack("<I", zlib.crc32(body))

    def assertError(self, raw, name):
        with self.assertRaises(FrameError) as ctx:
            parse_frame(raw)
        self.assertEqual(ctx.exception.name, name)

    def test_error_order(self):
        raw = encode_frame(self.frame())
        self.assertError(raw[:27], "TOO_SHORT")
        self.assertError(raw[:-1], "BAD_LENGTH")
        self.assertError(raw + b"\0", "BAD_LENGTH")
        self.assertError(self.corrupt(raw, 20, 9), "BAD_LENGTH")
        self.assertError(raw[:-1] + bytes([raw[-1] ^ 1]), "BAD_CRC")
        self.assertError(self.corrupt(raw, 0, 2), "BAD_VERSION")
        self.assertError(self.corrupt(raw, 3, 1), "BAD_RESERVED")
        self.assertError(self.corrupt(raw, 23, 1), "BAD_RESERVED")
        self.assertError(self.corrupt(raw, 1, 3), "BAD_CHANNEL")
        self.assertError(self.corrupt(raw, 2, 3), "BAD_KIND")
        with self.assertRaises(FrameError) as ctx:
            decode_frame(b"\x01" * (LIMITS.max_encoded + 1))
        self.assertEqual(ctx.exception.name, "TOO_LONG")

    def test_every_single_bit_flip_is_caught(self):
        raw = encode_frame(self.frame(payload=bytes(range(40))))
        for i in range(len(raw) * 8):
            b = bytearray(raw)
            b[i // 8] ^= 1 << (i % 8)
            with self.assertRaises(FrameError):
                parse_frame(bytes(b))


class StreamTests(unittest.TestCase):
    def setUp(self):
        self.f = Frame(0, 1, 3, 0, 7, 9, b"hi\0there")
        self.wire = wire_frame(self.f)

    def test_back_to_back_and_idle_delimiters(self):
        rx = StreamDecoder()
        out = rx.feed(b"\0\0" + self.wire + self.wire + b"\0")
        self.assertEqual(out, [self.f, self.f])

    def test_byte_at_a_time(self):
        rx = StreamDecoder()
        out = []
        for b in self.wire:
            out += rx.feed(bytes([b]))
        self.assertEqual(out, [self.f])

    def test_garbage_then_recovery(self):
        rx = StreamDecoder()
        out = rx.feed(b"\x13\x37garbage\0" + self.wire)
        self.assertIsInstance(out[0], FrameError)
        self.assertEqual(out[1:], [self.f])

    def test_overflow_discards_through_delimiter(self):
        rx = StreamDecoder()
        out = rx.feed(b"\x01" * 1000 + self.wire[:5] + b"\0" + self.wire)
        self.assertEqual([getattr(o, "name", None) for o in out], ["TOO_LONG", None])
        self.assertEqual(out[1], self.f)
        self.assertEqual(rx.counts["TOO_LONG"], 1)

    def test_interbyte_timeout(self):
        rx = StreamDecoder()
        self.assertEqual(rx.feed(self.wire[:10], now_ms=0), [])
        self.assertEqual(rx.feed(self.wire[10:], now_ms=50), [self.f])
        rx.feed(self.wire[:10], now_ms=1000)
        out = rx.feed(self.wire, now_ms=1101)
        self.assertEqual(out[0].name, "TIMEOUT")
        self.assertEqual(out[1:], [self.f])

    def test_poll_timeout(self):
        rx = StreamDecoder()
        rx.feed(self.wire[:3], now_ms=0)
        self.assertEqual(rx.poll(100), [])
        self.assertEqual([e.name for e in rx.poll(101)], ["TIMEOUT"])
        self.assertEqual(rx.poll(500), [])


if __name__ == "__main__":
    unittest.main()
