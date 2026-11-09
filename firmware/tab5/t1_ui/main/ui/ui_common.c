/* Small widget helpers shared by the screens. */
#include <stdio.h>
#include <string.h>

#include "ui_internal.h"

lv_obj_t *ui_label(lv_obj_t *parent, const lv_font_t *font, uint32_t colour, const char *text)
{
    lv_obj_t *l = lv_label_create(parent);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(colour), 0);
    lv_label_set_text(l, text);
    return l;
}

lv_obj_t *ui_button(lv_obj_t *parent, const char *text, lv_event_cb_t cb, void *user)
{
    lv_obj_t *b = lv_button_create(parent);
    lv_obj_set_height(b, TOUCH_MIN);
    lv_obj_set_style_min_width(b, 120, 0);
    lv_obj_set_style_pad_hor(b, 20, 0);
    lv_obj_set_style_radius(b, 10, 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(C_PANEL2), 0);
    lv_obj_set_style_border_color(b, lv_color_hex(C_BORDER), 0);
    lv_obj_set_style_border_width(b, 2, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(C_ACCENT), LV_STATE_PRESSED);
    lv_obj_set_style_bg_color(b, lv_color_hex(C_ACCENT), LV_STATE_CHECKED);
    lv_obj_set_style_bg_color(b, lv_color_hex(C_PANEL), LV_STATE_DISABLED);
    lv_obj_set_style_text_color(b, lv_color_hex(C_MUTED), LV_STATE_DISABLED);
    lv_obj_set_style_border_opa(b, LV_OPA_40, LV_STATE_DISABLED);
    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_style_text_font(l, F_LABEL, 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    if (cb) {
        lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, user);
    }
    return b;
}

void ui_button_set_enabled(lv_obj_t *btn, bool en)
{
    if (en) {
        lv_obj_remove_state(btn, LV_STATE_DISABLED);
    } else {
        lv_obj_add_state(btn, LV_STATE_DISABLED);
    }
}

