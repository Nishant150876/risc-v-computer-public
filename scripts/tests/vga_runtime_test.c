#include "vga.h"
#include "mmio.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include "vga_font8x8.inc"

static unsigned char text[4096], pixels[16384];
static unsigned status, target_mode, pending_reads, writes, polls;
static int blank_script;

static unsigned pixel(unsigned x,unsigned y) {
    unsigned position = y*160+x;
    return (pixels[position/2] >> ((position%2)*4)) & 15u;
}

static void graphics_helpers(void) {
    for (unsigned b = 0; b < 256; ++b) {
        uint32_t expected = 0;
        for (unsigned bit = 0; bit < 8; ++bit) if (b & (1u << bit)) expected |= 15u << (4u*bit);
        assert(vga_expand_bits((uint8_t)b) == expected);
    }
    static const int rectangles[][4] = {
        {0,0,160,120},{7,2,10,3},{-4,-3,11,8},{159,119,INT_MAX,INT_MAX},
        {INT_MIN,0,INT_MAX,10},{0,INT_MIN,10,INT_MAX},{-2,-2,INT_MAX,INT_MAX},
        {160,0,1,1},{0,120,1,1},{0,0,0,5},{0,0,5,-1}
    };
    for (unsigned n = 0; n < sizeof rectangles/sizeof rectangles[0]; ++n) {
        const int *r = rectangles[n];
        clear(3);
        int result = fill_rect(r[0],r[1],r[2],r[3],12);
        assert(result == ((r[2] <= 0 || r[3] <= 0) ? -1 : 0));
        for (unsigned y = 0; y < 120; ++y) for (unsigned x = 0; x < 160; ++x) {
            int inside = r[2] > 0 && r[3] > 0 && (int64_t)x >= r[0] && (int64_t)y >= r[1] &&
                         (int64_t)x < (int64_t)r[0]+r[2] && (int64_t)y < (int64_t)r[1]+r[3];
            assert(pixel(x,y) == (inside ? 12u : 3u));
        }
    }
    clear(3);
    for (unsigned code = 32; code < 127; ++code) {
        char glyph[2] = {(char)code,0};
        assert(vga_draw_text(19,14,glyph,14,1) == 1);
        for (unsigned y = 0; y < 120; ++y) for (unsigned x = 0; x < 160; ++x) {
            unsigned expected = 3;
            if (x >= 152 && y >= 112) expected = (rvc_font8x8[code][y-112] >> (x-152)) & 1u ? 14 : 1;
            assert(pixel(x,y) == expected);
        }
    }
    assert(vga_draw_text(19,14,"AB",15,0) == 1);
    unsigned before = writes;
    assert(vga_draw_text(20,0,"A",15,0) == -1 && vga_draw_text(0,15,"A",15,0) == -1);
    assert(vga_draw_text(0,0,0,15,0) == -1 && vga_draw_text(0,0,"A",16,0) == -1);
    assert(fill_rect(0,0,1,1,16) == -1 && writes == before);
}

static unsigned char *memory(uint32_t address, unsigned count) {
    if (address >= RVC_VGA_TEXT_ADDR && address - RVC_VGA_TEXT_ADDR + count <= 2400)
        return text + address - RVC_VGA_TEXT_ADDR;
    assert(address >= RVC_VGA_PIXELS_ADDR && address - RVC_VGA_PIXELS_ADDR + count <= 9600);
    return pixels + address - RVC_VGA_PIXELS_ADDR;
}

