#ifndef RVC_UART_H
#define RVC_UART_H

#include <stdint.h>

uint32_t uart_status(void);
int uart_try_getc(void); /* -1 if empty, otherwise an unsigned byte */
void uart_flush(void);
int putc(int character); /* raw byte; no newline translation */
int puts(const char *text); /* append CR LF for a serial terminal */
int getc(void);
int printf(const char *format, ...); /* %d %u %x %s %c %% only */

#endif
