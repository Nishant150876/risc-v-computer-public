// cpu_tb: +board_io +observe_io
#include "mmio.h"

static uint32_t fibonacci(uint32_t n) {
    uint32_t previous = 0, current = 1;
    for (uint32_t i = 0; i < n; ++i) {
        uint32_t next = previous + current;
        previous = current;
        current = next;
    }
    return previous;
}

int main(void) {
    for (;;) {
        uint32_t n = mmio_read32(RVC_SWITCHES_ADDR);
        uint32_t result = (n <= 20) ? fibonacci(n) : UINT32_C(0xffff);
        mmio_write32(RVC_LEDS_ADDR, n);
        mmio_write32(RVC_HEX_ADDR, result);
    }
}
