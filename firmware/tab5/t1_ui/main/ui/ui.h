/* Tab5 UI entry points. Call everything here from the LVGL task, or with the
 * display lock held. */
#ifndef UI_H
#define UI_H

#include <stdint.h>

#include "lvgl.h"

#include "../port/ui_port.h"
#include "../state/app_state.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t render_last_us;  /* last LVGL refresh: render + flush */
    uint32_t render_max_us;
    uint32_t touch_last_ms;   /* press seen -> next finished frame */
    uint32_t touch_max_ms;
    uint32_t touch_samples;
    uint32_t cmd_refused;
} ui_metrics_t;

/* Builds every screen. st must outlive the UI. */
void ui_init(app_state_t *st, const ui_port_t *port);
/* Drains the message queue into the model and refreshes the visible screen.
 * ui_init() runs this from an LVGL timer at 5 Hz; tests may call it too. */
void ui_poll(void);
void ui_set_mode(ui_mode_t mode);
void ui_goto(int screen);
void ui_get_metrics(ui_metrics_t *out);
/* Root object of a screen, for tests. */
lv_obj_t *ui_screen_root(int screen);

#ifdef __cplusplus
}
#endif
#endif
