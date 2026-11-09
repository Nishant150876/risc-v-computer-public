#ifndef RVC_RAND_H
#define RVC_RAND_H
#include <stdint.h>
/* Reproducible non-cryptographic xorshift32; zero seeds are normalized. */
uint32_t rng_next(uint32_t *state);
void rng_seed(uint32_t *state, uint32_t seed);
#endif
