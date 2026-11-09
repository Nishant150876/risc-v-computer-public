#ifndef RVC_DEMO_H
#define RVC_DEMO_H
#include <stdint.h>
#ifndef RVC_CPU_HZ
#define RVC_CPU_HZ 25000000u
#endif
/* The existing display renders hexadecimal nibbles. Pack four decimal
 * digits so a score/generation appears in decimal; wrap after 9999. */
static inline uint32_t demo_bcd4(unsigned value) {
    uint32_t result = 0;
    for (unsigned digit = 0; digit < 4; ++digit) {
        result |= (value % 10u) << (digit * 4u);
        value /= 10u;
    }
    return result;
}
#endif
