# Phase 7 presentation assets

The ten PNG files are actual simulated FPGA RGB pin captures, not artwork, mockups or
physical-monitor photos. Each source bench compared every pixel before reporting PASS.
[provenance.json](provenance.json) records the source capture, bench and SHA-256 hashes.
Base benches use the single-cycle CPU at 25 MHz; pipeline equivalents also passed.

| Files | State |
| --- | --- |
| life-glider-0 / life-glider-4 | Glider before and after four generations |
| life-gun | Canonical Gosper gun, initial state |
| life-rpentomino | R-pentomino, initial state |
| snake-start / snake-score-1 | Initial training game and first food/growth |
| snake-turn / snake-paused | First accepted queued turn; paused game |
| snake-game-over / snake-restarted | Top-wall collision and fresh restart |

Generate the source PPMs and convert any selected frame, from the repo root in WSL:

```bash
python3 scripts/run_tests.py life --evidence-dir build/phase7/simulation
python3 scripts/run_tests.py snake --evidence-dir build/phase7/simulation
python3 scripts/vga_preview.py build/phase7/simulation/life_tb/life/life-gun-0.ppm docs/images/phase7/life-gun.png
python3 scripts/vga_preview.py build/phase7/simulation/snake_tb/snake/snake-game-over.ppm docs/images/phase7/snake-game-over.png
```

Only trust captures accompanied by a successful run record. The PPM/PNG converter uses
the standard library and rejects incomplete images.

[architecture-sheet.pdf](architecture-sheet.pdf) is a one-page printable overview,
visually rendered and checked. Its editable content is described in
[ARCHITECTURE.md](../../ARCHITECTURE.md). It labels pending physical acceptance and
planned Tab5 integration explicitly. The remaining real photos/video are tracked in
[Phase 7](../../phases/PHASE7_DEMOS.md#6-acceptance-that-remains).
