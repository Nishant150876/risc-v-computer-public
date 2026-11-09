/* Exercise the actual freestanding engines with independent native oracles. */
#include "life.h"
#include "snake.h"
#include "sieve.h"
#include "buttons.h"
#include "rand.h"
#include "demo.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static life_t life;
static unsigned char reference[120][160], next[120][160];
static void compare_life(void) {
    for (unsigned y = 0; y < 120; ++y)
        for (unsigned x = 0; x < 160; ++x) assert(life_get(&life,x,y) == reference[y][x]);
}
static void step_reference(void) {
    for (int y = 0; y < 120; ++y) for (int x = 0; x < 160; ++x) {
        unsigned count = 0;
        for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx)
            if ((dx || dy) && x+dx >= 0 && x+dx < 160 && y+dy >= 0 && y+dy < 120)
                count += reference[y+dy][x+dx];
        next[y][x] = count == 3 || (count == 2 && reference[y][x]);
    }
    memcpy(reference,next,sizeof reference);
}
static void snapshot(void) {
    for (unsigned y = 0; y < 120; ++y)
        for (unsigned x = 0; x < 160; ++x) reference[y][x] = (unsigned char)life_get(&life,x,y);
}
static void test_sieve(void) {
    unsigned char composite[SIEVE_BYTES];
    memset(composite,0xa5,sizeof composite);
    assert(sieve_run(composite) == 1229);
    unsigned count = 0;
    for (unsigned n = 0; n <= 10000; ++n) {
        int prime = n >= 2;
        for (unsigned d = 2; d*d <= n; ++d) if (n%d == 0) { prime = 0; break; }
        assert(sieve_is_prime(composite,n) == prime);
        count += (unsigned)prime;
    }
    assert(count == 1229 && !sieve_is_prime(composite,10001));
}
static void test_helpers(void) {
    uint32_t state;
    rng_seed(&state,1);
    assert(rng_next(&state) == 270369u);
    assert(rng_next(&state) == 67634689u);
    assert(rng_next(&state) == 2647435461u);
    rng_seed(&state,0); assert(state != 0);
    for (unsigned n = 0; n < 10000; ++n) assert(rng_next(&state) != 0);
    button_edges_t buttons;
    buttons_init(&buttons,BUTTON_UP | 1);
    assert(buttons_pressed(&buttons,BUTTON_UP | 1) == 0);
    assert(buttons_pressed(&buttons,BUTTON_UP | BUTTON_RIGHT) == BUTTON_RIGHT);
    assert(buttons_pressed(&buttons,BUTTON_RIGHT) == 0);
    assert(buttons_pressed(&buttons,0) == 0);
    assert(buttons_pressed(&buttons,BUTTON_RIGHT | 1) == BUTTON_RIGHT);
    assert(demo_bcd4(0) == 0 && demo_bcd4(1229) == 0x1229 && demo_bcd4(12345) == 0x2345);
}
static void test_life_patterns(void) {
    life_t repeat;
    for (unsigned pattern = 0; pattern < 4; ++pattern) {
        assert(life_init(&life,pattern,1234) == 0);
        assert(life_init(&repeat,pattern,1234) == 0);
        assert(memcmp(life.cells,repeat.cells,sizeof life.cells) == 0);
        unsigned alive = 0;
        snapshot();
        for (unsigned y = 0; y < 120; ++y) for (unsigned x = 0; x < 160; ++x) alive += reference[y][x];
        if (pattern == LIFE_GUN) assert(alive == 36);
        else if (pattern != LIFE_RANDOM) assert(alive == 5);
        else assert(alive > 4000 && alive < 5600);
        for (unsigned generation = 1; generation <= 32; ++generation) {
            step_reference(); life_step(&life); compare_life();
            assert(life.generation == generation);
        }
    }
    life_init(&life,LIFE_GLIDER,1);
    for (unsigned n = 0; n < 4; ++n) life_step(&life);
    memset(reference,0,sizeof reference);
    reference[17][18] = reference[18][19] = reference[19][17] = reference[19][18] = reference[19][19] = 1;
    compare_life();
    assert(life_init(&life,4,1) == -1 && life.generation == 4);
}
static void test_life_boundaries(void) {
    life_clear(&life);
    /* Blinkers cross every packed-word boundary and touch all four edges. */
    for (unsigned x = 31; x < 159; x += 32)
        for (unsigned dy = 0; dy < 3; ++dy) life_set(&life,x,20+dy,1);
    for (unsigned x = 0; x < 3; ++x) { life_set(&life,x,0,1); life_set(&life,157+x,119,1); }
    life_set(&life,0,51,1); life_set(&life,0,52,1); life_set(&life,0,53,1);
    life_set(&life,159,71,1); life_set(&life,159,72,1); life_set(&life,159,73,1);
    life_set(&life,160,120,1); assert(life_get(&life,160,120) == 0);
    snapshot();
    for (unsigned n = 0; n < 10; ++n) { step_reference(); life_step(&life); compare_life(); }
    /* Eight live neighbors must die rather than alias the 2/3 bit-plane case. */
    life_clear(&life);
    for (unsigned y = 5; y < 8; ++y) for (unsigned x = 5; x < 8; ++x) life_set(&life,x,y,1);
    snapshot(); step_reference(); life_step(&life); compare_life(); assert(!life_get(&life,6,6));
}
static snake_t snake;
static void snake_invariants(void) {
    unsigned char seen[26][40] = {{0}};
    assert(snake.first < SNAKE_CAPACITY && snake.length >= 3 && snake.length <= SNAKE_CAPACITY);
    for (unsigned n = 0; n < snake.length; ++n) {
        uint16_t p = snake.body[(snake.first+n)%SNAKE_CAPACITY];
        assert(snake_x(p) < 40 && snake_y(p) < 26 && !seen[snake_y(p)][snake_x(p)]);
        seen[snake_y(p)][snake_x(p)] = 1;
    }
    assert(memcmp(seen,snake.occupied,sizeof seen) == 0);
    if (snake.food != SNAKE_NO_FOOD)
        assert(snake_x(snake.food) < 40 && snake_y(snake.food) < 26 && !seen[snake_y(snake.food)][snake_x(snake.food)]);
}
static void test_snake_controls(void) {
    snake_init(&snake,2377); snake_invariants();
    assert(snake.food == snake_pack(21,13));
    assert(!snake_turn(&snake,SNAKE_LEFT)); // no reversal
    snake_step(&snake); assert(snake.score == 1 && snake.length == 4); snake_invariants();
    assert(snake_turn(&snake,SNAKE_UP));
    assert(!snake_turn(&snake,SNAKE_LEFT)); // second turn cannot reverse into neck
    snake_step(&snake); assert(snake_head(&snake) == snake_pack(21,12)); snake_invariants();
    for (unsigned y = 0; y < 13; ++y) snake_step(&snake);
    assert(snake.status == SNAKE_DEAD && snake_head(&snake) == snake_pack(21,0));
    unsigned ticks = snake.ticks; snake_step(&snake); assert(snake.ticks == ticks);
    assert(!snake_turn(&snake,SNAKE_DOWN));
}
static void test_snake_ring(void) {
    snake_init(&snake,1); snake.food = snake_pack(5,5);
    /* Run >4 ring revolutions around an empty rectangle. */
    for (unsigned n = 0; n < 5000; ++n) {
        uint16_t head = snake_head(&snake); unsigned x = snake_x(head), y = snake_y(head);
        if (x == 30 && y == 13) assert(snake_turn(&snake,SNAKE_DOWN));
        if (x == 30 && y == 23) assert(snake_turn(&snake,SNAKE_LEFT));
        if (x == 10 && y == 23) assert(snake_turn(&snake,SNAKE_UP));
        if (x == 10 && y == 13) assert(snake_turn(&snake,SNAKE_RIGHT));
        snake_step(&snake); assert(snake.status == SNAKE_PLAYING && snake.length == 3); snake_invariants();
    }
    /* Tail entry is legal only when that tail vacates on this tick. */
    snake_init(&snake,1); memset(snake.occupied,0,sizeof snake.occupied);
    const uint16_t square[] = {65,129,130,66};
    snake.length = 4; snake.direction = SNAKE_UP; snake.queued = SNAKE_UP;
    for (unsigned n = 0; n < 4; ++n) { snake.body[n] = square[n]; snake.occupied[snake_y(square[n])][snake_x(square[n])] = 1; }
    snake.food = snake_pack(10,10);
    assert(snake_turn(&snake,SNAKE_LEFT)); snake_step(&snake);
    assert(snake.status == SNAKE_PLAYING && snake_head(&snake) == square[0]); snake_invariants();
    /* Steer into a body cell that is not the departing tail. */
    snake_init(&snake,1); memset(snake.occupied,0,sizeof snake.occupied);
    const uint16_t body[] = {64,65,129,130,66};
    snake.length = 5; snake.direction = SNAKE_UP; snake.queued = SNAKE_UP; snake.food = snake_pack(10,10);
    for (unsigned n = 0; n < 5; ++n) { snake.body[n] = body[n]; snake.occupied[snake_y(body[n])][snake_x(body[n])] = 1; }
    assert(snake_turn(&snake,SNAKE_LEFT)); snake_step(&snake); assert(snake.status == SNAKE_DEAD); snake_invariants();
}
static void test_snake_full(void) {
    snake_init(&snake,1); memset(snake.occupied,0,sizeof snake.occupied);
    unsigned n = 0;
    for (unsigned y = 0; y < 26; ++y) for (unsigned x = 0; x < 40; ++x) {
        if (x == 39 && y == 25) continue;
        snake.body[n++] = snake_pack(x,y); snake.occupied[y][x] = 1;
    }
    snake.first = 0; snake.length = n; snake.food = snake_pack(39,25); snake.score = n-3;
    snake_step(&snake);
    assert(snake.status == SNAKE_WON && snake.length == SNAKE_CAPACITY && snake.food == SNAKE_NO_FOOD);
    snake_invariants();
}
int main(int argc,char **argv) {
    assert(argc == 2);
    if (!strcmp(argv[1],"sieve")) test_sieve();
    else if (!strcmp(argv[1],"helpers")) test_helpers();
    else if (!strcmp(argv[1],"life_patterns")) test_life_patterns();
    else if (!strcmp(argv[1],"life_boundaries")) test_life_boundaries();
    else if (!strcmp(argv[1],"snake_controls")) test_snake_controls();
    else if (!strcmp(argv[1],"snake_ring")) test_snake_ring();
    else if (!strcmp(argv[1],"snake_full")) test_snake_full();
    else assert(0);
    printf("PASS: actual C %s, independent reference and invariants\n",argv[1]);
    return 0;
}
