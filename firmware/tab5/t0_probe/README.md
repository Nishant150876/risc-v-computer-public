[Project README](../../../README.md) › [firmware/tab5](../README.md) › **t0_probe/**

# `t0_probe/`: Tab5 bring-up check (milestone T0)

A small ESP-IDF app that checks the four T0 peripherals on the real Tab5 and prints every result
to the serial monitor with a `T0:` prefix.

| Check | How it passes |
| --- | --- |
| Display | You see four bars: red, green, blue, white, left to right. |
| Touch | Tap the four numbered corner squares; each turns green, then `TOUCH: PASS`. |
| microSD | Mounts the card, writes 64 KiB, reads it back, compares, writes `T0PROBE.TXT`. |
| UART | UART1 at 115200 8N1 on PORT.A: TX = G53, RX = G54. Sends bytes 0–255 every 2 s and checks the echo. |

## Versions

| Item | Version |
| --- | --- |
| ESP-IDF | v5.5.6 |
| Tab5 BSP | `espressif/m5stack_tab5` 1.3.2 (auto-detects ILI9881C, ST7123 and ST7121 panels) |
| Chip setting | `CONFIG_ESP32P4_SELECTS_REV_LESS_V3=y` |

The first build writes `dependencies.lock` with every resolved component version. Commit it.

## Build and flash

In the **ESP-IDF 5.5 PowerShell** window:

```
cd C:\Users\Nisha\OneDrive\Desktop\risc-v-computer\firmware\tab5\t0_probe
idf.py set-target esp32p4
idf.py build
idf.py -p COMx flash monitor
```

Replace `COMx` with the Tab5's port from Device Manager. Exit the monitor with `Ctrl+]`.

## UART loopback jumper

> [!WARNING]
> Connect **only G53 to G54** on PORT.A. Do not touch the 5V pin. Nothing else goes on PORT.A
> for this test, and the Basys 3 stays disconnected until the T0 pin and power table is approved.

Without the jumper the screen shows `UART: no echo`. With it, `UART: PASS`.

## Recovery

To go back to the factory demo, flash M5Stack's Tab5 factory firmware with M5Burner. If the
port does not appear, put the Tab5 in download mode using the button described on its rear
label and in M5Stack's Tab5 docs, then flash again.

## What to record

Copy the monitor lines that start with `T0:` and the BSP line `Discovered board version ...`
into the T0 record in [HARDWARE_CHECKLIST.md](../../../docs/tab5/HARDWARE_CHECKLIST.md#2-t0-identification-record).
