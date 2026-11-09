# VGA font source

`font8x8_basic.h` is Daniel Hepper's public-domain Basic Latin font, vendored
unchanged from [dhepper/font8x8](https://github.com/dhepper/font8x8/blob/8e279d2d864e79128e96188a6b9526cfa3fbfef9/font8x8_basic.h),
commit `8e279d2d864e79128e96188a6b9526cfa3fbfef9`.
Its original attribution and explicit **Public Domain** notice are preserved.
SHA-256: `49d8df366296b203ca3211bc0672cf2a762135bf12710735b6292756b19dffd5`.

Run `python3 scripts/font2mem.py` from the repository root to regenerate
`rtl/mem/font_rom.mem`, or append `--check` to verify it without writing.
The standard-library-only converter doubles each 8-pixel source row into an
8x16 cell and reverses source bits to make bit 7 the leftmost output pixel.
This is an explicitly doubled 8x8 font, not a separately drawn 16-row font.
ASCII 32..126 is printable; controls and codes 128..255 are blank.
The ROM has 256 glyphs x 16 rows = 4096 bytes. Glyph row address is
`character * 16 + row`. No runtime font download is required.

Phase 7 also draws 8x8 text into the pixel framebuffer. Generate or verify its C
header from this same source:

```bash
python3 scripts/font2mem.py --c-header sw/common/vga_font8x8.inc
python3 scripts/font2mem.py --check --c-header sw/common/vga_font8x8.inc
```

The C rows retain bit 0 at the left. The native tests check the conversion and every
printable glyph's pixel packing. This header does not change the hardware font ROM.
