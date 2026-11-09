#include "sieve.h"
#include "mmio.h"
#include "uart.h"
#include "demo.h"
static uint8_t composite[SIEVE_BYTES];
int main(void) {
    uint32_t c0 = mmio_read32(RVC_CYCLES_ADDR);
    uint32_t i0 = mmio_read32(RVC_INSTRET_ADDR);
    unsigned count = sieve_run(composite);
    uint32_t i1 = mmio_read32(RVC_INSTRET_ADDR);
    uint32_t c1 = mmio_read32(RVC_CYCLES_ADDR);
    uint32_t cycles = elapsed_cycles(c0,c1), instructions = elapsed_cycles(i0,i1);
    puts("primes <= 10000");
    unsigned column = 0;
    for (unsigned n = 2; n <= PRIMES_LIMIT; ++n) {
        if (!sieve_is_prime(composite,n)) continue;
        if (column) putc(' ');
        printf("%u",n);
        if (++column == 16) { puts(""); column = 0; }
    }
    if (column) puts("");
    printf("count %u\r\n",count);
    /* This interval covers the sieve and count, never serial printing.
     * Counts differ between CPUs. The host/bench validates the relationship,
     * while uart.expect describes only the deterministic prime output. */
    uint32_t milli = instructions ? (uint32_t)(((uint64_t)cycles*1000u + instructions/2u)/instructions) : 0;
    uint32_t fraction = milli%1000u;
    printf("cycles %u instret %u CPI %u.",cycles,instructions,milli/1000u);
    if (fraction < 100u) putc('0');
    if (fraction < 10u) putc('0');
    printf("%u\r\n",fraction);
    mmio_write32(RVC_LEDS_ADDR,count == 1229 ? 0x7001 : 0xdead);
    mmio_write32(RVC_HEX_ADDR,demo_bcd4(count));
    uart_flush();
    return count == 1229 ? 0 : 1;
}
