# Prime sieve

Runs a bit-packed Sieve of Eratosthenes through 10,000 on the FPGA CPU. The 1,251-byte
composite array lives in main RAM. The program prints all 1,229 primes, sixteen per line,
then the count and a measured performance line over the USB console at 115200 8N1.

The interval covers initialization, sieving and counting. UART printing happens afterward.
Cycle and instruction reads are separate MMIO operations, so the small read overhead is
included; they are not an atomic debug snapshot. CPI is rounded to three decimal places
using a 64-bit intermediate and compatible RV32I libgcc helpers. No RV32M instructions
are enabled. On completion, LEDs read `7001`, the hex register reads BCD `1229`, and
startup halts at EBREAK.

From the repository root in WSL:

```bash
python3 scripts/build_software.py primes
python3 scripts/run_tests.py primes
```

`primes_tb` and `primes_pipe_tb` run the unchanged program on the full board top at
single-cycle 25 MHz and pipeline 62.5 MHz. They decode the actual TX pin and compare
`uart.expect` byte for byte, then independently check the variable performance record.
The fixture is also checked by trial division in the native tests.

For later physical testing, open this Windows checker before loading the primes bitstream
or pressing the center CPU-reset button. Substitute the board's current COM port:

```powershell
python scripts/primes_check.py --port COM8 --report build/phase7/board-primes.json --save-capture build/phase7/board-primes.bin
```

It uses the existing `scripts/requirements-host.txt` dependency, bounded reads and capture,
and never programs or resets the board. Close other serial terminals first. A saved
capture can be checked without pyserial using `--capture-file <file>`.

[Phase 7 build, evidence and remaining gate](../../../docs/phases/PHASE7_DEMOS.md)
