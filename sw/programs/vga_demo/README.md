# VGA demonstration

Runs on the custom RV32I CPU. It blanks the monitor while building a text
screen and a 160x120, 16-color pattern, then switches at vertical blank.
Both switches off: alternate text and pixels about every two seconds.
SW0: hold pixels. SW1: show eight color bars (takes priority).
LEDs `6006` and hex `6404` mean initialization finished.

The scaled framebuffer has distinctive logical corner pixels: red at top
left, green at top right, blue at bottom left and white at bottom right.
Each pixel occupies a 4x4 screen block. These modes share the VGA output;
they do not overlay text on graphics.

Build with `python3 scripts/build_software.py vga_demo --cpu-hz 25000000`.
Use the actual configured CPU frequency when selecting another hardware
clock. [Phase 6](../../../docs/phases/PHASE6_VGA.md) describes simulation,
the memory map and the still-unrun monitor gate. The physical monitor gate remains unrun.