uint32_t vga_test_read32(uint32_t address) {
    assert((address & 3u) == 0);
    if (address == RVC_VGA_STATUS_ADDR) {
        ++polls;
        if (blank_script) {
            static const unsigned blanks[] = {1,1,0,0,1};
            assert(blank_script <= 5);
            return blanks[blank_script++ - 1];
        }
        if (pending_reads && --pending_reads == 0) status = target_mode << 2;
        return status;
    }
    unsigned char *p = memory(address, 4);
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

void vga_test_write32(uint32_t address, uint32_t value) {
    assert((address & 3u) == 0);
    ++writes;
    if (address == RVC_VGA_CONTROL_ADDR) {
        assert(!(status & RVC_VGA_MODE_PENDING) && value <= 3);
        target_mode = value;
        status |= RVC_VGA_MODE_PENDING;
        pending_reads = 3;
        return;
    }
    unsigned char *p = memory(address, 4);
    for (unsigned i = 0; i < 4; ++i) p[i] = (unsigned char)(value >> (i*8));
}

void vga_test_write8(uint32_t address, uint32_t value) {
    ++writes;
    *memory(address, 1) = (unsigned char)value;
}

int main(void) {
    memset(text, 0xcc, sizeof text);
    memset(pixels, 0xcc, sizeof pixels);
    for (unsigned mode = 0; mode < 4; ++mode) {
        assert(vga_set_mode((enum vga_mode)mode) == 0);
        assert(vga_get_mode() == (enum vga_mode)mode);
    }
    unsigned before = writes;
    assert(vga_set_mode((enum vga_mode)-1) == -1);
    assert(vga_set_mode((enum vga_mode)4) == -1 && writes == before);
    blank_script = 1;
    vga_wait_vblank();
    assert(blank_script == 6);
    blank_script = 0;
    vga_clear_text();
    for (unsigned n = 0; n < 2400; ++n) assert(text[n] == ' ');
    for (unsigned n = 2400; n < sizeof text; ++n) assert(text[n] == 0xcc);
    const char *expected = "-2147483648 4294967295 89abcdef (null) A %";
    assert(vga_printf("%d %u %x %s %c %%", INT_MIN, UINT_MAX, 0x89abcdefu, (const char *)0, 'A') == (int)strlen(expected));
    assert(memcmp(text, expected, strlen(expected)) == 0);
    vga_clear_text();
    assert(vga_printf("[%q]%") == 5);
    assert(memcmp(text,"[%q]%",5) == 0);
    before = writes;
    assert(vga_printf(0) == -1 && writes == before);
    vga_clear_text();
    vga_putc('A'); vga_putc('B'); vga_putc('\b'); vga_putc('C');
    assert(text[0] == 'A' && text[1] == 'C');
    vga_putc('\r'); vga_putc('D'); vga_putc('\n'); vga_putc('E');
    assert(text[0] == 'D' && text[80] == 'E');
    assert(vga_set_cursor(79,0) == 0); vga_putc('\t'); vga_putc('Q');
    assert(text[79] == ' ' && text[80] == 'Q');
    before = writes;
    assert(vga_set_cursor(80,0) == -1 && vga_set_cursor(0,30) == -1 && writes == before);
    vga_clear_text();
    for (unsigned row = 0; row < 30; ++row) {
        assert(vga_set_cursor(0,row) == 0); vga_putc((int)('A'+row%26));
    }
    assert(vga_set_cursor(0,29) == 0); vga_putc('\n');
    for (unsigned row = 0; row < 29; ++row) {
        assert(text[row*80] == 'A'+(row+1)%26);
        for (unsigned col = 1; col < 80; ++col) assert(text[row*80+col] == ' ');
    }
    for (unsigned col = 0; col < 80; ++col) assert(text[29*80+col] == ' ');
    for (unsigned c = 0; c < 16; ++c) {
        assert(clear(c) == 0);
        for (unsigned n = 0; n < 9600; ++n) assert(pixels[n] == (c | (c << 4)));
    }
    before = writes;
    assert(clear(16) == -1 && set_pixel(160,0,0) == -1 && set_pixel(0,120,0) == -1);
    assert(set_pixel(UINT_MAX,0,0) == -1 && set_pixel(0,0,16) == -1 && writes == before);
    clear(0);
    for (unsigned x = 0; x < 8; ++x) assert(set_pixel(x,0,x+1) == 0);
    assert(vga_test_read32(RVC_VGA_PIXELS_ADDR) == UINT32_C(0x87654321));
    assert(set_pixel(159,119,15) == 0 && pixels[9599] == 0xf0);
    for (unsigned y = 0; y < 120; ++y)
        for (unsigned x = 0; x < 160; ++x) assert(set_pixel(x,y,(x^y)&15u) == 0);
    for (unsigned position = 0; position < 19200; ++position) {
        unsigned actual = (pixels[position/2] >> ((position%2)*4)) & 15u;
        assert(actual == (((position%160)^(position/160))&15u));
    }
    graphics_helpers();
    for (unsigned n = 9600; n < sizeof pixels; ++n) assert(pixels[n] == 0xcc);
    printf("PASS: VGA C formatting/control/wrap/scroll/bounds/all pixel packing (%u MMIO writes, %u status reads)\n",writes,polls);
    return 0;
}
