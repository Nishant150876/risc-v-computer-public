// cpu_tb: +uart_console +uart_expect=sw/programs/cpi_report/uart.expect +uart_observe
// Board CPI report (Phase 5 task 10). Runs the cpi_bench workload in a loop
// and prints the hardware cycle and instret counters for each run over the
// USB UART, so CPI can be read on real hardware. Counters are read just
// before and after the workload, so UART time is not included.
// Success: LEDs 600d and hex 991d (the cpi_bench checksum); a failed sort
// shows ffff / dead and prints FAIL.
#include "mmio.h"
#include "demo.h" // RVC_CPU_HZ, the configured CPU clock
#include "uart.h"
#include "../cpi_bench/workload.h"

static void print_cpi(uint32_t cycles, uint32_t instret) {
    // CPI to three decimals in integer math; cycles stay far below 2^32 / 1000.
    uint32_t milli = instret ? (cycles * 1000u + instret / 2u) / instret : 0;
    uint32_t frac = milli % 1000u;
    printf("%u.", milli / 1000u);
    if (frac < 100u) putc('0');
    if (frac < 10u) putc('0');
    printf("%u", frac);
}

int main(void) {
    puts("cpi_report");
    for (uint32_t run = 1;; ++run) {
        uint32_t ok;
        uint32_t c0 = mmio_read32(RVC_CYCLES_ADDR);
        uint32_t i0 = mmio_read32(RVC_INSTRET_ADDR);
        uint32_t checksum = cpi_workload(&ok);
        uint32_t i1 = mmio_read32(RVC_INSTRET_ADDR);
        uint32_t c1 = mmio_read32(RVC_CYCLES_ADDR);
        uint32_t cycles = elapsed_cycles(c0, c1), instret = elapsed_cycles(i0, i1);
        mmio_write32(RVC_LEDS_ADDR, ok ? UINT32_C(0x600d) : UINT32_C(0xffff));
        mmio_write32(RVC_HEX_ADDR, ok ? (checksum & UINT32_C(0xffff)) : UINT32_C(0xdead));
        printf("run %u: cycles %u instret %u CPI ", run, cycles, instret);
        print_cpi(cycles, instret);
        printf(" checksum %x %s\r\n", checksum & UINT32_C(0xffff), ok ? "ok" : "FAIL");
        // About one second between reports at the configured CPU clock.
        uint32_t wait = mmio_read32(RVC_CYCLES_ADDR);
        while (elapsed_cycles(wait, mmio_read32(RVC_CYCLES_ADDR)) < ((uint32_t)RVC_CPU_HZ)) {
        }
    }
}
