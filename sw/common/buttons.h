#ifndef RVC_BUTTONS_H
#define RVC_BUTTONS_H
#include <stdint.h>
#define BUTTON_UP    UINT32_C(0x02)
#define BUTTON_LEFT  UINT32_C(0x04)
#define BUTTON_RIGHT UINT32_C(0x08)
#define BUTTON_DOWN  UINT32_C(0x10)
#define BUTTON_DIRECTIONS UINT32_C(0x1e)
typedef struct { uint32_t previous; } button_edges_t;
void buttons_init(button_edges_t *state, uint32_t levels);
/* Hardware supplies debounced levels; this returns new direction presses.
 * The center bit is deliberately excluded: it remains the CPU reset. */
uint32_t buttons_pressed(button_edges_t *state, uint32_t levels);
#endif
