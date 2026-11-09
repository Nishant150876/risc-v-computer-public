/* Registers: x0-x31 with ABI names, hex/decimal view, changed highlight and a
 * detail line with binary. Read-only at T1; halted edits come with T4. */
#include <stdio.h>

#include "ui_internal.h"

static lv_obj_t *s_badge;
static lv_obj_t *s_cell[32];
static lv_obj_t *s_val[32];
static lv_obj_t *s_hex_btn, *s_dec_btn;
static lv_obj_t *s_detail;
static lv_obj_t *s_pcs;

static void view_cb(lv_event_t *e)
{
    g_ui.st->reg_decimal = (bool)(intptr_t)lv_event_get_user_data(e);
    scr_registers_update(g_ui.st, g_ui.port->now_ms());
}

static void cell_cb(lv_event_t *e)
{
    int i = (int)(intptr_t)lv_event_get_user_data(e);
    g_ui.st->reg_selected = (g_ui.st->reg_selected == i) ? -1 : i;
    scr_registers_update(g_ui.st, g_ui.port->now_ms());
}

void scr_registers_create(lv_obj_t *parent)
{
    lv_obj_t *top = ui_panel(parent, "View", &s_badge);
    lv_obj_set_width(top, LV_PCT(100));
    lv_obj_t *r = ui_row(top);
    s_hex_btn = ui_button(r, "Hex", view_cb, (void *)(intptr_t)0);
    s_dec_btn = ui_button(r, "Decimal", view_cb, (void *)(intptr_t)1);
    lv_obj_t *ed = ui_button(r, LV_SYMBOL_EDIT " Edit", NULL, NULL);
    ui_button_set_enabled(ed, false);
    ui_label(r, F_BODY, C_MUTED,g_ui.port->backend_is_mock ? "Edit needs T4: live link + halted CPU" : "Host register editing available; touchscreen editor pending");
    s_pcs = ui_label(top, F_LABEL, C_TEXT, "");
    s_detail = ui_label(top, F_LABEL, C_TEXT, "Tap a register for its binary value.");
    lv_obj_set_width(s_detail, LV_PCT(100));
    lv_label_set_long_mode(s_detail, LV_LABEL_LONG_MODE_WRAP);

    lv_obj_t *grid = ui_row(parent);
    lv_obj_set_style_pad_gap(grid, 8, 0);
    for (int i = 0; i < 32; i++) {
        lv_obj_t *c = lv_obj_create(grid);
        lv_obj_set_size(c, LV_PCT(23), LV_SIZE_CONTENT);
        lv_obj_set_style_min_height(c, TOUCH_MIN, 0);
        lv_obj_set_style_bg_color(c, lv_color_hex(C_PANEL), 0);
        lv_obj_set_style_border_color(c, lv_color_hex(C_BORDER), 0);
        lv_obj_set_style_border_width(c, 1, 0);
        lv_obj_set_style_radius(c, 8, 0);
        lv_obj_set_style_pad_all(c, 8, 0);
        lv_obj_set_style_pad_gap(c, 2, 0);
        lv_obj_set_flex_flow(c, LV_FLEX_FLOW_COLUMN);
        lv_obj_remove_flag(c, LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_add_flag(c, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_set_style_bg_color(c, lv_color_hex(C_PANEL2), LV_STATE_PRESSED);
        lv_obj_add_event_cb(c, cell_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
        lv_obj_t *n = ui_label(c, F_BODY, C_MUTED, "");
        lv_label_set_text_fmt(n, "x%d  %s", i, reg_abi_name(i));
        s_val[i] = ui_label(c, F_LABEL, C_TEXT, "-");
        s_cell[i] = c;
    }
}

static void fmt_bin(char *b, size_t n, uint32_t v)
{
    size_t o = 0;
    for (int bit = 31; bit >= 0 && o + 2 < n; bit--) {
        b[o++] = (v >> bit) & 1u ? '1' : '0';
        if (bit % 4 == 0 && bit && o + 2 < n) {
            b[o++] = ' ';
        }
    }
    b[o] = '\0';
}

void scr_registers_update(const app_state_t *st, uint32_t now)
{
    const hw_model_t *hw = &st->hw;
    char b[160];
    ui_capture_badge(s_badge, st, hw->snap.regs_valid, hw->snap.regs_t_ms, now);

    if (st->reg_decimal) {
        lv_obj_add_state(s_dec_btn, LV_STATE_CHECKED);
        lv_obj_remove_state(s_hex_btn, LV_STATE_CHECKED);
    } else {
        lv_obj_add_state(s_hex_btn, LV_STATE_CHECKED);
        lv_obj_remove_state(s_dec_btn, LV_STATE_CHECKED);
    }

    bool have = hw->snap.regs_valid;
    bool stale = app_state_is_stale(st, now) || (!g_ui.port->backend_is_mock && now-hw->snap.regs_t_ms>STALE_AFTER_MS);
    if (have) {
        char pc[16], lp[16];
        fmt_hex32(pc, sizeof pc, hw->snap.pc);
        fmt_hex32(lp, sizeof lp, hw->snap.last_pc);
        snprintf(b, sizeof b, "next PC %s   last retired %s   snapshot #%lu", pc, lp,
                 (unsigned long)hw->snap.regs_generation);
        ui_set_text(s_pcs, b);
    } else ui_set_text(s_pcs,"No halted register capture available.");

    for (int i = 0; i < 32; i++) {
        uint32_t v = hw->snap.regs[i];
        if (!have) {
            snprintf(b, sizeof b, "-");
        } else if (st->reg_decimal) {
            snprintf(b, sizeof b, "%ld", (long)(int32_t)v);
        } else {
            fmt_hex32(b, sizeof b, v);
        }
        ui_set_text(s_val[i], b);
        bool changed = (hw->changed_regs >> i) & 1u;
        bool sel = st->reg_selected == i;
        lv_obj_set_style_bg_color(s_cell[i], lv_color_hex(changed ? C_CHANGED : C_PANEL), 0);
        lv_obj_set_style_border_color(s_cell[i], lv_color_hex(sel ? C_ACCENT : changed ? C_AMBER : C_BORDER), 0);
        lv_obj_set_style_border_width(s_cell[i], sel ? 3 : 1, 0);
        lv_obj_set_style_text_color(s_val[i], lv_color_hex(stale ? C_MUTED : C_TEXT), 0);
    }

    int s = st->reg_selected;
    if (s >= 0 && s < 32 && have) {
        uint32_t v = hw->snap.regs[s];
        char hx[16], bn[48];
        fmt_hex32(hx, sizeof hx, v);
        fmt_bin(bn, sizeof bn, v);
        snprintf(b, sizeof b, "x%d (%s) = %s = %lu = %ld\n%s", s, reg_abi_name(s), hx,
                 (unsigned long)v, (long)(int32_t)v, bn);
        ui_set_text(s_detail, b);
    } else {
        ui_set_text(s_detail, "Tap a register for its binary value. Amber = changed in the last snapshot.");
    }
}
