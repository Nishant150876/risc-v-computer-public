#include "vga.h"
#include "mmio.h"
#include <stdarg.h>
#include "vga_font8x8.inc"

/* Overrides let the native C contract test exercise this exact source with
 * a bounded MMIO model. Production builds use ordinary volatile accesses. */
#ifndef RVC_VGA_READ32
#define RVC_VGA_READ32(address) mmio_read32(address)
#define RVC_VGA_WRITE32(address, value) mmio_write32(address, value)
#define RVC_VGA_WRITE8(address, value) (*(volatile uint8_t *)(uintptr_t)(address) = (uint8_t)(value))
#endif

static unsigned cursor_column, cursor_row;

int vga_set_mode(enum vga_mode mode) {
    if ((unsigned)mode > VGA_BLACK) return -1;
    while (RVC_VGA_READ32(RVC_VGA_STATUS_ADDR) & RVC_VGA_MODE_PENDING) { }
    RVC_VGA_WRITE32(RVC_VGA_CONTROL_ADDR, (unsigned)mode);
    while (RVC_VGA_READ32(RVC_VGA_STATUS_ADDR) & RVC_VGA_MODE_PENDING) { }
    return 0;
}

enum vga_mode vga_get_mode(void) {
    return (enum vga_mode)((RVC_VGA_READ32(RVC_VGA_STATUS_ADDR) >> 2) & 3u);
}

void vga_wait_vblank(void) {
    while (RVC_VGA_READ32(RVC_VGA_STATUS_ADDR) & RVC_VGA_VBLANK) { }
    while (!(RVC_VGA_READ32(RVC_VGA_STATUS_ADDR) & RVC_VGA_VBLANK)) { }
}

void vga_clear_text(void) {
    for (unsigned word = 0; word < 600; ++word)
        RVC_VGA_WRITE32(RVC_VGA_TEXT_ADDR + word * 4u, UINT32_C(0x20202020));
    cursor_column = cursor_row = 0;
}

int vga_set_cursor(unsigned column, unsigned row) {
    if (column >= VGA_TEXT_COLUMNS || row >= VGA_TEXT_ROWS) return -1;
    cursor_column = column;
    cursor_row = row;
    return 0;
}

static void next_line(void) {
    cursor_column = 0;
    if (++cursor_row < VGA_TEXT_ROWS) return;
    for (unsigned word = 0; word < 580; ++word) {
        uint32_t value = RVC_VGA_READ32(RVC_VGA_TEXT_ADDR + (word + 20u) * 4u);
        RVC_VGA_WRITE32(RVC_VGA_TEXT_ADDR + word * 4u, value);
    }
    for (unsigned word = 580; word < 600; ++word)
        RVC_VGA_WRITE32(RVC_VGA_TEXT_ADDR + word * 4u, UINT32_C(0x20202020));
    cursor_row = VGA_TEXT_ROWS - 1u;
}

void vga_putc(int character) {
    if (character == '\r') { cursor_column = 0; return; }
    if (character == '\n') { next_line(); return; }
    if (character == '\b') {
        if (cursor_column) {
            --cursor_column;
            RVC_VGA_WRITE8(RVC_VGA_TEXT_ADDR + cursor_row * 80u + cursor_column, ' ');
        }
        return;
    }
    if (character == '\t') {
        unsigned spaces = 4u - (cursor_column & 3u);
        while (spaces--) vga_putc(' ');
        return;
    }
    unsigned byte = (unsigned)character;
    if (byte < 32 || byte > 126) byte = '?';
    RVC_VGA_WRITE8(RVC_VGA_TEXT_ADDR + cursor_row * 80u + cursor_column, byte);
    if (++cursor_column == VGA_TEXT_COLUMNS) next_line();
}

int set_pixel(unsigned x, unsigned y, unsigned color) {
    if (x >= VGA_WIDTH || y >= VGA_HEIGHT || color > 15) return -1;
    uint32_t address = RVC_VGA_PIXELS_ADDR + y * 80u + (x >> 3) * 4u;
    unsigned shift = (x & 7u) * 4u;
    uint32_t word = RVC_VGA_READ32(address);
    word = (word & ~(UINT32_C(15) << shift)) | ((uint32_t)color << shift);
    RVC_VGA_WRITE32(address, word);
    return 0;
}

int clear(unsigned color) {
    if (color > 15) return -1;
    uint32_t word = color;
    word |= word << 4;
    word |= word << 8;
    word |= word << 16;
    for (unsigned n = 0; n < 2400; ++n)
        RVC_VGA_WRITE32(RVC_VGA_PIXELS_ADDR + n * 4u, word);
    return 0;
}

