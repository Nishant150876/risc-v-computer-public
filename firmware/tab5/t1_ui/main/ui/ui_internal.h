/* Shared helpers for the UI screens. Only the LVGL task includes this. */
#ifndef UI_INTERNAL_H
#define UI_INTERNAL_H

#include "lvgl.h"

#include "../port/ui_port.h"
#include "../state/app_state.h"
#include "screens.h"

/* ---- Colours ---------------------------------------------------------- */
#define C_BG       0x0E1116
#define C_PANEL    0x171B22
#define C_PANEL2   0x1F242D
#define C_BORDER   0x2A303A
#define C_TEXT     0xE6EAF0
#define C_MUTED    0x8B95A5
#define C_ACCENT   0x4C9AFF
#define C_GREEN    0x30D158
#define C_RED      0xFF453A
#define C_AMBER    0xFFB020
#define C_MOCK_BG  0x3D2A00
#define C_CHANGED  0x3A2F0B

/* ---- Fonts (enabled in sdkconfig.defaults and sim/lv_conf.h) --------- */
#define F_BODY   (&lv_font_montserrat_16)
#define F_LABEL  (&lv_font_montserrat_20)
#define F_HEAD   (&lv_font_montserrat_28)
#define F_BIG    (&lv_font_montserrat_40)
#define F_MONO   (&lv_font_unscii_16)

/* Minimum touch target edge in px (Tab5 is ~218 ppi: 64 px is ~7.5 mm). */
#define TOUCH_MIN 64

/* ---- Context shared by all screens ------------------------------------ */
typedef struct {
    app_state_t      *st;
    const ui_port_t  *port;
    bool              portrait;
    /* responsiveness measurements */
    uint32_t render_last_us;
    uint32_t render_max_us;
    uint32_t touch_last_ms;
    uint32_t touch_max_ms;
    uint32_t touch_samples;
    uint32_t cmd_refused;     /* commands the UI tried to send but could not */
} ui_ctx_t;

extern ui_ctx_t g_ui;

/* Widgets */
lv_obj_t *ui_label(lv_obj_t *parent, const lv_font_t *font, uint32_t colour, const char *text);
lv_obj_t *ui_button(lv_obj_t *parent, const char *text, lv_event_cb_t cb, void *user);
void      ui_button_set_enabled(lv_obj_t *btn, bool en);
/* A card with a title row. The title row ends with a provenance badge;
 * *badge_out (optional) receives it so the screen can refresh it. */
lv_obj_t *ui_panel(lv_obj_t *parent, const char *title, lv_obj_t **badge_out);
/* Updates a provenance badge: "MOCK", "MOCK - STALE", "NO DATA". */
void      ui_badge_update(lv_obj_t *badge, const app_state_t *st, uint32_t now_ms);
void      ui_capture_badge(lv_obj_t *badge, const app_state_t *st, bool valid, uint32_t sample_ms, uint32_t now_ms);
/* Sets label text only when it changed (avoids needless redraws). */
void      ui_set_text(lv_obj_t *label, const char *text);
/* A small "key: value" row; returns the value label. */
lv_obj_t *ui_kv(lv_obj_t *parent, const char *key);
/* A note explaining why something is unavailable. */
lv_obj_t *ui_note(lv_obj_t *parent, const char *text);
/* Row container with wrap. */
lv_obj_t *ui_row(lv_obj_t *parent);
/* Send a command; false and a counter bump if the queue is full. */
bool      ui_send(ui_cmd_type_t type, uint32_t arg);
/* Simulation control buttons (unplug / reconnect / link error). */
void      ui_sim_controls(lv_obj_t *parent);
/* Navigate to a screen. */
void      ui_goto(int screen);

/* Format helpers */
void fmt_hex32(char *buf, size_t n, uint32_t v);         /* 0x0000_0000 */
void fmt_u64(char *buf, size_t n, uint64_t v);           /* 1,234,567 */
void fmt_cpi(char *buf, size_t n, uint32_t milli);       /* 1.317 */

#endif
