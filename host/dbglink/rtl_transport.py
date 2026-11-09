"""Linux/WSL transport to the real dbg_system RTL, using a cached Verilator build.

Simulation clocks advance during requests and bounded idle windows. This is
functional co-simulation, not a real-time timing or physical hardware claim.
"""
import hashlib
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time

from .client import LinkError, OutcomeUnknown
from .schema import LIMITS

REPO=Path(__file__).resolve().parents[2]
SERVER=REPO/"tb/debug/dbg_host_server.sv"


class RtlTransport:
    def __init__(self):
        if os.name!="posix" or not shutil.which("verilator") or not shutil.which("g++"):
            raise LinkError("--rtl-sim requires Linux/WSL with Verilator and g++")
        self.directory=None
        self.process=None
        self.request_fd=self.reply_fd=None
        self.line=bytearray()
        self.pending=b""
        binary=self._build()
        try:
            self.directory=tempfile.TemporaryDirectory(prefix="rvc-debug-")
            folder=Path(self.directory.name)
            request_path,reply_path=folder/"requests",folder/"replies"
            os.mkfifo(request_path); os.mkfifo(reply_path)
            self.request_fd=os.open(request_path,os.O_RDWR|os.O_NONBLOCK)
            self.reply_fd=os.open(reply_path,os.O_RDWR|os.O_NONBLOCK)
            self.log_path=folder/"simulator.log"
            self.log=self.log_path.open("w")
            self.process=subprocess.Popen([str(binary),f"+requests={request_path}",f"+replies={reply_path}"],
                cwd=REPO,stdout=self.log,stderr=subprocess.STDOUT)
        except Exception:
            self.close()
            raise

    @staticmethod
    def _build():
        sources=sorted((REPO/"rtl").rglob("*.sv"))
        sources=sorted(sources,key=lambda p:(not p.stem.endswith("_pkg"),str(p)))+[SERVER]
        version=subprocess.check_output(["verilator","--version"])
        digest=hashlib.sha256(version)
        for source in sources:
            digest.update(str(source.relative_to(REPO)).encode()); digest.update(source.read_bytes())
        cache=Path(os.environ.get("RVC_RTL_SIM_CACHE",Path.home()/".cache/risc-v-computer/rtl-link"))/digest.hexdigest()[:16]
        binary=cache/"Vdbg_host_server"
        if binary.exists() and (cache/"passed-build").exists(): return binary
        cache.mkdir(parents=True,exist_ok=True)
        result=subprocess.run(["verilator","--binary","--timing","--assert","-Wall","-j","2",
            "--top-module","dbg_host_server","--Mdir",str(cache),*[str(s) for s in sources]],
            cwd=REPO,capture_output=True,text=True)
        (cache/"build.log").write_text(result.stdout+result.stderr)
        if result.returncode:
            raise LinkError("RTL simulator build failed: "+"\n".join((result.stdout+result.stderr).splitlines()[-12:]))
        (cache/"passed-build").write_text("Verilator -Wall build returned 0\n")
        return binary

    def write(self,data):
        if not 1<=len(data)<=LIMITS.max_wire: raise ValueError("one bounded packet per write")
        wire=bytes(data).hex().encode()+b"\n"
        try:
            if os.write(self.request_fd,wire)!=len(wire): raise OSError("partial FIFO write")
        except OSError as error:
            raise OutcomeUnknown(f"RTL simulator request could not be delivered: {error}") from error

    def read(self,n,timeout_s):
        deadline=time.monotonic()+timeout_s
        while not self.pending:
            if self.process.poll() is not None:
                detail=self.log_path.read_text(errors="replace")[-1200:]
                raise OutcomeUnknown(f"RTL simulator stopped; last request may have executed:\n{detail}")
            remaining=deadline-time.monotonic()
            if remaining<=0: return b""
            if select.select([self.reply_fd],[],[],min(remaining,0.05))[0]:
                self.line.extend(os.read(self.reply_fd,2048))
                if len(self.line)>LIMITS.max_wire*2+1: raise LinkError("unbounded simulator reply")
                if b"\n" in self.line:
                    line,rest=self.line.split(b"\n",1); self.line=bytearray(rest)
                    try: self.pending=bytes.fromhex(line.decode("ascii"))
                    except (ValueError,UnicodeError) as error: raise LinkError("invalid simulator wire reply") from error
        result,self.pending=self.pending[:n],self.pending[n:]
        return result

    def close(self):
        if self.process is not None:
            try:
                if self.request_fd is not None: os.write(self.request_fd,b".\n")
                self.process.wait(timeout=2)
            except (OSError,subprocess.TimeoutExpired):
                self.process.terminate()
                try: self.process.wait(timeout=2)
                except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
            self.process=None
        for fd in (self.request_fd,self.reply_fd):
            if fd is not None: os.close(fd)
        self.request_fd=self.reply_fd=None
        if hasattr(self,"log"): self.log.close()
        if self.directory is not None: self.directory.cleanup(); self.directory=None

    def __enter__(self): return self
    def __exit__(self,*args): self.close()