uint32_t vga_expand_bits(uint8_t value) {
    uint32_t bits = value;
    bits = (bits | (bits << 12)) & UINT32_C(0x000f000f);
    bits = (bits | (bits << 6)) & UINT32_C(0x03030303);
    bits = (bits | (bits << 3)) & UINT32_C(0x11111111);
    return (bits << 4) - bits;
}

static uint32_t repeated_color(unsigned color) {
    uint32_t value = color;
    value |= value << 4; value |= value << 8; value |= value << 16;
    return value;
}

int fill_rect(int x, int y, int width, int height, unsigned color) {
    if (width <= 0 || height <= 0 || color > 15) return -1;
    if (x < 0) { width += x; x = 0; }
    if (y < 0) { height += y; y = 0; }
    if (x >= 160 || y >= 120 || width <= 0 || height <= 0) return 0;
    if (width > 160-x) width = 160-x;
    if (height > 120-y) height = 120-y;
    uint32_t pattern = repeated_color(color);
    for (int row = y; row < y+height; ++row) {
        unsigned remaining = (unsigned)width, px = (unsigned)x;
        while (remaining) {
            unsigned lane = px & 7u, count = 8u-lane;
            if (count > remaining) count = remaining;
            uint32_t address = RVC_VGA_PIXELS_ADDR + (unsigned)row*80u + (px >> 3)*4u;
            uint32_t mask = (UINT32_MAX >> (32u-count*4u)) << (lane*4u);
            uint32_t value = mask == UINT32_MAX ? pattern :
                (RVC_VGA_READ32(address) & ~mask) | (pattern & mask);
            RVC_VGA_WRITE32(address,value);
            px += count; remaining -= count;
        }
    }
    return 0;
}

int vga_draw_text(unsigned column, unsigned row, const char *text,
                  unsigned foreground, unsigned background) {
    if (column >= 20 || row >= 15 || !text || foreground > 15 || background > 15) return -1;
    uint32_t fg = repeated_color(foreground), bg = repeated_color(background);
    unsigned count = 0;
    while (*text && column < 20) {
        unsigned code = (unsigned char)*text++;
        if (code < 32 || code > 126) code = '?';
        for (unsigned line = 0; line < 8; ++line) {
            uint32_t mask = vga_expand_bits(rvc_font8x8[code][line]);
            RVC_VGA_WRITE32(RVC_VGA_PIXELS_ADDR + (row*8u+line)*80u + column*4u,
                            (fg & mask) | (bg & ~mask));
        }
        ++column; ++count;
    }
    return (int)count;
}

static uint32_t divide10(uint32_t value, uint32_t *remainder) {
    uint32_t quotient = 0, rem = 0;
    for (int bit = 31; bit >= 0; --bit) {
        rem = (rem << 1) | ((value >> bit) & 1u);
        if (rem >= 10) { rem -= 10; quotient |= UINT32_C(1) << bit; }
    }
    *remainder = rem;
    return quotient;
}

static int decimal(uint32_t value) {
    char digits[10];
    int count = 0;
    do {
        uint32_t remainder;
        value = divide10(value, &remainder);
        digits[count++] = (char)('0' + remainder);
    } while (value);
    for (int i = count - 1; i >= 0; --i) vga_putc(digits[i]);
    return count;
}

static int hexadecimal(uint32_t value) {
    static const char digits[] = "0123456789abcdef";
    int nibble = 7;
    while (nibble > 0 && ((value >> (nibble * 4)) & 15u) == 0) --nibble;
    int count = nibble + 1;
    for (; nibble >= 0; --nibble) vga_putc(digits[(value >> (nibble * 4)) & 15u]);
    return count;
}

int vga_printf(const char *format, ...) {
    va_list args;
    int count = 0;
    if (!format) return -1;
    va_start(args, format);
    while (*format) {
        if (*format != '%') { vga_putc((unsigned char)*format++); ++count; continue; }
        ++format;
        char conversion = *format;
        if (conversion) ++format;
        switch (conversion) {
            case 'd': {
                int32_t value = va_arg(args, int);
                uint32_t magnitude = (uint32_t)value;
                if (value < 0) { vga_putc('-'); ++count; magnitude = 0u - magnitude; }
                count += decimal(magnitude);
                break;
            }
            case 'u': count += decimal(va_arg(args, unsigned int)); break;
            case 'x': count += hexadecimal(va_arg(args, unsigned int)); break;
            case 'c': vga_putc(va_arg(args, int)); ++count; break;
            case 's': {
                const char *text = va_arg(args, const char *);
                if (!text) text = "(null)";
                while (*text) { vga_putc((unsigned char)*text++); ++count; }
                break;
            }
            case '%': vga_putc('%'); ++count; break;
            default:
                vga_putc('%'); ++count;
                if (conversion) { vga_putc(conversion); ++count; }
                break;
        }
    }
    va_end(args);
    return count;
}
