#include "snake.h"
#include "rand.h"
static unsigned ring(unsigned index) { return index >= SNAKE_CAPACITY ? index-SNAKE_CAPACITY : index; }
uint16_t snake_head(const snake_t *snake) { return snake->body[ring(snake->first+snake->length-1u)]; }
static void food(snake_t *snake) {
    if (snake->length == SNAKE_CAPACITY) { snake->food = SNAKE_NO_FOOD; snake->status = SNAKE_WON; return; }
    unsigned position = rng_next(&snake->random) % SNAKE_CAPACITY;
    for (unsigned attempts = 0; attempts < SNAKE_CAPACITY; ++attempts) {
        unsigned x = position % SNAKE_WIDTH, y = position/SNAKE_WIDTH;
        if (!snake->occupied[y][x]) { snake->food = snake_pack(x,y); return; }
        if (++position == SNAKE_CAPACITY) position = 0;
    }
    snake->food = SNAKE_NO_FOOD; snake->status = SNAKE_WON;
}
void snake_init(snake_t *snake,uint32_t seed) {
    for (unsigned y = 0; y < SNAKE_HEIGHT; ++y)
        for (unsigned x = 0; x < SNAKE_WIDTH; ++x) snake->occupied[y][x] = 0;
    snake->first = 0; snake->length = 3; snake->score = 0; snake->ticks = 0;
    snake->direction = SNAKE_RIGHT; snake->queued = SNAKE_RIGHT;
    snake->turn_pending = 0; snake->status = SNAKE_PLAYING;
    for (unsigned n = 0; n < 3; ++n) {
        snake->body[n] = snake_pack(18u+n,13);
        snake->occupied[13][18u+n] = 1;
    }
    rng_seed(&snake->random,seed); food(snake);
}
int snake_turn(snake_t *snake,unsigned direction) {
    if (snake->status != SNAKE_PLAYING || direction > SNAKE_DOWN || snake->turn_pending) return 0;
    if ((snake->direction == SNAKE_UP && direction == SNAKE_DOWN) ||
        (snake->direction == SNAKE_DOWN && direction == SNAKE_UP) ||
        (snake->direction == SNAKE_LEFT && direction == SNAKE_RIGHT) ||
        (snake->direction == SNAKE_RIGHT && direction == SNAKE_LEFT)) return 0;
    if (direction != snake->direction) { snake->queued = direction; snake->turn_pending = 1; }
    return 1;
}
void snake_step(snake_t *snake) {
    if (snake->status != SNAKE_PLAYING) return;
    if (snake->turn_pending) snake->direction = snake->queued;
    snake->turn_pending = 0; ++snake->ticks;
    uint16_t old_head = snake_head(snake);
    int x = (int)snake_x(old_head), y = (int)snake_y(old_head);
    switch (snake->direction) {
        case SNAKE_UP: --y; break; case SNAKE_DOWN: ++y; break;
        case SNAKE_LEFT: --x; break; default: ++x; break;
    }
    if (x < 0 || x >= (int)SNAKE_WIDTH || y < 0 || y >= (int)SNAKE_HEIGHT) { snake->status = SNAKE_DEAD; return; }
    uint16_t next = snake_pack((unsigned)x,(unsigned)y), tail = snake->body[snake->first];
    int grows = next == snake->food;
    /* The current tail moves away on a nongrowing tick and is a legal target. */
    if (snake->occupied[y][x] && (grows || next != tail)) { snake->status = SNAKE_DEAD; return; }
    if (!grows) {
        snake->occupied[snake_y(tail)][snake_x(tail)] = 0;
        snake->first = ring(snake->first+1u); --snake->length;
    }
    snake->body[ring(snake->first+snake->length)] = next;
    ++snake->length; snake->occupied[y][x] = 1;
    if (grows) { ++snake->score; food(snake); }
}
