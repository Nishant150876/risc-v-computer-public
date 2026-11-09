/*
 * UI shell: top bar, MOCK banner, navigation, mode switch, screen switching
 * and the 5 Hz refresh. Screens live in scr_*.c.
 *
 * Every screen is built once at start and then shown or hidden, so leaving
 * a screen (or switching Demo/Engineering) never throws away its state.
 */
#include <stdio.h>
#include <string.h>

#include "ui.h"
#include "ui_internal.h"

ui_ctx_t g_ui;

/* ---- Screen table ----------------------------------------------------- */
const screen_def_t g_screens[SCR_COUNT] = {
    [SCR_HOME]      = { "Home",      LV_SYMBOL_HOME,     true,  false, "T1 MOCK, T5 live", NULL,
                        scr_home_create, scr_home_update },
    [SCR_PROGRAMS]  = { "Programs",  LV_SYMBOL_LIST,     true,  false, "T1 MOCK, T5 live", NULL,
                        scr_programs_create, scr_programs_update },
    [SCR_TERMINAL]  = { "Terminal",  LV_SYMBOL_KEYBOARD, true,  false, "T1 MOCK, T5 live", NULL,
                        scr_terminal_create, scr_terminal_update },
    [SCR_REGISTERS] = { "Registers", LV_SYMBOL_DIRECTORY, false, false, "T1 MOCK view, T4 live", NULL,
                        scr_registers_create, scr_registers_update },
    [SCR_COUNTERS]  = { "Counters",  LV_SYMBOL_BARS,     true,  false, "T1 MOCK, T5 baseline, T9 full", NULL,
                        scr_counters_create, scr_counters_update },
    [SCR_SYSTEM]    = { "System",    LV_SYMBOL_SETTINGS, false, false, "T1 MOCK, T2/T5 live", NULL,
                        scr_system_create, scr_system_update },
    [SCR_ABOUT]     = { "About",     LV_SYMBOL_IMAGE,    true,  false, "T1 static", NULL,
                        scr_about_create, NULL },
    [SCR_CPU]       = { "CPU Control", LV_SYMBOL_PLAY,   false, true,  "T4, then T6/T7",
                        "HALT, RESUME and RESET need the debug link (T2), the bus bridge (T3) and "
                        "safe execution control in the FPGA (T4). STEP and breakpoints follow at T6/T7.",
                        NULL, NULL },
    [SCR_MEMORY]    = { "Memory",    LV_SYMBOL_DRIVE,    false, true,  "T3 reset-held, T4 halted",
                        "Reading and editing RAM needs the Wishbone debug bridge and RAM ownership "
                        "control (T3). Edits while the CPU is halted come with T4.",
                        NULL, NULL },
    [SCR_PIPELINE]  = { "Pipeline",  LV_SYMBOL_SHUFFLE,  false, true,  "T8",
                        "IF/ID/EX/MEM/WB captures need coherent pipeline capture hardware (T8) on "
                        "the verified Phase 5 pipeline.",
                        NULL, NULL },
    [SCR_TRACE]     = { "Trace",     LV_SYMBOL_LOOP,     false, true,  "T8",
                        "Retirement trace needs the trace buffer and capture control (T8).",
                        NULL, NULL },
    [SCR_DIAG]      = { "Diagnostics", LV_SYMBOL_OK,     false, true,  "T10",
                        "Memory March test and ALU self-test run in FPGA hardware (T10). Nothing "
                        "is simulated here, so this screen stays locked until then.",
                        NULL, NULL },
    [SCR_FAULT]     = { "Fault Injection", LV_SYMBOL_CHARGE, false, true, "T11",
                        "Controlled fault injection needs the bounded hardware hook (T11).",
                        NULL, NULL },
    [SCR_REFERENCE] = { "Reference", LV_SYMBOL_COPY,     false, true,  "T12",
                        "Comparison against an independent RV32I reference needs complete trace "
                        "(T8) and the T12 comparison tool.",
                        NULL, NULL },
};

