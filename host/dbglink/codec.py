"""Frame codec: CRC-32/ISO-HDLC, COBS, the 24-byte header and a bounded stream receiver.

Receive checks run in a fixed order so every implementation reports the same error for the
same bytes: TOO_LONG, COBS_INVALID, TOO_SHORT, BAD_LENGTH, BAD_CRC, BAD_VERSION,
BAD_RESERVED, BAD_CHANNEL, BAD_KIND.
"""
import struct
from dataclasses import dataclass

from .schema import LIMITS, FRAME_ERROR, SCHEMA

HEADER = struct.Struct("<BBBBHHIQHH")
assert HEADER.size == LIMITS.header_bytes
VERSION = SCHEMA["protocol_version"]


def _crc_table():
    table = []
    for n in range(256):
        c = n
        for _ in range(8):
            c = (c >> 1) ^ 0xEDB88320 if c & 1 else c >> 1
        table.append(c)
    return table


_TABLE = _crc_table()


def crc32(data, crc=0):
    """CRC-32/ISO-HDLC. crc32(b"123456789") == 0xCBF43926."""
    crc ^= 0xFFFFFFFF
    for b in data:
        crc = _TABLE[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF


class FrameError(ValueError):
    def __init__(self, code, detail=""):
        self.code = code
        self.name = FRAME_ERROR.name(code)
        super().__init__(f"{self.name}{': ' + detail if detail else ''}")


def cobs_encode(data):
    """COBS without the trailing delimiter. A full 254-byte block at the end adds no code."""
    out = bytearray([0])
    code_at, code = 0, 1
    for b in data:
        if b:
            out.append(b)
            code += 1
        if not b or code == 0xFF:
            out[code_at] = code
            code_at, code = len(out), 1
            out.append(0)
    out[code_at] = code
    if code == 1 and data and data[-1] != 0 and len(out) > 1 and code_at == len(out) - 1:
        # A 0xFF block ended exactly at the end of the input: drop the empty trailing group.
        out.pop()
    return bytes(out)


def cobs_decode(data):
    """Inverse of cobs_encode; data excludes the delimiter."""
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        code = data[i]
        if code == 0:
            raise FrameError(FRAME_ERROR.COBS_INVALID, "zero code byte")
        end = i + code
        if end > n:
            raise FrameError(FRAME_ERROR.COBS_INVALID, "block runs past end")
        block = data[i + 1:end]
        if 0 in block:
            raise FrameError(FRAME_ERROR.COBS_INVALID, "zero inside block")
        out += block
        i = end
        if code != 0xFF and i < n:
            out.append(0)
    return bytes(out)


@dataclass(frozen=True)
class Frame:
    channel: int
    kind: int
    opcode: int
    status: int = 0
    request_id: int = 0
    session_id: int = 0
    payload: bytes = b""
    version: int = VERSION
    flags: int = 0
    reserved: int = 0

    def header(self):
        return HEADER.pack(self.version, self.channel, self.kind, self.flags, self.opcode,
                           self.status, self.request_id, self.session_id, len(self.payload),
                           self.reserved)


def encode_frame(frame):
    """Decoded bytes: header || payload || crc32 (no COBS)."""
    if len(frame.payload) > LIMITS.max_payload:
        raise ValueError(f"payload {len(frame.payload)} > {LIMITS.max_payload}")
    body = frame.header() + bytes(frame.payload)
    return body + struct.pack("<I", crc32(body))


def wire_frame(frame):
    """Bytes for the UART: COBS(header || payload || crc32) || 0x00."""
    return cobs_encode(encode_frame(frame)) + b"\x00"


def decode_frame(encoded):
    """COBS-encoded bytes (delimiter removed) -> Frame, or raise FrameError."""
    if len(encoded) > LIMITS.max_encoded:
        raise FrameError(FRAME_ERROR.TOO_LONG, f"{len(encoded)} encoded bytes")
    raw = cobs_decode(encoded)
    return parse_frame(raw)


def parse_frame(raw):
    """Decoded bytes -> Frame, or raise FrameError."""
    if len(raw) > LIMITS.max_frame:
        raise FrameError(FRAME_ERROR.TOO_LONG, f"{len(raw)} decoded bytes")
    if len(raw) < LIMITS.header_bytes + LIMITS.crc_bytes:
        raise FrameError(FRAME_ERROR.TOO_SHORT, f"{len(raw)} bytes")
    ver, chan, kind, flags, op, status, rid, sid, length, reserved = HEADER.unpack_from(raw)
    if length > LIMITS.max_payload or LIMITS.header_bytes + length + LIMITS.crc_bytes != len(raw):
        raise FrameError(FRAME_ERROR.BAD_LENGTH, f"length field {length}, frame {len(raw)}")
    body, (crc,) = raw[:-4], struct.unpack("<I", raw[-4:])
    if crc32(body) != crc:
        raise FrameError(FRAME_ERROR.BAD_CRC)
    if ver != VERSION:
        raise FrameError(FRAME_ERROR.BAD_VERSION, str(ver))
    if flags or reserved:
        raise FrameError(FRAME_ERROR.BAD_RESERVED)
    if chan > 2:
        raise FrameError(FRAME_ERROR.BAD_CHANNEL, str(chan))
    if kind > 2:
        raise FrameError(FRAME_ERROR.BAD_KIND, str(kind))
    return Frame(chan, kind, op, status, rid, sid, bytes(body[LIMITS.header_bytes:]))


class StreamDecoder:
    """Bounded byte-stream receiver.

    feed() returns a list of Frame objects and FrameError objects in arrival order. Empty
    frames (back-to-back delimiters) are idle fill and are ignored. Bytes after an overflow are
    discarded through the next delimiter. A gap longer than the inter-byte timeout while a
    frame is half assembled discards it and reports TIMEOUT.
    """

    def __init__(self, timeout_ms=LIMITS.interbyte_timeout_ms):
        self.timeout_ms = timeout_ms
        self.buf = bytearray()
        self.overflow = False
        self.last_ms = None
        self.counts = {name: 0 for name in SCHEMA["frame_errors"]}

    def _error(self, err, out):
        self.counts[err.name] += 1
        out.append(err)

    def feed(self, data, now_ms=0):
        out = []
        for b in data:
            if (self.last_ms is not None and (self.buf or self.overflow)
                    and now_ms - self.last_ms > self.timeout_ms):
                self._error(FrameError(FRAME_ERROR.TIMEOUT), out)
                self.buf.clear()
                self.overflow = False
            self.last_ms = now_ms
            if b == 0:
                if self.overflow:
                    self._error(FrameError(FRAME_ERROR.TOO_LONG), out)
                elif self.buf:
                    try:
                        frame = decode_frame(bytes(self.buf))
                        self.counts["OK"] += 1
                        out.append(frame)
                    except FrameError as err:
                        self._error(err, out)
                self.buf.clear()
                self.overflow = False
            elif not self.overflow:
                if len(self.buf) == LIMITS.max_encoded:
                    self.overflow = True
                    self.buf.clear()
                else:
                    self.buf.append(b)
        return out

    def poll(self, now_ms):
        """Report a timeout without needing another byte."""
        if (self.last_ms is not None and (self.buf or self.overflow)
                and now_ms - self.last_ms > self.timeout_ms):
            self.buf.clear()
            self.overflow = False
            err = FrameError(FRAME_ERROR.TIMEOUT)
            self.counts[err.name] += 1
            return [err]
        return []
