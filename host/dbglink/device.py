"""Reference model of the FPGA debug endpoint for version 1 discovery, sessions and replay.

The RTL endpoint must produce the same reply bytes for the same request bytes and time; the
session vectors in protocol/vectors/sessions.txt are exported from this model and checked by
hand-written expectations in host/tests/test_device.py.

Rules (T2 subset: HELLO, PING, STATUS; every other opcode is UNSUPPORTED):
  * Only CRC-valid requests reach handle(); responses/events sent to the device are ignored.
  * Discovery: HELLO with session 0 and request ID 0, read-only, never stored.
  * Session 0 with any other opcode or a nonzero ID: BAD_SESSION / BAD_ARGUMENT, not stored.
  * Claim: HELLO with a new nonzero session when nobody holds an unexpired lease.
  * Another session while the lease is live: BUSY for HELLO, BAD_SESSION otherwise.
  * Owner request: ID equal to the stored one replays (identical bytes) or ID_CONFLICT;
    lower ID is STALE_REQUEST; ID 0 is BAD_ARGUMENT; a higher ID executes and is stored.
  * Every request that reaches execution renews the 2-second lease, including replays.
"""
from .codec import Frame, encode_frame
from .schema import (CHANNEL, CPU_STATE, KIND, LIMITS, OPCODE, OPERATION_STATE, SCHEMA,
                     SESSION_STATE, STATUS, HELLO_RESPONSE, STATUS_RESPONSE)

T2_CAPABILITIES = 1 << SCHEMA["capabilities"]["BASE_STATUS"]
CHANNEL_OF = {OPCODE.CONSOLE_READ: CHANNEL.CONSOLE, OPCODE.CONSOLE_WRITE: CHANNEL.CONSOLE,
              OPCODE.CONSOLE_STATUS: CHANNEL.CONSOLE}


class DebugDevice:
    def __init__(self, build_id=0x54320001, clock_hz=62_500_000, cpu_present=True):
        self.build_id = build_id
        self.clock_hz = clock_hz
        self.cpu_present = cpu_present
        self.frames_rejected = 0
        self.uart_overruns = 0
        self.executed = 0
        self.executed_by_op = {}
        self.reset()

    def reset(self):
        """Debug/board reset: clears the session and the replay slot."""
        self.owner = 0
        self.lease_until = 0
        self.last_id = 0
        self.last_request = b""
        self.last_reply = None
        self.cpu_state = CPU_STATE.RESET_HELD if self.cpu_present else CPU_STATE.ABSENT

    def _lease_live(self, now_ms):
        return self.owner != 0 and now_ms < self.lease_until

    def _reply(self, req, status, payload=b""):
        return Frame(req.channel, KIND.RESPONSE, req.opcode, status, req.request_id,
                     req.session_id, payload)

    def hello_payload(self, session_id, now_ms):
        if not self._lease_live(now_ms):
            state, left = SESSION_STATE.NONE, 0
        else:
            state = SESSION_STATE.YOURS if session_id == self.owner else SESSION_STATE.OTHER
            left = min(self.lease_until - now_ms, 0xFFFF)
        return HELLO_RESPONSE.pack(
            protocol_version=SCHEMA["protocol_version"], schema_minor=SCHEMA["schema_minor"],
            descriptor_bytes=HELLO_RESPONSE.size, build_id=self.build_id,
            isa_flags=1 if self.cpu_present else 0, clock_hz=self.clock_hz,
            max_payload=LIMITS.max_payload, max_chunk=LIMITS.max_chunk,
            capabilities=T2_CAPABILITIES, breakpoint_count=0, trace_format=0, trace_depth=0,
            cpu_state=self.cpu_state, operation_state=OPERATION_STATE.IDLE,
            session_state=state, lease_remaining_ms=left,
            operation_states_supported=1 << OPERATION_STATE.IDLE)

    def status_payload(self):
        return STATUS_RESPONSE.pack(
            cpu_state=self.cpu_state, halt_reason=0, operation_state=OPERATION_STATE.IDLE,
            valid=0, last_retired_pc=0, next_pc=0, image_id=0, operation_id=0,
            frames_rejected=self.frames_rejected, uart_overruns=self.uart_overruns,
            snapshot_generation=0)

    def _execute(self, req, now_ms):
        """Run one accepted request. Validation failures have no side effect."""
        if req.channel != CHANNEL_OF.get(req.opcode, CHANNEL.CONTROL) or req.status:
            return self._reply(req, STATUS.BAD_ARGUMENT)
        self.executed += 1
        self.executed_by_op[req.opcode] = self.executed_by_op.get(req.opcode, 0) + 1
        if req.opcode == OPCODE.HELLO:
            if req.payload:
                return self._reply(req, STATUS.BAD_ARGUMENT)
            return self._reply(req, STATUS.OK, self.hello_payload(req.session_id, now_ms))
        if req.opcode == OPCODE.PING:
            if len(req.payload) > LIMITS.max_ping_echo:
                return self._reply(req, STATUS.BAD_ARGUMENT)
            return self._reply(req, STATUS.OK, req.payload)
        if req.opcode == OPCODE.STATUS:
            if req.payload:
                return self._reply(req, STATUS.BAD_ARGUMENT)
            return self._reply(req, STATUS.OK, self.status_payload())
        return self._reply(req, STATUS.UNSUPPORTED)

    def handle(self, req, now_ms):
        """One CRC-valid decoded frame in; the reply Frame out, or None for no reply."""
        if req.kind != KIND.REQUEST:
            self.frames_rejected += 1
            return None
        if req.session_id == 0:
            if req.request_id != 0:
                return self._reply(req, STATUS.BAD_ARGUMENT)
            if req.opcode != OPCODE.HELLO:
                return self._reply(req, STATUS.BAD_SESSION)
            if req.channel != CHANNEL.CONTROL or req.status or req.payload:
                return self._reply(req, STATUS.BAD_ARGUMENT)
            return self._reply(req, STATUS.OK, self.hello_payload(0, now_ms))

        live = self._lease_live(now_ms)
        if not live and self.owner:
            self.owner, self.last_id, self.last_request, self.last_reply = 0, 0, b"", None
        if self.owner != req.session_id:
            if self.owner or req.opcode != OPCODE.HELLO:
                return self._reply(req, STATUS.BUSY if req.opcode == OPCODE.HELLO
                                   else STATUS.BAD_SESSION)
            if req.request_id == 0:
                return self._reply(req, STATUS.BAD_ARGUMENT)
            self.owner = req.session_id
            self.last_id = 0

        raw = encode_frame(req)
        if req.request_id == 0:
            return self._reply(req, STATUS.BAD_ARGUMENT)
        if req.request_id == self.last_id:
            if raw != self.last_request:
                return self._reply(req, STATUS.ID_CONFLICT)
            self.lease_until = now_ms + LIMITS.lease_ms
            return self.last_reply
        if req.request_id < self.last_id:
            return self._reply(req, STATUS.STALE_REQUEST)
        self.lease_until = now_ms + LIMITS.lease_ms
        reply = self._execute(req, now_ms)
        self.last_id, self.last_request, self.last_reply = req.request_id, raw, reply
        return reply
