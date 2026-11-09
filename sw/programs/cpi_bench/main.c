// cpu_tb: +board_io +expect_stop=EBREAK +max_cycles=2000000
// Phase 5 CPI workload: compute-bound kernels with self-checked results, so
// the cycle and instret counters measure the CPU rather than UART waits.
// The kernels are in workload.h. Success: LEDs 600d, hex = checksum.
#include "mmio.h"
#include "workload.h"

int main(void) {
    uint32_t ok;
    uint32_t checksum = cpi_workload(&ok);
    if (!ok) {
        mmio_write32(RVC_LEDS_ADDR, UINT32_C(0xffff));
        mmio_write32(RVC_HEX_ADDR, UINT32_C(0xdead));
        return 1;
    }
    mmio_write32(RVC_LEDS_ADDR, UINT32_C(0x600d));
    mmio_write32(RVC_HEX_ADDR, checksum & UINT32_C(0xffff));
    return 0;
}
