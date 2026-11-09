#include "rand.h"
void rng_seed(uint32_t *state, uint32_t seed) {
    *state = seed ? seed : UINT32_C(0x6d2b79f5);
}
uint32_t rng_next(uint32_t *state) {
    uint32_t value = *state ? *state : UINT32_C(0x6d2b79f5);
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    *state = value;
    return value;
}