/* ---- Widgets owned by the shell --------------------------------------- */
static lv_obj_t *s_content;
static lv_obj_t *s_root[SCR_COUNT];
static lv_obj_t *s_nav;
static lv_obj_t *s_nav_btn[SCR_COUNT];
static lv_obj_t *s_mode_btn[2];
static lv_obj_t *s_ident;
static lv_obj_t *s_chip_link;
static lv_obj_t *s_chip_cpu;
static lv_obj_t *s_chip_age;
static lv_obj_t *s_source,*s_banner;
static lv_obj_t *s_scr_title;
static lv_obj_t *s_scr_meta;

static uint64_t s_refr_start_us;
static uint32_t s_press_ms;
static bool     s_press_pending;

/* ---- Measurements ----------------------------------------------------- */
static void refr_start_cb(lv_event_t *e)
{
    (void)e;
    s_refr_start_us = g_ui.port->now_us();
}

static void refr_ready_cb(lv_event_t *e)
{
    (void)e;
    uint64_t now = g_ui.port->now_us();
    uint32_t dt = (uint32_t)(now - s_refr_start_us);
    g_ui.render_last_us = dt;
    if (dt > g_ui.render_max_us) {
        g_ui.render_max_us = dt;
    }
    if (s_press_pending) {
        uint32_t lat = g_ui.port->now_ms() - s_press_ms;
        s_press_pending = false;
        g_ui.touch_last_ms = lat;
        if (lat > g_ui.touch_max_ms) {
            g_ui.touch_max_ms = lat;
        }
        g_ui.touch_samples++;
    }
}

static void indev_press_cb(lv_event_t *e)
{
    (void)e;
    s_press_ms = g_ui.port->now_ms();
    s_press_pending = true;
}

void ui_get_metrics(ui_metrics_t *out)
{
    out->render_last_us = g_ui.render_last_us;
    out->render_max_us = g_ui.render_max_us;
    out->touch_last_ms = g_ui.touch_last_ms;
    out->touch_max_ms = g_ui.touch_max_ms;
    out->touch_samples = g_ui.touch_samples;
    out->cmd_refused = g_ui.cmd_refused;
}

