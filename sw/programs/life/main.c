#include "life.h"
#include "buttons.h"
#include "demo.h"
#include "mmio.h"
#include "vga.h"
static life_t world;
static uint32_t colors[256];
static unsigned draw_overrun;
static unsigned selected_pattern(uint32_t switches) {
    if (switches & 1u) return LIFE_GLIDER;
    if (switches & 2u) return LIFE_GUN;
    if (switches & 4u) return LIFE_R_PENTOMINO;
    if (switches & 8u) return LIFE_RANDOM;
    return LIFE_GLIDER;
}
static void draw(int hidden) {
    if (!hidden) vga_wait_vblank();
    unsigned offset = 0;
    for (unsigned y = 0; y < LIFE_HEIGHT; ++y)
        for (unsigned w = 0; w < LIFE_WORDS; ++w) {
            uint32_t cells = world.cells[world.front][y][w];
            for (unsigned byte = 0; byte < 4; ++byte) {
                mmio_write32(RVC_VGA_PIXELS_ADDR + offset,colors[cells & 255u]);
                cells >>= 8; offset += 4;
            }
        }
    if (!hidden && !(mmio_read32(RVC_VGA_STATUS_ADDR) & RVC_VGA_VBLANK)) draw_overrun = 1;
    mmio_write32(RVC_HEX_ADDR,demo_bcd4(world.generation));
    mmio_write32(RVC_LEDS_ADDR,0x7100u | (1u << world.pattern) | (draw_overrun ? 0x8000u : 0));
}
static void restart(void) {
    vga_set_mode(VGA_BLACK);
    life_init(&world,selected_pattern(mmio_read32(RVC_SWITCHES_ADDR)),
              mmio_read32(RVC_CYCLES_ADDR) ^ UINT32_C(0x71fe1234));
    draw_overrun = 0;
    draw(1);
    vga_set_mode(VGA_PIXELS);
}
int main(void) {
    for (unsigned b = 0; b < 256; ++b) colors[b] = vga_expand_bits((uint8_t)b) & UINT32_C(0xaaaaaaaa);
    button_edges_t buttons;
    buttons_init(&buttons,mmio_read32(RVC_BUTTONS_ADDR));
    restart();
    uint32_t last = mmio_read32(RVC_CYCLES_ADDR);
    for (;;) {
        uint32_t pressed = buttons_pressed(&buttons,mmio_read32(RVC_BUTTONS_ADDR));
        uint32_t now = mmio_read32(RVC_CYCLES_ADDR);
        if (pressed & BUTTON_UP) { restart(); last = mmio_read32(RVC_CYCLES_ADDR); continue; }
        unsigned manual = mmio_read32(RVC_SWITCHES_ADDR) & 0x8000u;
        if (manual) last = now;
        if ((manual && (pressed & BUTTON_RIGHT)) || (!manual && elapsed_cycles(last,now) >= RVC_CPU_HZ/4u)) {
            last = now;
            life_step(&world);
            draw(0);
        }
    }
}
