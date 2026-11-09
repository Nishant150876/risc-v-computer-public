# Conway's Game of Life

B3/S23 on a finite 160 x 120 board: outside cells are dead, with no wrapping. The FPGA CPU
owns two bit-packed 2,400-byte grids and computes each generation. The engine counts
neighbors for 32 cells at once with three bit planes; a count of eight wraps to zero,
which is harmless because neither count survives or births a cell.

Rendering expands eight cells into one packed framebuffer word using a 256-entry color
table. Live cells are palette A (light green). The code writes all 2,400 framebuffer
words at a fresh vertical blank. Initialization and restarts draw while BLACK mode is
displayed, then request PIXELS at a frame boundary. Normal pacing is four steps per second
by the configured CPU cycle counter, with computation and frame alignment delaying the
visible update slightly.

| Control | Behavior |
| --- | --- |
| SW0 | Glider |
| SW1 | Gosper glider gun |
| SW2 | R-pentomino |
| SW3 | Random, approximately 25% live; seed from cycle counter |
| BTNU | Restart using the selected pattern |
| SW15 | Manual mode; BTNR advances one generation per new press |
| BTNC | CPU reset |

The lowest numbered enabled pattern switch wins; all four off also selects glider.
Pattern changes take effect on restart. Held buttons do not repeat. The hex display
shows the generation modulo 10,000 in BCD. LEDs show `7100 | (1 << active_pattern)`;
bit 15 sticks if an ordinary redraw finishes after vertical blank. A fresh restart
clears that diagnostic. The framebuffer is single buffered, so the blank budget must
be remeasured if the code, compiler or CPU clock changes.

```bash
python3 scripts/build_software.py life
python3 scripts/run_tests.py life
```

Native sanitized tests compare every cell with a naive model for all four patterns and
exercise packed-word boundaries and finite edges. The full-board benches run the real
ELF on both CPUs, check glider movement, RLE-derived gun and R-pentomino images, restart/
held-button behavior, real timer pacing and complete physical VGA output frames.

The 36-cell gun uses the canonical 36 x 9 pattern, offset to (8,8); its independent RLE
oracle is in `tb/system/life_tb.sv`. Provenance:
[LifeWiki Gosper glider gun](https://conwaylife.com/wiki/GGG) and the
[Golly pattern RLE](https://github.com/mzfy/golly/blob/master/Guns/Gosper%20Glider%20Gun.rle).
The glider is at (16,16); the R-pentomino is centered at (80,60).

[Phase 7 build, previews and remaining gate](../../../docs/phases/PHASE7_DEMOS.md)
