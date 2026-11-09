#ifndef RVC_VGA_H
#define RVC_VGA_H

#include <stdint.h>

#define VGA_TEXT_COLUMNS 80u
#define VGA_TEXT_ROWS 30u
#define VGA_WIDTH 160u
#define VGA_HEIGHT 120u

enum vga_mode { VGA_TEXT = 0, VGA_PIXELS = 1, VGA_COLOR_BARS = 2, VGA_BLACK = 3 };

/* Waits for the frame-boundary acknowledgement; -1 for an invalid mode.
 * Call only while the pixel clock is running and global VGA reset is released. */
int vga_set_mode(enum vga_mode mode);
enum vga_mode vga_get_mode(void);
/* Wait for the START of the next blank; this does not reserve a whole frame. */
void vga_wait_vblank(void);
void vga_clear_text(void);
int vga_set_cursor(unsigned column, unsigned row);
void vga_putc(int character); /* CR/LF, backspace, 4-column tabs, wrap and scroll */
int vga_printf(const char *format, ...); /* %d %u %x %s %c %% */
int set_pixel(unsigned x, unsigned y, unsigned color); /* color 0..15; -1 invalid */
int clear(unsigned color); /* whole pixel framebuffer; -1 for color > 15 */
/* Clip a rectangle to the 160x120 framebuffer. Nonpositive sizes/invalid
 * colors return -1; a valid off-screen rectangle is a no-op. */
int fill_rect(int x, int y, int width, int height, unsigned color);
/* Pixel-mode text: 20x15 cells of 8x8 pixels, using the same public-domain
 * glyph source. Column/row are cells, not VGA text-mode coordinates. */
int vga_draw_text(unsigned column, unsigned row, const char *text,
                  unsigned foreground, unsigned background);
/* Expand a byte's bit0..7 into nibble masks 0/F, for packed rendering. */
uint32_t vga_expand_bits(uint8_t value);

/* Display memory is single-buffered. Draw into a hidden mode for large
 * updates, then switch modes. A vblank poll alone cannot prevent tearing
 * if an update runs past the end of the blank. Single-writer API. */
#endif
