#ifndef RVC_LIFE_H
#define RVC_LIFE_H
#include <stdint.h>
#define LIFE_WIDTH 160u
#define LIFE_HEIGHT 120u
#define LIFE_WORDS 5u
enum life_pattern { LIFE_GLIDER, LIFE_GUN, LIFE_R_PENTOMINO, LIFE_RANDOM };
typedef struct {
    uint32_t cells[2][LIFE_HEIGHT][LIFE_WORDS];
    uint32_t generation, random;
    unsigned front, pattern;
} life_t;
int life_init(life_t *life, unsigned pattern, uint32_t seed);
void life_clear(life_t *life);
int life_get(const life_t *life, unsigned x, unsigned y);
void life_set(life_t *life, unsigned x, unsigned y, int alive);
void life_step(life_t *life); /* B3/S23, finite board; outside cells are dead */
#endif
