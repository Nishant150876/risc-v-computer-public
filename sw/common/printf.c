#include "uart.h"
#include <stdarg.h>

/* RV32I long division: decimal formatting needs no multiply/divide helper. */
static uint32_t divide10(uint32_t value, uint32_t *remainder) {
    uint32_t quotient = 0, rem = 0;
    for (int bit = 31; bit >= 0; --bit) {
        rem = (rem << 1) | ((value >> bit) & 1u);
        if (rem >= 10) { rem -= 10; quotient |= UINT32_C(1) << bit; }
    }
    *remainder = rem;
    return quotient;
}

static int decimal(uint32_t value) {
    char digits[10];
    int count = 0;
    do {
        uint32_t remainder;
        value = divide10(value, &remainder);
        digits[count++] = (char)('0' + remainder);
    } while (value != 0);
    for (int i = count - 1; i >= 0; --i) putc(digits[i]);
    return count;
}

static int hexadecimal(uint32_t value) {
    static const char digits[] = "0123456789abcdef";
    int nibble = 7;
    while (nibble > 0 && ((value >> (nibble * 4)) & 15u) == 0) --nibble;
    int count = nibble + 1;
    for (; nibble >= 0; --nibble) putc(digits[(value >> (nibble * 4)) & 15u]);
    return count;
}

int printf(const char *format, ...) {
    va_list args;
    int count = 0;
    if (format == 0) return -1;
    va_start(args, format);
    while (*format != '\0') {
        if (*format != '%') { putc((unsigned char)*format++); ++count; continue; }
        ++format;
        char conversion = *format;
        if (conversion != '\0') ++format;
        switch (conversion) {
            case 'd': {
                int32_t value = va_arg(args, int);
                uint32_t magnitude = (uint32_t)value;
                if (value < 0) { putc('-'); ++count; magnitude = 0u - magnitude; }
                count += decimal(magnitude);
                break;
            }
            case 'u': count += decimal(va_arg(args, unsigned int)); break;
            case 'x': count += hexadecimal(va_arg(args, unsigned int)); break;
            case 'c': putc(va_arg(args, int)); ++count; break;
            case 's': {
                const char *text = va_arg(args, const char *);
                if (text == 0) text = "(null)";
                while (*text != '\0') { putc((unsigned char)*text++); ++count; }
                break;
            }
            case '%': putc('%'); ++count; break;
            default:
                putc('%'); ++count;
                if (conversion != '\0') { putc(conversion); ++count; }
                break;
        }
    }
    va_end(args);
    return count;
}
