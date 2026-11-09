"""Validate the existing RV32I build manifest before any device mutation."""
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import zlib


@dataclass(frozen=True)
class ProgramImage:
    data: bytes
    name: str
    bss_address: int
    bss_bytes: int

    def __post_init__(self):
        if not isinstance(self.data, bytes) or not 1 <= len(self.data) <= 0xD000:
            raise ValueError("image must contain 1..53248 initialized bytes")
        if not isinstance(self.name, str) or len(self.name.encode("utf-8")) > 48 or "\0" in self.name:
            raise ValueError("name must be UTF-8, at most 48 bytes, without NUL")
        if (type(self.bss_address) is not int or type(self.bss_bytes) is not int
                or self.bss_address % 4 or self.bss_bytes % 4 or self.bss_bytes < 0
                or not len(self.data) <= self.bss_address <= self.bss_address + self.bss_bytes <= 0xD000):
            raise ValueError("BSS must be word aligned, after the image and below scratch")

    @property
    def crc32(self):
        return zlib.crc32(self.data) & 0xFFFFFFFF

    @classmethod
    def from_manifest(cls, path):
        """Read build_software.py's .json plus its adjacent .bin; trust no paths in JSON."""
        path = Path(path)
        manifest = json.loads(path.read_text(encoding="utf-8"))
        with path.with_suffix(".bin").open("rb") as binary:
            data = binary.read(0xD001)
        if not 1 <= len(data) <= 0xD000:
            raise ValueError("binary is empty or exceeds the 52-KiB initialized-image limit")
        if (manifest.get("schema_version") != 1 or manifest.get("isa") != "rv32i"
                or manifest.get("abi") != "ilp32" or manifest.get("load_address") != 0
                or manifest.get("entry_address") != 0
                or manifest.get("image_bytes") != len(data)
                or manifest.get("image_padded_bytes") != ((len(data) + 3) & ~3)
                or manifest.get("scratch") != {"start": 0xD000, "end": 0xE000}
                or manifest.get("stack") != {"start": 0xE000, "end": 0x10000}):
            raise ValueError("manifest architecture, length, entry or reserved ranges do not match")
        if (manifest.get("image_crc32") != f"{zlib.crc32(data) & 0xFFFFFFFF:08x}"
                or manifest.get("image_sha256") != hashlib.sha256(data).hexdigest()):
            raise ValueError("binary CRC32/SHA256 does not match the build manifest")
        bss, heap = manifest["bss"], manifest["heap"]
        image = cls(data, manifest["name"], bss["start"], bss["end"] - bss["start"])
        if not bss["end"] <= heap["start"] <= heap["end"] == 0xD000:
            raise ValueError("manifest heap overlaps BSS or reserved RAM")
        return image
