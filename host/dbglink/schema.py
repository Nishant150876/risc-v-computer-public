"""Loads protocol/schema.json, the single source for every number in the protocol."""
import json
import struct
from pathlib import Path
from types import SimpleNamespace

SCHEMA_PATH = Path(__file__).resolve().parents[2] / "protocol" / "schema.json"
SCHEMA = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
LIMITS = SimpleNamespace(**SCHEMA["limits"])


class Table(SimpleNamespace):
    """Name -> value table with reverse lookup."""

    def __init__(self, mapping):
        super().__init__(**mapping)
        self._names = {v: k for k, v in mapping.items()}

    def name(self, value):
        return self._names.get(value, f"0x{value:X}")


CHANNEL = Table(SCHEMA["channels"])
KIND = Table(SCHEMA["kinds"])
OPCODE = Table(SCHEMA["opcodes"])
STATUS = Table(SCHEMA["status"])
FRAME_ERROR = Table(SCHEMA["frame_errors"])
CAPABILITY = Table(SCHEMA["capabilities"])
CPU_STATE = Table(SCHEMA["cpu_states"])
OPERATION_STATE = Table(SCHEMA["operation_states"])
LINK_STATE = Table(SCHEMA["link_states"])
SESSION_STATE = Table(SCHEMA["session_states"])

_FORMAT = {"u8": "B", "u16": "H", "u32": "I", "u64": "Q"}


class Layout:
    """Packed little-endian payload layout from the schema."""

    def __init__(self, name):
        self.fields = [f for f, _ in SCHEMA["payloads"][name]]
        self.struct = struct.Struct("<" + "".join(_FORMAT[t] for _, t in SCHEMA["payloads"][name]))
        self.size = self.struct.size

    def pack(self, **values):
        missing = set(self.fields) - set(values) - {f for f in self.fields if f.startswith("reserved")}
        extra = set(values) - set(self.fields)
        if missing or extra:
            raise KeyError(f"missing {sorted(missing)} extra {sorted(extra)}")
        return self.struct.pack(*(values.get(f, 0) for f in self.fields))

    def unpack(self, data):
        if len(data) != self.size:
            raise ValueError(f"payload is {len(data)} bytes, layout needs {self.size}")
        return dict(zip(self.fields, self.struct.unpack(data)))


HELLO_RESPONSE = Layout("HELLO_RESPONSE")
STATUS_RESPONSE = Layout("STATUS_RESPONSE")
