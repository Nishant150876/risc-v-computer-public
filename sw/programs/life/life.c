#include "life.h"
#include "rand.h"
void life_clear(life_t *life) {
    for (unsigned buffer = 0; buffer < 2; ++buffer)
        for (unsigned y = 0; y < LIFE_HEIGHT; ++y)
            for (unsigned word = 0; word < LIFE_WORDS; ++word) life->cells[buffer][y][word] = 0;
    life->front = 0; life->generation = 0;
}
int life_get(const life_t *life, unsigned x, unsigned y) {
    if (x >= LIFE_WIDTH || y >= LIFE_HEIGHT) return 0;
    return (life->cells[life->front][y][x >> 5] >> (x & 31u)) & 1u;
}
void life_set(life_t *life, unsigned x, unsigned y, int alive) {
    if (x >= LIFE_WIDTH || y >= LIFE_HEIGHT) return;
    uint32_t mask = UINT32_C(1) << (x & 31u);
    uint32_t *word = &life->cells[life->front][y][x >> 5];
    *word = alive ? *word | mask : *word & ~mask;
}
int life_init(life_t *life, unsigned pattern, uint32_t seed) {
    if (pattern > LIFE_RANDOM) return -1;
    life_clear(life); life->pattern = pattern; rng_seed(&life->random,seed);
    if (pattern == LIFE_RANDOM) {
        for (unsigned y = 0; y < LIFE_HEIGHT; ++y)
            for (unsigned w = 0; w < LIFE_WORDS; ++w) {
                uint32_t a = rng_next(&life->random), b = rng_next(&life->random);
                life->cells[0][y][w] = a & b; // approximately 1/4 live
            }
    } else if (pattern == LIFE_GLIDER) {
        life_set(life,17,16,1); life_set(life,18,17,1);
        life_set(life,16,18,1); life_set(life,17,18,1); life_set(life,18,18,1);
    } else if (pattern == LIFE_R_PENTOMINO) {
        life_set(life,80,59,1); life_set(life,81,59,1);
        life_set(life,79,60,1); life_set(life,80,60,1); life_set(life,80,61,1);
    } else {
        /* Gosper glider gun, 36 live cells in a 36x9 bounding box.
         * Coordinates are relative to (8,8); provenance is in README.md. */
        static const uint8_t points[][2] = {
            {24,0},{22,1},{24,1},{12,2},{13,2},{20,2},{21,2},{34,2},{35,2},
            {11,3},{15,3},{20,3},{21,3},{34,3},{35,3},{0,4},{1,4},{10,4},
            {16,4},{20,4},{21,4},{0,5},{1,5},{10,5},{14,5},{16,5},{17,5},
            {22,5},{24,5},{10,6},{16,6},{24,6},{11,7},{15,7},{12,8},{13,8}
        };
        for (unsigned n = 0; n < sizeof points/sizeof points[0]; ++n)
            life_set(life,8u+points[n][0],8u+points[n][1],1);
    }
    return 0;
}
static uint32_t row_word(const life_t *life, int row, int word) {
    if (row < 0 || row >= (int)LIFE_HEIGHT || word < 0 || word >= (int)LIFE_WORDS) return 0;
    return life->cells[life->front][row][word];
}
/* Count eight neighbors in parallel for all 32 cells. Three bit planes are
 * sufficient: 8 wraps to 0, and neither value satisfies a count of 2 or 3. */
#define ADD_NEIGHBORS(mask) do { \
    uint32_t carry0 = low & (mask); low ^= (mask); \
    uint32_t carry1 = high & carry0; high ^= carry0; third ^= carry1; \
} while (0)
void life_step(life_t *life) {
    unsigned next = life->front ^ 1u;
    for (int y = 0; y < (int)LIFE_HEIGHT; ++y)
        for (int w = 0; w < (int)LIFE_WORDS; ++w) {
            uint32_t n = row_word(life,y-1,w), c = row_word(life,y,w), s = row_word(life,y+1,w);
            uint32_t nw = (n << 1) | (row_word(life,y-1,w-1) >> 31);
            uint32_t ne = (n >> 1) | (row_word(life,y-1,w+1) << 31);
            uint32_t west = (c << 1) | (row_word(life,y,w-1) >> 31);
            uint32_t east = (c >> 1) | (row_word(life,y,w+1) << 31);
            uint32_t sw = (s << 1) | (row_word(life,y+1,w-1) >> 31);
            uint32_t se = (s >> 1) | (row_word(life,y+1,w+1) << 31);
            uint32_t low = 0, high = 0, third = 0;
            ADD_NEIGHBORS(nw); ADD_NEIGHBORS(n); ADD_NEIGHBORS(ne); ADD_NEIGHBORS(west);
            ADD_NEIGHBORS(east); ADD_NEIGHBORS(sw); ADD_NEIGHBORS(s); ADD_NEIGHBORS(se);
            life->cells[next][y][w] = high & ~third & (low | c);
        }
    life->front = next; ++life->generation;
}
#undef ADD_NEIGHBORS
