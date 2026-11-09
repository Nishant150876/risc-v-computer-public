#ifndef RVC_MMIO_H
#define RVC_MMIO_H

#include <stdint.h>

#define RVC_LEDS_ADDR       UINT32_C(0x80000000)
#define RVC_HEX_ADDR        UINT32_C(0x80000004)
#define RVC_SWITCHES_ADDR   UINT32_C(0x80000008)
#define RVC_BUTTONS_ADDR    UINT32_C(0x8000000c)
#define RVC_UART_TX_ADDR    UINT32_C(0x80000010)
#define RVC_UART_STATUS_ADDR UINT32_C(0x80000014)
#define RVC_UART_RX_ADDR    UINT32_C(0x80000018)
#define RVC_UART_TX_BUSY    UINT32_C(0x01)
#define RVC_UART_RX_READY   UINT32_C(0x02)
#define RVC_UART_OVERRUN    UINT32_C(0x04)
#define RVC_UART_FRAMING_ERROR UINT32_C(0x08)
#define RVC_CYCLES_ADDR     UINT32_C(0x80000020)
#define RVC_INSTRET_ADDR    UINT32_C(0x80000024)
#define RVC_VGA_STATUS_ADDR UINT32_C(0x80000028)
#define RVC_VGA_CONTROL_ADDR UINT32_C(0x8000002c)
#define RVC_VGA_VBLANK      UINT32_C(0x01)
#define RVC_VGA_MODE_PENDING UINT32_C(0x02)
#define RVC_VGA_TEXT_ADDR   UINT32_C(0x80010000)
#define RVC_VGA_PIXELS_ADDR UINT32_C(0x80020000)
#define RVC_TEST_RESULT_ADDR UINT32_C(0xf0000000) /* simulation only */

static inline uint32_t mmio_read32(uint32_t address) {
    return *(volatile const uint32_t *)(uintptr_t)address;
}
static inline void mmio_write32(uint32_t address, uint32_t value) {
    *(volatile uint32_t *)(uintptr_t)address = value;
}

/* Unsigned subtraction handles one modulo-2^32 counter wrap. */
static inline uint32_t elapsed_cycles(uint32_t before, uint32_t after) {
    return after - before;
}

#endif
