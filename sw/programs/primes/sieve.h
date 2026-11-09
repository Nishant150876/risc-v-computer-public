#ifndef RVC_SIEVE_H
#define RVC_SIEVE_H
#include <stdint.h>
#define PRIMES_LIMIT 10000u
#define SIEVE_BYTES ((PRIMES_LIMIT + 8u) / 8u)
unsigned sieve_run(uint8_t composite[SIEVE_BYTES]);
int sieve_is_prime(const uint8_t composite[SIEVE_BYTES], unsigned value);
#endif
