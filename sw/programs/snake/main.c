#include "snake.h"
#include "buttons.h"
#include "demo.h"
#include "mmio.h"
#include "vga.h"
static snake_t game;
static unsigned draw_overrun, training;
/* SW12 makes a reproducible training game; ordinary play seeds from cycles. */
#define TRAINING_SEED 2377u
static void square(uint16_t position,unsigned color) {
    if (position != SNAKE_NO_FOOD)
        fill_rect((int)snake_x(position)*4,16+(int)snake_y(position)*4,3,3,color);
}
static void hud(unsigned paused) {
    char score[] = "SCORE 0000          ";
    unsigned value = game.score;
    for (int digit = 9; digit >= 6; --digit) { score[digit] = (char)('0'+value%10u); value /= 10u; }
    const char *status = game.status == SNAKE_DEAD ? "GAME OVER: UP       " :
                         game.status == SNAKE_WON ? "YOU WIN: UP         " :
                         paused ? "PAUSED SW0          " : "PLAY U L R D        ";
    vga_draw_text(0,0,score,15,0);
    vga_draw_text(0,1,status,game.status == SNAKE_DEAD ? 12 : 15,0);
}
static void publish(uint32_t switches) {
    uint32_t flags = 0x0200u | (game.ticks & 255u) | (training ? 0x1000u : 0) |
                     ((switches & 0x8000u) ? 0x0800u : 0) | ((switches & 1u) ? 0x2000u : 0) |
                     (game.status == SNAKE_DEAD ? 0x8000u : 0) | (game.status == SNAKE_WON ? 0x4000u : 0) |
                     (draw_overrun ? 0x0400u : 0);
    mmio_write32(RVC_HEX_ADDR,demo_bcd4(game.score));
    mmio_write32(RVC_LEDS_ADDR,flags);
}
static void restart(uint32_t switches) {
    vga_set_mode(VGA_BLACK);
    training = (switches & 0x1000u) != 0;
    snake_init(&game,training ? TRAINING_SEED : mmio_read32(RVC_CYCLES_ADDR)^UINT32_C(0x5a7e17));
    draw_overrun = 0; clear(0); hud(switches & 1u);
    for (unsigned n = 0; n < game.length; ++n) square(game.body[n],n+1u == game.length ? 14 : 10);
    square(game.food,12);
    vga_set_mode(VGA_PIXELS); publish(switches);
}
int main(void) {
    button_edges_t buttons;
    buttons_init(&buttons,mmio_read32(RVC_BUTTONS_ADDR));
    uint32_t previous_switches = mmio_read32(RVC_SWITCHES_ADDR);
    restart(previous_switches);
    uint32_t last = mmio_read32(RVC_CYCLES_ADDR);
    for (;;) {
        uint32_t switches = mmio_read32(RVC_SWITCHES_ADDR);
        uint32_t pressed = buttons_pressed(&buttons,mmio_read32(RVC_BUTTONS_ADDR));
        uint32_t now = mmio_read32(RVC_CYCLES_ADDR);
        unsigned manual_tick = (switches & 0x4000u) && !(previous_switches & 0x4000u);
        unsigned pause_changed = (switches ^ previous_switches) & 1u;
        previous_switches = switches;
        if (game.status != SNAKE_PLAYING && (pressed & BUTTON_UP)) {
            restart(switches); last = mmio_read32(RVC_CYCLES_ADDR); continue;
        }
        if (pressed & BUTTON_UP) snake_turn(&game,SNAKE_UP);
        else if (pressed & BUTTON_LEFT) snake_turn(&game,SNAKE_LEFT);
        else if (pressed & BUTTON_RIGHT) snake_turn(&game,SNAKE_RIGHT);
        else if (pressed & BUTTON_DOWN) snake_turn(&game,SNAKE_DOWN);
        unsigned paused = switches & 1u, manual = switches & 0x8000u;
        uint32_t period = (switches & 2u) ? RVC_CPU_HZ/4u : RVC_CPU_HZ/8u;
        if (paused || manual) last = now;
        unsigned tick = !paused && game.status == SNAKE_PLAYING &&
                        (manual ? manual_tick : elapsed_cycles(last,now) >= period);
        if (tick || pause_changed) {
            uint16_t old_head = snake_head(&game), old_tail = game.body[game.first];
            unsigned old_length = game.length, old_status = game.status;
            if (tick) { last = now; snake_step(&game); }
            vga_wait_vblank();
            if (tick && game.status != SNAKE_DEAD) {
                if (game.length == old_length) square(old_tail,0);
                square(old_head,10); square(snake_head(&game),14); square(game.food,12);
            }
            if (tick || pause_changed || game.status != old_status) hud(paused);
            if (!(mmio_read32(RVC_VGA_STATUS_ADDR) & RVC_VGA_VBLANK)) draw_overrun = 1;
            publish(switches);
        }
    }
}
