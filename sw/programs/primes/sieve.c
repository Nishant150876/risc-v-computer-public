#include "sieve.h"
static int marked(const uint8_t *bits, unsigned n) {
    return (bits[n >> 3] >> (n & 7u)) & 1u;
}
static void mark(uint8_t *bits, unsigned n) {
    bits[n >> 3] |= (uint8_t)(1u << (n & 7u));
}
int sieve_is_prime(const uint8_t composite[SIEVE_BYTES], unsigned value) {
    return value >= 2 && value <= PRIMES_LIMIT && !marked(composite,value);
}
unsigned sieve_run(uint8_t composite[SIEVE_BYTES]) {
    for (unsigned i = 0; i < SIEVE_BYTES; ++i) composite[i] = 0;
    mark(composite,0); mark(composite,1);
    for (unsigned p = 2; p <= 100; ++p)
        if (!marked(composite,p))
            for (unsigned multiple = p*p; multiple <= PRIMES_LIMIT; multiple += p)
                mark(composite,multiple);
    unsigned count = 0;
    for (unsigned n = 2; n <= PRIMES_LIMIT; ++n) count += !marked(composite,n);
    return count;
}
