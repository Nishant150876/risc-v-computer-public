"""Phase 7: real engine code under ASan/UBSan, independent output and image contracts."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/"scripts"))
import build_software
import run_tests
import primes_check


@unittest.skipUnless(shutil.which("gcc"),"native GCC required")
class EngineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.temp.name)/"demos_test"
        common = REPO/"sw/common"
        programs = REPO/"sw/programs"
        command = ["gcc","-std=c11","-O2","-Wall","-Wextra","-Werror","-fno-builtin",
                   "-fsanitize=address,undefined","-fno-pie","-no-pie","-I",str(common)]
        for name,engine in (("life","life.c"),("snake","snake.c"),("primes","sieve.c")):
            command += ["-I",str(programs/name),str(programs/name/engine)]
        command += [str(common/"rand.c"),str(common/"buttons.c"),
                    str(REPO/"scripts/tests/demos_test.c"),"-o",str(cls.binary)]
        result = subprocess.run(command,capture_output=True,text=True)
        if result.returncode: raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def check_engine(self,name):
        result = subprocess.run([str(self.binary),name],capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn("PASS:",result.stdout)

    def test_sieve(self): self.check_engine("sieve")
    def test_helpers(self): self.check_engine("helpers")
    def test_life_patterns(self): self.check_engine("life_patterns")
    def test_life_boundaries(self): self.check_engine("life_boundaries")
    def test_snake_controls(self): self.check_engine("snake_controls")
    def test_snake_ring(self): self.check_engine("snake_ring")
    def test_snake_full(self): self.check_engine("snake_full")


class DemoIntegrationTests(unittest.TestCase):
    def test_board_capture_validation_and_rejections(self):
        fixed = primes_check.expected_output()
        valid = fixed+b"cycles 315458 instret 258430 CPI 1.221\r\n"
        self.assertEqual(primes_check.validate(valid)["prime_count"],1229)
        self.assertTrue(primes_check.validate(b"old firmware noise\r\n"+valid)["passed"])
        for bad in (valid[:-1],valid+b"X",valid.replace(b"9973",b"9971"),
                    valid.replace(b"1.221",b"1.222"),fixed+b"cycles 0 instret 0 CPI 0.000\r\n",
                    valid+b"x"*16384):
            with self.subTest(suffix=bad[-50:]),self.assertRaises(ValueError): primes_check.validate(bad)

    def test_failed_capture_cannot_leave_old_pass_report(self):
        import json
        with tempfile.TemporaryDirectory() as tmp:
            capture,report = Path(tmp)/"capture.bin",Path(tmp)/"report.json"
            capture.write_bytes(b"corrupt")
            report.write_text('{"passed":true}')
            result = subprocess.run([sys.executable,str(REPO/"scripts/primes_check.py"),"--capture-file",str(capture),"--report",str(report)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(json.loads(report.read_text())["passed"])

    def test_demo_runner_profiles(self):
        for name in ("primes","life","snake"):
            programs = [p for _,p in run_tests.find_programs(None) if p.source.parent.name == name]
            self.assertEqual({p.bench for p in programs},{f"{name}_tb",f"{name}_pipe_tb"})
            self.assertEqual(run_tests.BENCH_CPU_HZ[f"{name}_pipe_tb"],62_500_000)
            self.assertEqual(run_tests.WRAPPED_BENCHES[f"{name}_pipe_tb"],f"{name}_tb")

    def test_prime_fixture_independent_trial_division(self):
        primes = [n for n in range(2,10001) if all(n%d for d in range(2,int(n**0.5)+1))]
        lines = ["primes <= 10000"]
        lines += [" ".join(map(str,primes[i:i+16])) for i in range(0,len(primes),16)]
        lines += ["count 1229"]
        self.assertEqual((REPO/"sw/programs/primes/uart.expect").read_text(),"\n".join(lines)+"\n")

    def test_demo_images_rv32i_and_bounds(self):
        import json
        prefix = run_tests.find_gcc_prefix()
        self.assertIsNotNone(prefix,"complete RV32 toolchain required")
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("primes","life","snake"):
                for hz in (25_000_000,62_500_000):
                    with self.subTest(program=name,cpu_hz=hz):
                        output = Path(tmp)/f"{name}-{hz}"
                        build_software.build(REPO/f"sw/programs/{name}/main.c",output,prefix,hz)
                        meta = json.loads((output/f"{name}.json").read_text())
                        self.assertEqual((meta["isa"],meta["abi"],meta["entry_address"]),("rv32i","ilp32",0))
                        self.assertEqual(meta["configured_cpu_hz"],hz)
                        self.assertLess(meta["image_padded_bytes"],0xd000)


if __name__ == "__main__": unittest.main()
