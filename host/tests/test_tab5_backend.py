"""Compile/run the exact Tab5 backend and C codec natively with sanitizers."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO=Path(__file__).resolve().parents[2]
MAIN=REPO/"firmware/tab5/t1_ui/main"
CODEC=REPO/"firmware/tab5/components/dbglink"


@unittest.skipUnless(shutil.which("gcc"),"native GCC required")
class Tab5Worker(unittest.TestCase):
    def test_exact_worker_codec_and_state_with_sanitizers(self):
        with tempfile.TemporaryDirectory() as folder:
            out=Path(folder)/"link_worker"
            command=["gcc","-std=gnu11","-Wall","-Wextra","-Werror","-g",
                     "-fsanitize=address,undefined","-fno-pie","-no-pie",f"-I{MAIN}",f"-I{CODEC/'include'}",
                     str(MAIN/"../sim/test_link_device.c"),str(MAIN/"device/link_device.c"),str(MAIN/"state/app_state.c"),
                     str(CODEC/"dbglink.c"),str(CODEC/"dbglink_client.c"),"-o",str(out)]
            build=subprocess.run(command,capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            run=subprocess.run([str(out)],capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn("PASS:",run.stdout)


if __name__=="__main__": unittest.main()
