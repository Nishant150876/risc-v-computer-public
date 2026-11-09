/* Terminal: bounded console buffer with scroll, clear and visible overflow.
 * At T1 the text comes from the MOCK backend and every line says so. */
#include <stdio.h>

#include "ui_internal.h"

static lv_obj_t *s_badge;
static lv_obj_t *s_box;
static lv_obj_t *s_text;
static lv_obj_t *s_info;
static lv_obj_t *s_follow_btn;
static uint32_t  s_seen_gen = UINT32_MAX;
static bool      s_follow = true;

static void clear_cb(lv_event_t *e)
{
    (void)e;
    app_state_console_clear(g_ui.st);
    scr_terminal_update(g_ui.st, g_ui.port->now_ms());
}

static void follow_cb(lv_event_t *e)
{
    (void)e;
    s_follow = !s_follow;
    if (s_follow) {
        lv_obj_add_state(s_follow_btn, LV_STATE_CHECKED);
        lv_obj_scroll_to_y(s_box, LV_COORD_MAX, LV_ANIM_OFF);
    } else {
        lv_obj_remove_state(s_follow_btn, LV_STATE_CHECKED);
    }
}

/* Dragging the text up stops auto-follow, like a normal terminal. */
static void scroll_cb(lv_event_t *e)
{
    (void)e;
    if (lv_obj_get_scroll_bottom(s_box) > 40 && s_follow) {
        s_follow = false;
        lv_obj_remove_state(s_follow_btn, LV_STATE_CHECKED);
    }
}

void scr_terminal_create(lv_obj_t *parent)
{
    lv_obj_t *p = ui_panel(parent, "CPU console", &s_badge);
    lv_obj_set_width(p, LV_PCT(100));
    lv_obj_set_flex_grow(p, 1);

    lv_obj_t *r = ui_row(p);
    ui_button(r, LV_SYMBOL_TRASH " Clear", clear_cb, NULL);
    s_follow_btn = ui_button(r, LV_SYMBOL_DOWN " Follow", follow_cb, NULL);
    lv_obj_add_state(s_follow_btn, LV_STATE_CHECKED);
    lv_obj_t *in = ui_button(r, LV_SYMBOL_KEYBOARD " Input", NULL, NULL);
    ui_button_set_enabled(in, false);
    ui_label(r, F_BODY, C_MUTED, "Input needs T5");
    s_info = ui_label(p, F_BODY, C_MUTED, "");

    s_box = lv_obj_create(p);
    lv_obj_set_width(s_box, LV_PCT(100));
    lv_obj_set_flex_grow(s_box, 1);
    lv_obj_set_style_min_height(s_box, 300, 0);
    lv_obj_set_style_bg_color(s_box, lv_color_hex(0x05070A), 0);
    lv_obj_set_style_border_color(s_box, lv_color_hex(C_BORDER), 0);
    lv_obj_set_style_radius(s_box, 8, 0);
    lv_obj_set_style_pad_all(s_box, 10, 0);
    lv_obj_set_scroll_dir(s_box, LV_DIR_VER);
    lv_obj_add_event_cb(s_box, scroll_cb, LV_EVENT_SCROLL_END, NULL);

    s_text = ui_label(s_box, F_MONO, 0xB8F5C0, "");
    lv_obj_set_width(s_text, LV_PCT(100));
    lv_label_set_long_mode(s_text, LV_LABEL_LONG_MODE_WRAP);
}

void scr_terminal_update(const app_state_t *st, uint32_t now)
{
    const hw_model_t *hw = &st->hw;
    ui_badge_update(s_badge, st, now);
    if(!g_ui.port->backend_is_mock) {
        ui_set_text(s_badge,"UNAVAILABLE");
        ui_set_text(s_info,"Packet console is pending. CPU console remains on the separate USB UART.");
        return;
    }

    char b[96];
    snprintf(b, sizeof b, "buffer %u / %u bytes  |  %lu bytes dropped (oldest lines)",
             (unsigned)hw->console_len, (unsigned)CONSOLE_BYTES, (unsigned long)hw->console_dropped);
    ui_set_text(s_info, b);
    lv_obj_set_style_text_color(s_info, lv_color_hex(hw->console_dropped ? C_AMBER : C_MUTED), 0);

    if (hw->console_gen != s_seen_gen) {
        s_seen_gen = hw->console_gen;
        lv_label_set_text(s_text, hw->console);
        if (s_follow) {
            lv_obj_update_layout(s_box);
            lv_obj_scroll_to_y(s_box, LV_COORD_MAX, LV_ANIM_OFF);
        }
    }
}
