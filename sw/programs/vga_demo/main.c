#include "mmio.h"
#include "vga.h"

#ifndef RVC_CPU_HZ
#define RVC_CPU_HZ 25000000u
#endif

int main(void) {
    /* Hide both memories while populating them. The display memories are
     * single-buffered, so a whole redraw need not fit in a 1.44 ms blank. */
    vga_set_mode(VGA_BLACK);
    vga_clear_text();
    vga_printf("hello, world\n\nRISC-V Computer / Basys 3\n");
    vga_printf("80 x 30 text / 8 x 16 public-domain font\n");
    vga_printf("160 x 120 pixels / 16 colors / 4 x 4 scaling\n\n");
    vga_printf("RV32I: %s  %d  %u  0x%x  %c  %%\n", "ready", -42, 640u, 0x480u, 'V');
    vga_printf("SW0: pixels   SW1: color bars   both off: alternate\n");
    vga_printf("CPU clock: %u Hz (configured, not measured Fmax)\n", (unsigned)RVC_CPU_HZ);
    clear(0);
    for (unsigned y = 0; y < VGA_HEIGHT; ++y)
        for (unsigned x = 0; x < VGA_WIDTH; ++x)
            set_pixel(x, y, ((x >> 4) + (y >> 4)) & 15u);
    /* Distinct corners make nibble order, 4x scaling and RGB wiring visible. */
    set_pixel(0, 0, 4);
    set_pixel(159, 0, 2);
    set_pixel(0, 119, 1);
    set_pixel(159, 119, 15);
    vga_set_mode(VGA_TEXT);
    mmio_write32(RVC_LEDS_ADDR, 0x6006);
    mmio_write32(RVC_HEX_ADDR, 0x6404);

    uint32_t started = mmio_read32(RVC_CYCLES_ADDR);
    unsigned auto_pixels = 0;
    enum vga_mode current = VGA_TEXT;
    for (;;) {
        uint32_t now = mmio_read32(RVC_CYCLES_ADDR);
        if (elapsed_cycles(started, now) >= (uint32_t)RVC_CPU_HZ * 2u) {
            started = now;
            auto_pixels ^= 1u;
        }
        unsigned switches = mmio_read32(RVC_SWITCHES_ADDR);
        enum vga_mode desired = (switches & 2u) ? VGA_COLOR_BARS :
                               (switches & 1u) ? VGA_PIXELS :
                               auto_pixels ? VGA_PIXELS : VGA_TEXT;
        if (desired != current) { vga_set_mode(desired); current = desired; }
    }
}
