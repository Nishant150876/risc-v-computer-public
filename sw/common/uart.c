#include "uart.h"
#include "mmio.h"

uint32_t uart_status(void) {
    return mmio_read32(RVC_UART_STATUS_ADDR);
}

int putc(int character) {
    while ((uart_status() & RVC_UART_TX_BUSY) != 0) { }
    mmio_write32(RVC_UART_TX_ADDR, (uint8_t)character);
    return (uint8_t)character;
}

void uart_flush(void) {
    while ((uart_status() & RVC_UART_TX_BUSY) != 0) { }
}

int puts(const char *text) {
    int count = 0;
    if (text == 0) text = "(null)";
    while (*text != '\0') { putc((unsigned char)*text++); ++count; }
    putc('\r'); putc('\n');
    return count + 2;
}

int uart_try_getc(void) {
    if ((uart_status() & RVC_UART_RX_READY) == 0) return -1;
    return (int)(mmio_read32(RVC_UART_RX_ADDR) & UINT32_C(0xff));
}

int getc(void) {
    int character;
    do { character = uart_try_getc(); } while (character < 0);
    return character;
}
