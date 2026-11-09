#include "buttons.h"
void buttons_init(button_edges_t *state, uint32_t levels) {
    state->previous = levels & BUTTON_DIRECTIONS;
}
uint32_t buttons_pressed(button_edges_t *state, uint32_t levels) {
    levels &= BUTTON_DIRECTIONS;
    uint32_t pressed = levels & ~state->previous;
    state->previous = levels;
    return pressed;
}