/* ---- Small styling helpers -------------------------------------------- */
static lv_obj_t *chip(lv_obj_t *parent)
{
    lv_obj_t *c = lv_label_create(parent);
    lv_obj_set_style_text_font(c, F_BODY, 0);
    lv_obj_set_style_bg_opa(c, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(c, lv_color_hex(C_PANEL2), 0);
    lv_obj_set_style_radius(c, 16, 0);
    lv_obj_set_style_pad_hor(c, 12, 0);
    lv_obj_set_style_pad_ver(c, 6, 0);
    lv_label_set_text(c, "-");
    return c;
}

static void chip_set(lv_obj_t *c, uint32_t colour, const char *text)
{
    if (strcmp(lv_label_get_text(c), text) != 0) {
        lv_label_set_text(c, text);
    }
    lv_obj_set_style_text_color(c, lv_color_hex(colour), 0);
}

static lv_obj_t *plain(lv_obj_t *parent)
{
    lv_obj_t *o = lv_obj_create(parent);
    lv_obj_remove_style_all(o);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    return o;
}

/* ---- Navigation ------------------------------------------------------- */
static void nav_cb(lv_event_t *e)
{
    ui_goto((int)(intptr_t)lv_event_get_user_data(e));
}

static void mode_cb(lv_event_t *e)
{
    ui_set_mode((ui_mode_t)(intptr_t)lv_event_get_user_data(e));
}

static bool screen_listed(int id)
{
    return g_ui.st->mode == MODE_ENGINEERING || g_screens[id].in_demo;
}

static void refresh_nav(void)
{
    for (int i = 0; i < SCR_COUNT; i++) {
        if (screen_listed(i)) {
            lv_obj_remove_flag(s_nav_btn[i], LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(s_nav_btn[i], LV_OBJ_FLAG_HIDDEN);
        }
        if (i == g_ui.st->screen) {
            lv_obj_add_state(s_nav_btn[i], LV_STATE_CHECKED);
        } else {
            lv_obj_remove_state(s_nav_btn[i], LV_STATE_CHECKED);
        }
    }
    for (int m = 0; m < 2; m++) {
        if ((int)g_ui.st->mode == m) {
            lv_obj_add_state(s_mode_btn[m], LV_STATE_CHECKED);
        } else {
            lv_obj_remove_state(s_mode_btn[m], LV_STATE_CHECKED);
        }
    }
}

static void update_visible(void)
{
    const screen_def_t *d = &g_screens[g_ui.st->screen];
    if (d->update) {
        d->update(g_ui.st, g_ui.port->now_ms());
    }
}

void ui_goto(int screen)
{
    if (screen < 0 || screen >= SCR_COUNT) {
        return;
    }
    g_ui.st->screen = screen;
    for (int i = 0; i < SCR_COUNT; i++) {
        if (i == screen) {
            lv_obj_remove_flag(s_root[i], LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(s_root[i], LV_OBJ_FLAG_HIDDEN);
        }
    }
    const screen_def_t *d = &g_screens[screen];
    lv_label_set_text_fmt(s_scr_title, "%s %s", d->symbol, d->name);
    lv_label_set_text_fmt(s_scr_meta, "%s  |  %s", d->locked ? "LOCKED" : g_ui.port->backend_is_mock ? "MOCK" : "PACKET LINK", d->milestone);
    refresh_nav();
    update_visible();
}

void ui_set_mode(ui_mode_t mode)
{
    /* A view change only touches view state. The hardware model, the mock
     * backend and the terminal buffer are left exactly as they are. */
    g_ui.st->mode = mode;
    if (!screen_listed(g_ui.st->screen)) {
        ui_goto(SCR_HOME);
    } else {
        refresh_nav();
    }
}

lv_obj_t *ui_screen_root(int screen)
{
    return (screen >= 0 && screen < SCR_COUNT) ? s_root[screen] : NULL;
}

/* ---- Locked screens --------------------------------------------------- */
static void locked_create(lv_obj_t *parent, const screen_def_t *d)
{
    lv_obj_t *p = ui_panel(parent, "Not available yet", NULL);
    lv_obj_set_width(p, LV_PCT(100));
    lv_obj_t *badge = lv_obj_get_child(lv_obj_get_child(p, 0), 1);
    lv_label_set_text(badge, "LOCKED");
    lv_obj_set_style_text_color(badge, lv_color_hex(C_MUTED), 0);
    lv_obj_set_style_bg_color(badge, lv_color_hex(C_PANEL2), 0);

    ui_label(p, F_HEAD, C_TEXT, d->name);
    lv_obj_t *m = ui_label(p, F_LABEL, C_AMBER, "");
    lv_label_set_text_fmt(m, LV_SYMBOL_WARNING " Becomes real at %s", d->milestone);
    lv_obj_t *n = ui_note(p, d->needs);
    lv_obj_set_style_text_font(n, F_LABEL, 0);
    ui_note(p, "No mock version is offered for this screen, so nothing here can be "
               "mistaken for hardware behaviour.");
}

/* ---- Top bar ---------------------------------------------------------- */
static void update_topbar(uint32_t now)
{
    const app_state_t *st = g_ui.st;
    const hw_model_t *hw = &st->hw;
    char buf[96];
    if(!g_ui.port->backend_is_mock) {
        ui_set_text(s_source,g_ui.port->test_fixture ? "PACKET TEST FIXTURE" : "FPGA PACKET LINK");
        ui_set_text(s_banner,g_ui.port->test_fixture ?
            "DESKTOP UI TEST FIXTURE: these values test rendering and controls. This is not an observed physical FPGA/Tab5 run." : hw->snap.prov==PROV_NONE ?
            "FPGA LINK: waiting for verified packets. Unavailable values stay blank." :
            "FPGA LINK: LIVE status; register/counter captures have independent ages. USB console remains separate; SD launcher pending.");
    }

    if (hw->have_id) {
        snprintf(buf, sizeof buf, "%s  |  %lu.%01lu MHz", hw->id.board,
                 (unsigned long)(hw->id.clock_hz / 1000000u),
                 (unsigned long)(hw->id.clock_hz / 100000u % 10u));
    } else {
        snprintf(buf, sizeof buf, "no device identity yet");
    }
    if (strcmp(lv_label_get_text(s_ident), buf) != 0) {
        lv_label_set_text(s_ident, buf);
    }

    uint32_t lc = hw->link == LINK_CONNECTED ? C_GREEN :
                  hw->link == LINK_CONNECTING ? C_AMBER : C_RED;
    snprintf(buf, sizeof buf, LV_SYMBOL_USB " %s", link_name(hw->link));
    chip_set(s_chip_link, lc, buf);

    if (app_state_is_stale(st, now)) {
        snprintf(buf, sizeof buf, "CPU %s (last known)", cpu_name(hw->snap.cpu));
        chip_set(s_chip_cpu, C_MUTED, buf);
    } else {
        snprintf(buf, sizeof buf, "CPU %s", cpu_name(hw->snap.cpu));
        chip_set(s_chip_cpu, hw->snap.cpu == CPU_RUNNING ? C_GREEN : C_MUTED, buf);
    }

    uint32_t age = app_state_data_age(st, now);
    if (age == UINT32_MAX) {
        chip_set(s_chip_age, C_MUTED, "no data");
    } else if (app_state_is_stale(st, now)) {
        snprintf(buf, sizeof buf, "STALE %lu s", (unsigned long)(age / 1000u));
        chip_set(s_chip_age, C_RED, buf);
    } else {
        snprintf(buf, sizeof buf, "data %lu.%01lu s", (unsigned long)(age / 1000u),
                 (unsigned long)(age / 100u % 10u));
        chip_set(s_chip_age, C_TEXT, buf);
    }
}

static void build_topbar(lv_obj_t *scr)
{
    lv_obj_t *bar = plain(scr);
    lv_obj_set_size(bar, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(bar, lv_color_hex(C_PANEL), 0);
    lv_obj_set_style_pad_hor(bar, 16, 0);
    lv_obj_set_style_pad_ver(bar, 8, 0);
    lv_obj_set_style_pad_gap(bar, 12, 0);
    lv_obj_set_flex_flow(bar, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_flex_align(bar, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

    lv_obj_t *title = plain(bar);
    lv_obj_set_size(title, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(title, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_grow(title, 1);
    lv_obj_set_style_min_width(title, 240, 0);
    ui_label(title, F_LABEL, C_TEXT, "RV32I Computer");
    s_ident = ui_label(title, F_BODY, C_MUTED, "");

    s_chip_link = chip(bar);
    s_chip_cpu = chip(bar);
    s_chip_age = chip(bar);

    /* The persistent MOCK badge. It is created once and never hidden. */
    lv_obj_t *mock = lv_label_create(bar);
    s_source=mock;
    lv_obj_set_style_text_font(mock, F_LABEL, 0);
    lv_obj_set_style_text_color(mock, lv_color_hex(C_AMBER), 0);
    lv_obj_set_style_bg_opa(mock, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(mock, lv_color_hex(C_MOCK_BG), 0);
    lv_obj_set_style_border_color(mock, lv_color_hex(C_AMBER), 0);
    lv_obj_set_style_border_width(mock, 2, 0);
    lv_obj_set_style_radius(mock, 8, 0);
    lv_obj_set_style_pad_hor(mock, 12, 0);
    lv_obj_set_style_pad_ver(mock, 6, 0);
    lv_label_set_text(mock, g_ui.port->backend_is_mock ? LV_SYMBOL_WARNING " MOCK DATA" : g_ui.port->test_fixture ? "PACKET TEST FIXTURE" : "FPGA PACKET LINK");

    lv_obj_t *seg = plain(bar);
    lv_obj_set_size(seg, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(seg, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_gap(seg, 4, 0);
    s_mode_btn[MODE_DEMO] = ui_button(seg, "Demo", mode_cb, (void *)(intptr_t)MODE_DEMO);
    s_mode_btn[MODE_ENGINEERING] = ui_button(seg, "Engineering", mode_cb,
                                             (void *)(intptr_t)MODE_ENGINEERING);

    /* Full-width banner under the bar. Also persistent. */
    lv_obj_t *ban = lv_label_create(scr);
    s_banner=ban;
    lv_obj_set_width(ban, LV_PCT(100));
    lv_obj_set_style_bg_opa(ban, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(ban, lv_color_hex(C_AMBER), 0);
    lv_obj_set_style_text_color(ban, lv_color_hex(0x1A1200), 0);
    lv_obj_set_style_text_font(ban, F_BODY, 0);
    lv_obj_set_style_pad_ver(ban, 4, 0);
    lv_obj_set_style_pad_hor(ban, 16, 0);
    lv_label_set_long_mode(ban, LV_LABEL_LONG_MODE_WRAP);
    lv_label_set_text(ban, g_ui.port->backend_is_mock ?
        "MOCK MODE: every value is simulated on the Tab5. Nothing on this screen comes from the FPGA." :
        "FPGA LINK: waiting for verified packets. LIVE status and CAPTURED data show their provenance; unavailable values stay blank.");
}

static void build_nav(lv_obj_t *parent)
{
    s_nav = plain(parent);
    lv_obj_add_flag(s_nav, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_opa(s_nav, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(s_nav, lv_color_hex(C_PANEL), 0);
    lv_obj_set_style_pad_all(s_nav, 8, 0);
    lv_obj_set_style_pad_gap(s_nav, 6, 0);
    if (g_ui.portrait) {
        lv_obj_set_size(s_nav, LV_PCT(100), TOUCH_MIN + 16);
        lv_obj_set_flex_flow(s_nav, LV_FLEX_FLOW_ROW);
        lv_obj_set_scroll_dir(s_nav, LV_DIR_HOR);
    } else {
        lv_obj_set_size(s_nav, 230, LV_PCT(100));
        lv_obj_set_flex_flow(s_nav, LV_FLEX_FLOW_COLUMN);
        lv_obj_set_scroll_dir(s_nav, LV_DIR_VER);
    }

    for (int i = 0; i < SCR_COUNT; i++) {
        const screen_def_t *d = &g_screens[i];
        char txt[48];
        snprintf(txt, sizeof txt, "%s  %s", d->symbol, d->name);
        lv_obj_t *b = ui_button(s_nav, txt, nav_cb, (void *)(intptr_t)i);
        lv_obj_t *l = lv_obj_get_child(b, 0);
        lv_obj_set_style_text_font(l, F_BODY, 0);
        if (!g_ui.portrait) {
            lv_obj_set_width(b, LV_PCT(100));
            lv_obj_align(l, LV_ALIGN_LEFT_MID, 0, 0);
        }
        if (d->locked) {
            /* Colour set on the button so the label inherits it, and the
             * checked (selected) state can still switch it to white. */
            lv_obj_set_style_text_color(b, lv_color_hex(C_MUTED), 0);
            lv_obj_set_style_text_color(b, lv_color_hex(0xFFFFFF), LV_STATE_CHECKED);
            lv_obj_set_style_border_opa(b, LV_OPA_30, 0);
        }
        s_nav_btn[i] = b;
    }
}

/* ---- Poll ------------------------------------------------------------- */
#define MAX_MSGS_PER_POLL 64

void ui_poll(void)
{
    dev_msg_t m;
    for (int i = 0; i < MAX_MSGS_PER_POLL && g_ui.port->recv_msg(&m); i++) {
        app_state_apply(g_ui.st, &m);
    }
    update_topbar(g_ui.port->now_ms());
    update_visible();
}

static void poll_timer_cb(lv_timer_t *t)
{
    (void)t;
    ui_poll();
}

/* ---- Init ------------------------------------------------------------- */
void ui_init(app_state_t *st, const ui_port_t *port)
{
    memset(&g_ui, 0, sizeof g_ui);
    g_ui.st = st;
    g_ui.port = port;

    lv_display_t *disp = lv_display_get_default();
    const int w = lv_display_get_horizontal_resolution(disp);
    const int h = lv_display_get_vertical_resolution(disp);
    g_ui.portrait = h > w;

    lv_display_add_event_cb(disp, refr_start_cb, LV_EVENT_REFR_START, NULL);
    lv_display_add_event_cb(disp, refr_ready_cb, LV_EVENT_REFR_READY, NULL);
    for (lv_indev_t *in = lv_indev_get_next(NULL); in; in = lv_indev_get_next(in)) {
        if (lv_indev_get_type(in) == LV_INDEV_TYPE_POINTER) {
            lv_indev_add_event_cb(in, indev_press_cb, LV_EVENT_PRESSED, NULL);
        }
    }

    lv_obj_t *scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, lv_color_hex(C_BG), 0);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
    lv_obj_set_style_text_color(scr, lv_color_hex(C_TEXT), 0);
    lv_obj_set_style_text_font(scr, F_BODY, 0);
    lv_obj_remove_flag(scr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_flex_flow(scr, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_all(scr, 0, 0);
    lv_obj_set_style_pad_gap(scr, 0, 0);

    build_topbar(scr);

    lv_obj_t *body = plain(scr);
    lv_obj_set_width(body, LV_PCT(100));
    lv_obj_set_flex_grow(body, 1);
    lv_obj_set_flex_flow(body, g_ui.portrait ? LV_FLEX_FLOW_COLUMN_REVERSE : LV_FLEX_FLOW_ROW);

    build_nav(body);

    lv_obj_t *main_col = plain(body);
    lv_obj_set_flex_grow(main_col, 1);
    if (g_ui.portrait) {
        lv_obj_set_width(main_col, LV_PCT(100));
    } else {
        lv_obj_set_height(main_col, LV_PCT(100));
    }
    lv_obj_set_flex_flow(main_col, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_all(main_col, 16, 0);
    lv_obj_set_style_pad_gap(main_col, 8, 0);

    lv_obj_t *hdr = plain(main_col);
    lv_obj_set_size(hdr, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(hdr, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_flex_align(hdr, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    s_scr_title = ui_label(hdr, F_HEAD, C_TEXT, "");
    s_scr_meta = ui_label(hdr, F_BODY, C_MUTED, "");

    s_content = plain(main_col);
    lv_obj_set_width(s_content, LV_PCT(100));
    lv_obj_set_flex_grow(s_content, 1);

    for (int i = 0; i < SCR_COUNT; i++) {
        lv_obj_t *r = plain(s_content);
        lv_obj_set_size(r, LV_PCT(100), LV_PCT(100));
        lv_obj_add_flag(r, LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_set_scroll_dir(r, LV_DIR_VER);
        lv_obj_set_flex_flow(r, LV_FLEX_FLOW_COLUMN);
        lv_obj_set_style_pad_gap(r, 12, 0);
        lv_obj_add_flag(r, LV_OBJ_FLAG_HIDDEN);
        s_root[i] = r;
        if (g_screens[i].create) {
            g_screens[i].create(r);
        } else {
            locked_create(r, &g_screens[i]);
        }
    }

    ui_goto(st->screen);
    update_topbar(port->now_ms());
    lv_timer_create(poll_timer_cb, 200, NULL);
}
