// cpu_tb: +board_io +expect_stop=EBREAK
#include "mmio.h"

/* Volatile globals make startup/data initialization and libgcc execution
   observable. The simulator poisons unwritten RAM before loading this image. */
static volatile uint32_t zero_word;
static volatile uint32_t zero_array[4];
static volatile uint32_t initialized_word = UINT32_C(0x12345678);
static volatile uint32_t numerator = UINT32_C(0xfffffffd);
static volatile uint32_t denominator = 7;
extern unsigned char __stack_bottom[], __stack_top[];
extern unsigned char initial_gp[] __asm__("__global_pointer$");

int main(void) {
    uint32_t start = mmio_read32(RVC_CYCLES_ADDR);
    uintptr_t sp, gp, tp;
    __asm__ volatile ("mv %0, sp" : "=r" (sp));
    __asm__ volatile ("mv %0, gp" : "=r" (gp));
    __asm__ volatile ("mv %0, tp" : "=r" (tp));
    uint32_t bad = zero_word | zero_array[0] | zero_array[1] | zero_array[2] | zero_array[3];
    bad |= (sp & 15) != 0 || sp < (uintptr_t)__stack_bottom || sp > (uintptr_t)__stack_top;
    bad |= gp != (uintptr_t)initial_gp || tp != 0;
    bad |= initialized_word ^ UINT32_C(0x12345678);
    uint32_t q = numerator / denominator;
    uint32_t product = q * denominator;
    bad |= q ^ UINT32_C(0x24924924);
    bad |= product ^ UINT32_C(0xfffffffc);
    bad |= elapsed_cycles(start, mmio_read32(RVC_CYCLES_ADDR)) == 0;
    bad |= mmio_read32(RVC_INSTRET_ADDR) == 0;
    if (bad != 0) {
        mmio_write32(RVC_LEDS_ADDR, UINT32_C(0xffff));
        mmio_write32(RVC_HEX_ADDR, UINT32_C(0xdead));
        return 1;
    }
    mmio_write32(RVC_LEDS_ADDR, UINT32_C(0x600d));
    mmio_write32(RVC_HEX_ADDR, q & UINT32_C(0xffff));
    return 0;
}
