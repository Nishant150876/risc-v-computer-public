/* Counters: cumulative counters, overall CPI and an interval-CPI chart. */
#include <stdio.h>

#include "ui_internal.h"

static lv_obj_t *s_badge[2];
static lv_obj_t *s_cpi;
static lv_obj_t *s_v[9];
static lv_obj_t *s_chart;
static lv_chart_series_t *s_ser;
static lv_obj_t *s_chart_info;
static uint32_t s_seen_gen = UINT32_MAX;

static const char *const k_names[9] = {
    "Cycles", "Instructions retired", "Load-use stall cycles", "Flush cycles",
    "Loads", "Stores", "Branches", "Branches taken", "Jumps",
};

void scr_counters_create(lv_obj_t *parent)
{
    lv_obj_t *row = ui_row(parent);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);

    lv_obj_t *p = ui_panel(row, "Counters", &s_badge[0]);
    lv_obj_set_width(p, g_ui.portrait ? LV_PCT(100) : LV_PCT(40));
    ui_label(p, F_BODY, C_MUTED, "CPI, whole run");
    s_cpi = ui_label(p, F_BIG, C_TEXT, "-");
    for (int i = 0; i < 9; i++) {
        s_v[i] = ui_kv(p, k_names[i]);
    }
    lv_obj_t *r = ui_row(p);
    lv_obj_t *ex = ui_button(r, LV_SYMBOL_SAVE " Export", NULL, NULL);
    ui_button_set_enabled(ex, false);
    ui_label(r, F_BODY, C_MUTED, "Export to SD needs T5");

    lv_obj_t *c = ui_panel(row, "Interval CPI (each 200 ms)", &s_badge[1]);
    lv_obj_set_width(c, g_ui.portrait ? LV_PCT(100) : LV_PCT(57));
    s_chart = lv_chart_create(c);
    lv_obj_set_size(s_chart, LV_PCT(100), 300);
    lv_chart_set_type(s_chart, LV_CHART_TYPE_LINE);
    lv_chart_set_point_count(s_chart, CPI_HISTORY);
    lv_chart_set_axis_range(s_chart, LV_CHART_AXIS_PRIMARY_Y, 1000, 1600);
    lv_chart_set_div_line_count(s_chart, 7, 6);
    lv_chart_set_update_mode(s_chart, LV_CHART_UPDATE_MODE_SHIFT);
    lv_obj_set_style_bg_color(s_chart, lv_color_hex(0x05070A), 0);
    lv_obj_set_style_border_color(s_chart, lv_color_hex(C_BORDER), 0);
    lv_obj_set_style_line_color(s_chart, lv_color_hex(C_BORDER), LV_PART_MAIN);
    lv_obj_set_style_size(s_chart, 0, 0, LV_PART_INDICATOR); /* no point dots */
    lv_obj_set_style_line_width(s_chart, 3, LV_PART_ITEMS);
    s_ser = lv_chart_add_series(s_chart, lv_color_hex(C_AMBER), LV_CHART_AXIS_PRIMARY_Y);
    lv_chart_set_all_values(s_chart, s_ser, LV_CHART_POINT_NONE);
    s_chart_info = ui_label(c, F_BODY, C_MUTED, "Y axis 1.0 to 1.6 CPI, newest on the right.");

    lv_obj_t *d = ui_panel(parent, "Definitions", NULL);
    lv_obj_set_width(d, LV_PCT(100));
    lv_obj_add_flag(lv_obj_get_child(lv_obj_get_child(d, 0), 1), LV_OBJ_FLAG_HIDDEN);
    ui_note(d, "CPI = cycles / instructions retired. Load-use stall: a cycle the pipeline "
               "waited for a load result. Flush: a cycle lost to a taken branch or jump. "
               "Real counters are read atomically from the FPGA at T5 (baseline) and T9 (full).");
}

void scr_counters_update(const app_state_t *st, uint32_t now)
{
    const hw_model_t *hw = &st->hw;
    char b[96];
    ui_capture_badge(s_badge[0], st, (hw->snap.counter_mask & 3u)==3u, hw->snap.counter_t_ms, now);
    ui_capture_badge(s_badge[1], st, (hw->snap.counter_mask & 3u)==3u, hw->snap.counter_t_ms, now);
    if (hw->snap.prov == PROV_NONE) {
        return;
    }
    const counters_t *c = &hw->snap.ctr;
    const uint64_t v[9] = { c->cycles, c->instret, c->stalls, c->flushes,
                            c->loads, c->stores, c->branches, c->taken, c->jumps };
    for (int i = 0; i < 9; i++) {
        if(hw->snap.counter_mask & (1u<<i)) fmt_u64(b, sizeof b, v[i]); else snprintf(b,sizeof b,"-");
        ui_set_text(s_v[i], b);
    }
    if((hw->snap.counter_mask & 3u)==3u) fmt_cpi(b, sizeof b, counters_cpi_milli(c)); else snprintf(b,sizeof b,"-");
    ui_set_text(s_cpi, b);
    lv_obj_set_style_text_color(s_cpi, lv_color_hex(app_state_is_stale(st, now) ? C_MUTED : C_TEXT), 0);

    if (hw->snap.generation != s_seen_gen) {
        s_seen_gen = hw->snap.generation;
        /* Redraw the whole series from the model so the chart always matches it. */
        lv_chart_set_all_values(s_chart, s_ser, LV_CHART_POINT_NONE);
        int32_t *ys = lv_chart_get_series_y_array(s_chart, s_ser);
        int first = CPI_HISTORY - hw->cpi_count;
        for (int i = 0; i < hw->cpi_count; i++) {
            ys[first + i] = hw->cpi_hist[i];
        }
        lv_chart_set_x_start_point(s_chart, s_ser, 0);
        lv_chart_refresh(s_chart);
        if (hw->cpi_count) {
            char cp[16];
            fmt_cpi(cp, sizeof cp, hw->cpi_hist[hw->cpi_count - 1]);
            snprintf(b, sizeof b, "Latest interval CPI %s (%s). Y axis 1.0 to 1.6.", cp, g_ui.port->backend_is_mock ? "MOCK" : "CAPTURED");
            ui_set_text(s_chart_info, b);
        }
    }
}
