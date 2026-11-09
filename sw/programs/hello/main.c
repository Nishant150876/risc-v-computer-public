// cpu_tb: +uart_console +uart_expect=sw/programs/hello/uart.expect +uart_observe
#include "uart.h"
#include "mmio.h"
#include "demo.h" // RVC_CPU_HZ, the configured CPU clock

// One real second at the configured CPU clock.
#define CPU_CLOCK_HZ ((uint32_t)RVC_CPU_HZ)

int main(void) {
    puts("hello, world");
    uint32_t counter = 0;
    uint32_t last = mmio_read32(RVC_CYCLES_ADDR);
    printf("\r\ncounter: %u\r\n", counter);
    for (;;) {
        int character = uart_try_getc();
        if (character >= 0) putc(character);
        uint32_t now = mmio_read32(RVC_CYCLES_ADDR);
        if (elapsed_cycles(last, now) >= CPU_CLOCK_HZ) {
            last += CPU_CLOCK_HZ;
            ++counter;
            mmio_write32(RVC_LEDS_ADDR, counter);
            mmio_write32(RVC_HEX_ADDR, counter);
            printf("\r\ncounter: %u\r\n", counter);
        }
    }
}
