"""Blocking host client with safe identical retries, over any byte transport.

transport must provide write(bytes) and read(max_bytes, timeout_s) -> bytes. The client keeps
exactly one request outstanding, resends the identical bytes on timeout (at most three
retries) and drops any reply that does not match the outstanding session, ID and opcode.
"""
import os
import time

from .codec import Frame, FrameError, StreamDecoder, wire_frame
from .schema import CHANNEL, KIND, LIMITS, OPCODE, STATUS, HELLO_RESPONSE, STATUS_RESPONSE


class LinkError(RuntimeError):
    pass


class OutcomeUnknown(LinkError):
    """The request may have run; reconcile actual device state before another mutation."""


class SessionLost(LinkError):
    pass


class DeviceError(LinkError):
    def __init__(self, frame):
        self.frame = frame
        super().__init__(f"{OPCODE.name(frame.opcode)} -> {STATUS.name(frame.status)}")


class Client:
    def __init__(self, transport, clock=time.monotonic, timeout_ms=LIMITS.response_timeout_ms,
                 retries=LIMITS.max_retries):
        self.transport = transport
        self.clock = clock
        self.timeout_ms = timeout_ms
        self.retries = retries
        self.rx = StreamDecoder()
        self.session_id = 0
        self.last_id = 0
        self.stats = {"sent": 0, "retries": 0, "stale_replies": 0, "bad_frames": 0}

    def _now_ms(self):
        return int(self.clock() * 1000)

    def _await(self, req):
        deadline = self._now_ms() + self.timeout_ms
        while (left := deadline - self._now_ms()) > 0:
            data = self.transport.read(LIMITS.max_wire, left / 1000)
            for item in self.rx.feed(data, self._now_ms()) + self.rx.poll(self._now_ms()):
                if isinstance(item, FrameError):
                    self.stats["bad_frames"] += 1
                elif (item.kind == KIND.RESPONSE and item.request_id == req.request_id
                      and item.session_id == req.session_id and item.opcode == req.opcode
                      and item.channel == req.channel):
                    return item
                else:
                    self.stats["stale_replies"] += 1
        return None

    def transact(self, req):
        wire = wire_frame(req)
        for attempt in range(self.retries + 1):
            if attempt:
                self.stats["retries"] += 1
            self.transport.write(wire)
            self.stats["sent"] += 1
            reply = self._await(req)
            if reply is not None:
                return reply
        raise OutcomeUnknown(f"{OPCODE.name(req.opcode)} id {req.request_id}: no reply")

    def request(self, opcode, payload=b"", channel=CHANNEL.CONTROL, check=True):
        if not self.session_id:
            raise SessionLost("no session; call connect()")
        if self.last_id == 0xFFFFFFFF:
            raise SessionLost("request IDs exhausted; start a new session")
        self.last_id += 1
        reply = self.transact(Frame(channel, KIND.REQUEST, opcode, 0, self.last_id,
                                    self.session_id, bytes(payload)))
        if reply.status == STATUS.BAD_SESSION:
            self.session_id = 0
            raise SessionLost("device no longer recognises this session")
        if check and reply.status not in (STATUS.OK, STATUS.ACCEPTED):
            raise DeviceError(reply)
        return reply

    def discover(self):
        reply = self.transact(Frame(CHANNEL.CONTROL, KIND.REQUEST, OPCODE.HELLO))
        if reply.status != STATUS.OK:
            raise DeviceError(reply)
        return HELLO_RESPONSE.unpack(reply.payload)

    def connect(self, session_id=None):
        """Claim control with a fresh nonzero session ID and return the descriptor."""
        self.session_id = session_id or (int.from_bytes(os.urandom(8), "little") or 1)
        self.last_id = 0
        try:
            reply = self.request(OPCODE.HELLO)
        except DeviceError:
            self.session_id = 0
            raise
        return HELLO_RESPONSE.unpack(reply.payload)

    def ping(self, data=b""):
        reply = self.request(OPCODE.PING, data)
        if reply.payload != bytes(data):
            raise LinkError("PING echo mismatch")
        return reply

    def status(self):
        return STATUS_RESPONSE.unpack(self.request(OPCODE.STATUS).payload)
