/* System: firmware/build info, memory and responsiveness measurements, link
 * statistics and the capability list (all missing at T1). */
#include <stdio.h>

#include "ui.h"
#include "ui_internal.h"

static lv_obj_t *s_badge;
static lv_obj_t *s_build, *s_plat, *s_up;
static lv_obj_t *s_heap, *s_heap_min, *s_int, *s_psram, *s_stack;
static lv_obj_t *s_render, *s_touch, *s_queue;
static lv_obj_t *s_link, *s_msgs;
static lv_obj_t *s_capabilities;

static const char *const k_caps[] = {
    "HELLO / PING / STATUS            T2",
    "Debug RAM read/write             T3",
    "HALT / RESUME / RESET            T4",
    "Register read/write              T4",
    "SD program loader + RUN          T5",
    "Atomic counters                  T5",
    "STEP / breakpoints               T6-T7",
    "Pipeline + trace capture         T8",
    "Memory / ALU BIST                T10",
    "Fault injection                  T11",
};

void scr_system_create(lv_obj_t *parent)
{
    lv_obj_t *row = ui_row(parent);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);

    lv_obj_t *p = ui_panel(row, "Tab5 firmware", NULL);
    lv_obj_set_width(p, g_ui.portrait ? LV_PCT(100) : LV_PCT(48));
    lv_obj_t *b = lv_obj_get_child(lv_obj_get_child(p, 0), 1);
    lv_label_set_text(b, "MEASURED"); /* these numbers are real, from the Tab5 itself */
    lv_obj_set_style_text_color(b, lv_color_hex(C_GREEN), 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(0x0F2A17), 0);
    s_build = ui_kv(p, "Build");
    s_plat = ui_kv(p, "Platform");
    s_up = ui_kv(p, "Uptime");
    s_heap = ui_kv(p, "Free heap");
    s_heap_min = ui_kv(p, "Lowest free heap");
    s_int = ui_kv(p, "Free internal RAM");
    s_psram = ui_kv(p, "Free PSRAM");
    s_stack = ui_kv(p, "Unused stack worker / LVGL");
    s_render = ui_kv(p, "Frame time last / max");
    s_touch = ui_kv(p, "Touch to frame last / max");
    s_queue = ui_kv(p, "Queue drops msg / cmd, peak");

    lv_obj_t *q = ui_panel(row, "FPGA link", &s_badge);
    lv_obj_set_width(q, g_ui.portrait ? LV_PCT(100) : LV_PCT(48));
    s_link = ui_kv(q, "Link changes");
    s_msgs = ui_kv(q, "Messages applied");
    ui_label(q, F_LABEL, C_TEXT, "Capabilities");
    s_capabilities=ui_label(q,F_LABEL,C_TEXT,"No capability descriptor received");
    ui_note(q,"Capabilities below are the milestone key. The received bit mask determines actual support; a screen can still need UI integration or a physical gate.");
    for (size_t i = 0; i < sizeof k_caps / sizeof k_caps[0]; i++) {
        ui_label(q, F_MONO, C_MUTED, k_caps[i]);
    }

    ui_sim_controls(parent);
}

void scr_system_update(const app_state_t *st, uint32_t now)
{
    char a[32], b[32], t[128];
    port_stats_t ps;
    ui_metrics_t m;
    g_ui.port->get_stats(&ps);
    ui_get_metrics(&m);
    ui_badge_update(s_badge, st, now);
    if(st->hw.have_id) {
        snprintf(t,sizeof t,"Reported capabilities: 0x%08lX%s",(unsigned long)st->hw.id.capabilities,
                 g_ui.port->backend_is_mock ? " (MOCK)" : ""); ui_set_text(s_capabilities,t);
    }

    ui_set_text(s_build, g_ui.port->build_info);
    ui_set_text(s_plat, g_ui.port->platform);
    snprintf(t, sizeof t, "%lu s", (unsigned long)(now / 1000u));
    ui_set_text(s_up, t);

    fmt_u64(a, sizeof a, ps.free_heap);
    snprintf(t, sizeof t, "%s B", a);
    ui_set_text(s_heap, t);
    fmt_u64(a, sizeof a, ps.min_free_heap);
    snprintf(t, sizeof t, "%s B", a);
    ui_set_text(s_heap_min, t);
    fmt_u64(a, sizeof a, ps.free_internal);
    snprintf(t, sizeof t, "%s B", a);
    ui_set_text(s_int, t);
    fmt_u64(a, sizeof a, ps.free_psram);
    snprintf(t, sizeof t, "%s B", a);
    ui_set_text(s_psram, t);
    fmt_u64(a, sizeof a, ps.worker_stack_free);
    fmt_u64(b, sizeof b, ps.ui_stack_free);
    snprintf(t, sizeof t, "%s / %s B", a, b);
    ui_set_text(s_stack, t);

    snprintf(t, sizeof t, "%lu.%01lu / %lu.%01lu ms",
             (unsigned long)(m.render_last_us / 1000u), (unsigned long)(m.render_last_us / 100u % 10u),
             (unsigned long)(m.render_max_us / 1000u), (unsigned long)(m.render_max_us / 100u % 10u));
    ui_set_text(s_render, t);
    snprintf(t, sizeof t, "%lu / %lu ms (%lu taps)", (unsigned long)m.touch_last_ms,
             (unsigned long)m.touch_max_ms, (unsigned long)m.touch_samples);
    ui_set_text(s_touch, t);
    lv_obj_set_style_text_color(s_touch, lv_color_hex(m.touch_max_ms > 100 ? C_AMBER : C_TEXT), 0);
    snprintf(t, sizeof t, "%lu / %lu, peak %lu", (unsigned long)ps.msg_queue_drops,
             (unsigned long)m.cmd_refused, (unsigned long)ps.msg_queue_peak);
    ui_set_text(s_queue, t);

    snprintf(t, sizeof t, "%lu", (unsigned long)st->hw.link_changes);
    ui_set_text(s_link, t);
    snprintf(t, sizeof t, "%lu", (unsigned long)st->hw.msgs_applied);
    ui_set_text(s_msgs, t);
}
