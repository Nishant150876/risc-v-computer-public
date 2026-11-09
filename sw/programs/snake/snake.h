#ifndef RVC_SNAKE_H
#define RVC_SNAKE_H
#include <stdint.h>
#define SNAKE_WIDTH 40u
#define SNAKE_HEIGHT 26u
#define SNAKE_CAPACITY (SNAKE_WIDTH*SNAKE_HEIGHT)
#define SNAKE_NO_FOOD UINT16_MAX
enum snake_direction { SNAKE_UP, SNAKE_LEFT, SNAKE_RIGHT, SNAKE_DOWN };
enum snake_status { SNAKE_PLAYING, SNAKE_DEAD, SNAKE_WON };
typedef struct {
    uint16_t body[SNAKE_CAPACITY]; /* tail at first; ring contains length cells */
    uint8_t occupied[SNAKE_HEIGHT][SNAKE_WIDTH];
    unsigned first, length, score, ticks, direction, queued, turn_pending, status;
    uint16_t food;
    uint32_t random;
} snake_t;
static inline uint16_t snake_pack(unsigned x,unsigned y) { return (uint16_t)((y<<6)|x); }
static inline unsigned snake_x(uint16_t p) { return p & 63u; }
static inline unsigned snake_y(uint16_t p) { return p >> 6; }
uint16_t snake_head(const snake_t *snake);
void snake_init(snake_t *snake,uint32_t seed);
int snake_turn(snake_t *snake,unsigned direction); /* one accepted turn per tick; no reversal */
void snake_step(snake_t *snake);
#endif
