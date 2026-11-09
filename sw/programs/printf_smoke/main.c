// cpu_tb: +uart_console +uart_expect=sw/programs/printf_smoke/uart.expect +uart_input=4b +expect_stop=EBREAK +max_cycles=1000000
#include "uart.h"
#include <stdint.h>

int main(void) {
    int result = printf("format: %d %d %d %d\r\n", INT32_MIN, -1, 0, INT32_MAX);
    if (result != (int)sizeof("format: -2147483648 -1 0 2147483647\r\n") - 1) return 1;
    printf("unsigned: %u %u\r\n", 0u, UINT32_MAX);
    printf("hex: %x %x %x\r\n", 0u, UINT32_C(0x89abcdef), UINT32_MAX);
    printf("text: %s %c %% %s\r\n", "ok", 'Z', (const char *)0);
    printf("unknown: %q tail%"); printf("\r\n");
    puts("input?");
    int character = getc();
    printf("rx:%c\r\n", character);
    uart_flush();
    return character == 'K' ? 0 : 1;
}
