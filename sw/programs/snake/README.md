# Snake

A 40 x 26 playfield with 4 x 4 pixel cells, rendered as 3 x 3 squares with a one-pixel
gap. Two 8-pixel HUD rows occupy the top of the 160 x 120 framebuffer. The HUD uses
the same pinned public-domain font as the hardware text mode, drawn by C so text and
graphics appear together without changing the VGA hardware.

The CPU maintains a 1,040-entry ring of packed segment coordinates and a separate
occupancy map. Each tick checks walls and body collisions, removes the old tail
unless growing, adds the new head, and chooses food using bounded xorshift32 plus
linear search for an empty cell. Moving into a departing tail is legal; reversing
direction or accepting two turns before a tick is not. Filling the board wins.

| Control | Behavior |
| --- | --- |
| BTNU / BTNL / BTNR / BTND | Up / Left / Right / Down; new presses only |
| BTNU after game over or win | Restart |
| BTNC | CPU reset |
| SW0 | Pause |
| SW1 | Slow: 4 ticks/s; otherwise 8 ticks/s |
| SW12 | Reproducible training seed 2377, selected at restart; first food is one cell ahead |
| SW15 | Manual mode |
| SW14 rising edge in manual mode | Advance one tick; direction buttons still queue turns |

Ordinary play seeds from cycles. The first accepted direction per tick wins; simultaneous
press priority is U, L, R, D. Paused direction presses may queue the next turn, but stepping
is disabled. The score appears in the pixel HUD and as four BCD digits on the hex display.
The body is light green (A), head yellow (E) and food light red (C).

LEDs: bit 9 ready, bits 7:0 tick modulo 256, bit 10 sticky redraw-overrun diagnostic,
bit 11 manual, bit 12 training, bit 13 paused, bit 14 won, bit 15 dead. Controls that
change flags are reflected at the next published update. Restart clears the overrun flag.
Initial drawing is hidden; later incremental draws wait for a fresh vertical blank.

```bash
python3 scripts/build_software.py snake
python3 scripts/run_tests.py snake
```

Native sanitized tests cover growth, turn guards, wall/body collision, legal tail entry,
over four complete ring-buffer revolutions and a full-board win. Full-board benches
press the actual inputs, verify the real 125 ms timer and compare six complete VGA
frames with an independent deque and glyph model on both CPUs.

[Phase 7 build, previews and remaining gate](../../../docs/phases/PHASE7_DEMOS.md)