lv_obj_t *ui_row(lv_obj_t *parent)
{
    lv_obj_t *r = lv_obj_create(parent);
    lv_obj_remove_style_all(r);
    lv_obj_set_width(r, LV_PCT(100));
    lv_obj_set_height(r, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_flex_align(r, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_gap(r, 12, 0);
    lv_obj_remove_flag(r, LV_OBJ_FLAG_SCROLLABLE);
    return r;
}

lv_obj_t *ui_panel(lv_obj_t *parent, const char *title, lv_obj_t **badge_out)
{
    lv_obj_t *p = lv_obj_create(parent);
    lv_obj_set_style_bg_color(p, lv_color_hex(C_PANEL), 0);
    lv_obj_set_style_border_color(p, lv_color_hex(C_BORDER), 0);
    lv_obj_set_style_border_width(p, 1, 0);
    lv_obj_set_style_radius(p, 12, 0);
    lv_obj_set_style_pad_all(p, 16, 0);
    lv_obj_set_style_pad_gap(p, 8, 0);
    lv_obj_set_height(p, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(p, LV_FLEX_FLOW_COLUMN);
    lv_obj_remove_flag(p, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *head = lv_obj_create(p);
    lv_obj_remove_style_all(head);
    lv_obj_set_size(head, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(head, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(head, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_remove_flag(head, LV_OBJ_FLAG_SCROLLABLE);
    ui_label(head, F_LABEL, C_MUTED, title);

    lv_obj_t *badge = lv_label_create(head);
    lv_obj_set_style_text_font(badge, F_BODY, 0);
    lv_obj_set_style_bg_opa(badge, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(badge, 6, 0);
    lv_obj_set_style_pad_hor(badge, 8, 0);
    lv_obj_set_style_pad_ver(badge, 2, 0);
    lv_label_set_text(badge, g_ui.port->backend_is_mock ? "MOCK" : "NO DATA");
    lv_obj_set_style_bg_color(badge, lv_color_hex(C_MOCK_BG), 0);
    lv_obj_set_style_text_color(badge, lv_color_hex(C_AMBER), 0);
    if (badge_out) {
        *badge_out = badge;
    }
    return p;
}

void ui_badge_update(lv_obj_t *badge, const app_state_t *st, uint32_t now_ms)
{
    if (badge == NULL) {
        return;
    }
    const char *txt;
    char value[48];
    if (st->hw.snap.prov == PROV_NONE) {
        txt = g_ui.port->backend_is_mock ? "MOCK - NO DATA YET" : "NO DATA";
    } else if (app_state_is_stale(st, now_ms)) {
        snprintf(value,sizeof value,"%s - STALE",prov_name(st->hw.snap.prov)); txt=value;
    } else {
        txt = prov_name(st->hw.snap.prov);
    }
    /* Only touch LVGL when the text really changes. */
    if (strcmp(lv_label_get_text(badge), txt) != 0) {
        lv_label_set_text(badge, txt);
    }
}

void ui_set_text(lv_obj_t *label, const char *text)
{
    if (strcmp(lv_label_get_text(label), text) != 0) {
        lv_label_set_text(label, text);
    }
}

void ui_capture_badge(lv_obj_t *badge, const app_state_t *st, bool valid, uint32_t sample_ms, uint32_t now_ms)
{
    if(g_ui.port->backend_is_mock) { ui_badge_update(badge,st,now_ms); return; }
    char text[64];
    uint32_t age=now_ms-sample_ms;
    if(!valid) snprintf(text,sizeof text,"UNAVAILABLE");
    else snprintf(text,sizeof text,"CAPTURED %lu.%lus%s",(unsigned long)(age/1000),(unsigned long)(age/100%10),
                  st->hw.link!=LINK_CONNECTED || age>STALE_AFTER_MS ? " - STALE" : "");
    ui_set_text(badge,text);
}

lv_obj_t *ui_kv(lv_obj_t *parent, const char *key)
{
    lv_obj_t *r = lv_obj_create(parent);
    lv_obj_remove_style_all(r);
    lv_obj_set_size(r, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(r, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_remove_flag(r, LV_OBJ_FLAG_SCROLLABLE);
    ui_label(r, F_BODY, C_MUTED, key);
    lv_obj_t *v = ui_label(r, F_LABEL, C_TEXT, "-");
    return v;
}

lv_obj_t *ui_note(lv_obj_t *parent, const char *text)
{
    lv_obj_t *l = ui_label(parent, F_BODY, C_MUTED, text);
    lv_obj_set_width(l, LV_PCT(100));
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_WRAP);
    return l;
}

bool ui_send(ui_cmd_type_t type, uint32_t arg)
{
    ui_cmd_t c = { .type = type, .arg = arg };
    if (!g_ui.port->send_cmd(&c)) {
        g_ui.cmd_refused++;
        return false;
    }
    return true;
}

static void sim_cb(lv_event_t *e)
{
    ui_send((ui_cmd_type_t)(intptr_t)lv_event_get_user_data(e), 0);
}

void ui_sim_controls(lv_obj_t *parent)
{
    if(!g_ui.port->backend_is_mock) {
        lv_obj_t *p=ui_panel(parent,"Packet link",NULL);
        lv_obj_set_width(p,LV_PCT(100));
        ui_note(p,"Data comes from the negotiated FPGA endpoint. Captures have independent ages. CPU controls require advertised capabilities and a reconciled session.");
        ui_button(p,LV_SYMBOL_REFRESH " Reconnect",sim_cb,(void *)(intptr_t)CMD_LINK_RECONNECT);
        return;
    }
    lv_obj_t *p = ui_panel(parent, "MOCK simulation controls", NULL);
    lv_obj_set_width(p, LV_PCT(100));
    ui_note(p, "These only change the simulated link. They do not touch any hardware.");
    lv_obj_t *r = ui_row(p);
    ui_button(r, LV_SYMBOL_CLOSE " Unplug", sim_cb, (void *)(intptr_t)CMD_SIM_DISCONNECT);
    ui_button(r, LV_SYMBOL_REFRESH " Reconnect", sim_cb, (void *)(intptr_t)CMD_SIM_RECONNECT);
    ui_button(r, LV_SYMBOL_WARNING " Link error", sim_cb, (void *)(intptr_t)CMD_SIM_LINK_ERROR);
}

void fmt_hex32(char *buf, size_t n, uint32_t v)
{
    snprintf(buf, n, "0x%04lX_%04lX", (unsigned long)(v >> 16), (unsigned long)(v & 0xFFFFu));
}

void fmt_u64(char *buf, size_t n, uint64_t v)
{
    char tmp[32];
    int len = snprintf(tmp, sizeof tmp, "%llu", (unsigned long long)v);
    size_t o = 0;
    for (int i = 0; i < len && o + 1 < n; i++) {
        if (i > 0 && (len - i) % 3 == 0 && o + 2 < n) {
            buf[o++] = ',';
        }
        buf[o++] = tmp[i];
    }
    buf[o] = '\0';
}

void fmt_cpi(char *buf, size_t n, uint32_t milli)
{
    if (milli == 0) {
        snprintf(buf, n, "-");
    } else {
        snprintf(buf, n, "%lu.%03lu", (unsigned long)(milli / 1000u), (unsigned long)(milli % 1000u));
    }
}
