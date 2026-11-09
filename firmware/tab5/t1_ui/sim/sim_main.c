/*
 * Desktop simulator and UI test for the T1 firmware.
 *
 * Builds the same state/, device/ and ui/ sources as the Tab5 against LVGL
 * 9.5 with an in-memory display and a scripted touch input. Time is
 * simulated, so the run is deterministic. Taps go through LVGL's own hit
 * testing at the centre of the real widget, like a finger would.
 *
 * Usage: t1_sim <out_dir> [--portrait]
 * Writes PPM screenshots into out_dir and prints one line per check.
 * Exit status 0 only when every check passes.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lvgl.h"

#include "device/mock_device.h"
#include "port/ui_port.h"
#include "state/app_state.h"
#include "ui/screens.h"
#include "ui/ui.h"

/* ---- Simulated time --------------------------------------------------- */
static uint32_t g_now;
static uint32_t tick_cb(void) { return g_now; }
static uint32_t now_ms(void) { return g_now; }
static uint64_t now_us(void) { return (uint64_t)g_now * 1000u; }

/* ---- Bounded queues, same sizes as app_main.c ------------------------- */
#define MSG_CAP 32
#define CMD_CAP 8
static dev_msg_t q_msg[MSG_CAP];
static int       q_msg_head, q_msg_n;
static ui_cmd_t  q_cmd[CMD_CAP];
static int       q_cmd_head, q_cmd_n;
static uint32_t  g_drops, g_peak;

static bool send_cmd(const ui_cmd_t *c)
{
    if (q_cmd_n == CMD_CAP) {
        return false;
    }
    q_cmd[(q_cmd_head + q_cmd_n++) % CMD_CAP] = *c;
    return true;
}

static bool recv_msg(dev_msg_t *m)
{
    if (q_msg_n == 0) {
        return false;
    }
    *m = q_msg[q_msg_head];
    q_msg_head = (q_msg_head + 1) % MSG_CAP;
    q_msg_n--;
    return true;
}

static void emit(void *ctx, const dev_msg_t *m)
{
    (void)ctx;
    if (q_msg_n == MSG_CAP) {
        g_drops++;
        return;
    }
    q_msg[(q_msg_head + q_msg_n++) % MSG_CAP] = *m;
    if ((uint32_t)q_msg_n > g_peak) {
        g_peak = (uint32_t)q_msg_n;
    }
}

static void get_stats(port_stats_t *o)
{
    memset(o, 0, sizeof *o);
    o->msg_queue_drops = g_drops;
    o->msg_queue_peak = g_peak;
}

static ui_port_t g_port = {
    .now_ms = now_ms,
    .now_us = now_us,
    .send_cmd = send_cmd,
    .recv_msg = recv_msg,
    .get_stats = get_stats,
    .build_info = "t1_ui desktop simulator",
    .platform = "desktop simulator (LVGL 9.5)",
    .backend_is_mock = true,
};

/* ---- Display ---------------------------------------------------------- */
static int       W, H;
static uint16_t *g_fb;

static void flush_cb(lv_display_t *d, const lv_area_t *a, uint8_t *px)
{
    const uint16_t *src = (const uint16_t *)px;
    int w = lv_area_get_width(a);
    for (int y = a->y1; y <= a->y2; y++) {
        memcpy(&g_fb[y * W + a->x1], &src[(y - a->y1) * w], (size_t)w * 2);
    }
    lv_display_flush_ready(d);
}

static void save_ppm(const char *dir, const char *name)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s.ppm", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f) {
        perror(path);
        exit(2);
    }
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    for (int i = 0; i < W * H; i++) {
        uint16_t p = g_fb[i];
        uint8_t rgb[3] = {
            (uint8_t)(((p >> 11) & 0x1F) * 255 / 31),
            (uint8_t)(((p >> 5) & 0x3F) * 255 / 63),
            (uint8_t)((p & 0x1F) * 255 / 31),
        };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
}

/* ---- Touch ------------------------------------------------------------ */
static bool    g_pressed;
static int32_t g_tx, g_ty;

static void read_cb(lv_indev_t *in, lv_indev_data_t *data)
{
    (void)in;
    data->point.x = g_tx;
    data->point.y = g_ty;
    data->state = g_pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

/* ---- Main loop -------------------------------------------------------- */
static mock_device_t g_dev;
static bool          g_mock_paused;
static app_state_t   g_st;

static void advance(uint32_t ms)
{
    for (uint32_t t = 0; t < ms; t += 5) {
        g_now += 5;
        if (!g_mock_paused && g_now % 20 == 0) {
            ui_cmd_t c;
            while (q_cmd_n) {
                c = q_cmd[q_cmd_head];
                q_cmd_head = (q_cmd_head + 1) % CMD_CAP;
                q_cmd_n--;
                mock_device_command(&g_dev, &c, g_now, emit, NULL);
            }
            mock_device_step(&g_dev, g_now, emit, NULL);
        }
        lv_timer_handler();
    }
}

/* ---- Checks ----------------------------------------------------------- */
static int g_fail, g_pass;

static void check(bool ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s  ", ok ? "PASS" : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    if (ok) {
        g_pass++;
    } else {
        g_fail++;
    }
}

/* Visible label whose text contains s, searched depth first. */
static lv_obj_t *find_label(lv_obj_t *root, const char *s)
{
    if (lv_obj_has_flag(root, LV_OBJ_FLAG_HIDDEN)) {
        return NULL;
    }
    if (lv_obj_check_type(root, &lv_label_class) && strstr(lv_label_get_text(root), s)) {
        return root;
    }
    uint32_t n = lv_obj_get_child_count(root);
    for (uint32_t i = 0; i < n; i++) {
        lv_obj_t *r = find_label(lv_obj_get_child(root, (int32_t)i), s);
        if (r) {
            return r;
        }
    }
    return NULL;
}

/* Is any label under root showing the whole word w (upper case)? */
static bool any_word(lv_obj_t *root, const char *w)
{
    if (lv_obj_has_flag(root, LV_OBJ_FLAG_HIDDEN)) {
        return false;
    }
    if (lv_obj_check_type(root, &lv_label_class)) {
        const char *t = lv_label_get_text(root);
        size_t n = strlen(w);
        for (const char *p = strstr(t, w); p; p = strstr(p + 1, w)) {
            bool l = p == t || !((p[-1] >= 'A' && p[-1] <= 'Z') || (p[-1] >= 'a' && p[-1] <= 'z'));
            bool r = !((p[n] >= 'A' && p[n] <= 'Z') || (p[n] >= 'a' && p[n] <= 'z'));
            if (l && r) {
                return true;
            }
        }
    }
    uint32_t n = lv_obj_get_child_count(root);
    for (uint32_t i = 0; i < n; i++) {
        if (any_word(lv_obj_get_child(root, (int32_t)i), w)) {
            return true;
        }
    }
    return false;
}

/* Tap the clickable widget that holds the label with text s. */
static bool tap_text(const char *s)
{
    lv_obj_t *l = find_label(lv_screen_active(), s);
    if (!l) {
        printf("      (no visible widget with text \"%s\")\n", s);
        return false;
    }
    lv_obj_t *o = l;
    while (o && !lv_obj_has_flag(o, LV_OBJ_FLAG_CLICKABLE)) {
        o = lv_obj_get_parent(o);
    }
    if (!o) {
        return false;
    }
    lv_obj_scroll_to_view_recursive(o, LV_ANIM_OFF);
    advance(40);
    lv_area_t a;
    lv_obj_get_coords(o, &a);
    g_tx = (a.x1 + a.x2) / 2;
    g_ty = (a.y1 + a.y2) / 2;
    g_pressed = true;
    advance(80);
    g_pressed = false;
    advance(80);
    return true;
}

/* Is any label containing s actually on screen (not hidden, not scrolled away)? */
static bool visible_in(lv_obj_t *root, const char *s)
{
    if (lv_obj_has_flag(root, LV_OBJ_FLAG_HIDDEN)) {
        return false;
    }
    if (lv_obj_check_type(root, &lv_label_class) && strstr(lv_label_get_text(root), s) &&
        lv_obj_is_visible(root)) {
        return true;
    }
    uint32_t n = lv_obj_get_child_count(root);
    for (uint32_t i = 0; i < n; i++) {
        if (visible_in(lv_obj_get_child(root, (int32_t)i), s)) {
            return true;
        }
    }
    return false;
}

static bool visible(const char *s)
{
    return visible_in(lv_screen_active(), s);
}

static lv_obj_t *nav_button(int id)
{
    char t[48];
    snprintf(t, sizeof t, "%s  %s", g_screens[id].symbol, g_screens[id].name);
    lv_obj_t *l = find_label(lv_screen_active(), t);
    return l ? lv_obj_get_parent(l) : NULL;
}

static bool goto_screen(int id)
{
    char t[48];
    snprintf(t, sizeof t, "%s  %s", g_screens[id].symbol, g_screens[id].name);
    return tap_text(t) && g_st.screen == id;
}

static void shot(const char *dir, const char *name)
{
    lv_obj_invalidate(lv_screen_active());
    lv_refr_now(lv_display_get_default());
    advance(60);
    save_ppm(dir, name);
}

/* ---- Scenario --------------------------------------------------------- */
static int packet_fixture(const char *out,const char *prefix)
{
    char name[80];
    advance(250);
    check(visible("PACKET TEST FIXTURE") && visible("NO DATA"),"packet fixture starts without invented FPGA data");
    dev_msg_t m={.type=MSG_LINK,.t_ms=g_now}; m.u.link.state=LINK_CONNECTED;
    strcpy(m.u.link.reason,"UI test fixture, no physical hardware"); emit(NULL,&m);
    m=(dev_msg_t){.type=MSG_IDENTITY,.t_ms=g_now}; strcpy(m.u.id.board,"UI packet fixture");
    strcpy(m.u.id.core,"UI fixture only"); m.u.id.clock_hz=25000000; m.u.id.capabilities=1; emit(NULL,&m);
    m=(dev_msg_t){.type=MSG_SNAPSHOT,.t_ms=g_now}; m.u.snap.prov=PROV_LIVE;
    m.u.snap.cpu=CPU_RUNNING; m.u.snap.pc=8; m.u.snap.pc_valid=2; emit(NULL,&m); advance(250);
    check(visible("LIVE") && !g_st.hw.snap.regs_valid && g_st.hw.snap.counter_mask==0,"decoded-status view keeps unsupported registers/counters unavailable");
    check(tap_text("Engineering") && goto_screen(SCR_REGISTERS),"packet register view reachable");
    check(find_label(ui_screen_root(SCR_REGISTERS),"UNAVAILABLE") && !find_label(ui_screen_root(SCR_REGISTERS),"0x"),"unavailable registers do not display fabricated zeros");
    goto_screen(SCR_COUNTERS);
    check(find_label(ui_screen_root(SCR_COUNTERS),"UNAVAILABLE"),"unavailable counter capture is labelled");
    goto_screen(SCR_PROGRAMS);
    lv_obj_t *label=find_label(ui_screen_root(SCR_PROGRAMS),"Simulate load");
    check(label && lv_obj_has_state(lv_obj_get_parent(label),LV_STATE_DISABLED),"MOCK program buttons disabled on packet backend");
    goto_screen(SCR_TERMINAL);
    check(find_label(ui_screen_root(SCR_TERMINAL),"UNAVAILABLE") && g_st.hw.console_len==0,"no invented packet console");
    m=(dev_msg_t){.type=MSG_IDENTITY,.t_ms=g_now}; strcpy(m.u.id.board,"UI packet fixture");
    strcpy(m.u.id.core,"UI fixture only"); m.u.id.clock_hz=25000000; m.u.id.capabilities=0xeff7; m.u.id.can_halt=true; m.u.id.can_step=true; emit(NULL,&m);
    m=(dev_msg_t){.type=MSG_SNAPSHOT,.t_ms=g_now}; m.u.snap.prov=PROV_LIVE;
    m.u.snap.cpu=CPU_HALTED; m.u.snap.pc=8; m.u.snap.last_pc=4; m.u.snap.pc_valid=3;
    m.u.snap.regs_valid=true; m.u.snap.regs[2]=0x10000; m.u.snap.regs[5]=0x12345678; m.u.snap.image_valid=true;
    m.u.snap.regs_t_ms=g_now; m.u.snap.counter_t_ms=g_now; m.u.snap.regs_generation=12; m.u.snap.counter_generation=7;
    m.u.snap.counter_mask=0x173; m.u.snap.ctr.cycles=500; m.u.snap.ctr.instret=250;
    emit(NULL,&m); advance(250); goto_screen(SCR_HOME);
    label=find_label(ui_screen_root(SCR_HOME),"Step one instruction");
    check(label && !lv_obj_has_state(lv_obj_get_parent(label),LV_STATE_DISABLED),"step enabled by real-link policy only with capability, halt and verified image");
    check(tap_text("Step one instruction") && q_cmd_n==1 && q_cmd[q_cmd_head].type==CMD_CPU_STEP,"step tap enqueues one command without waiting for serial");
    snprintf(name,sizeof name,"%spacket_home_fixture",prefix); shot(out,name);
    goto_screen(SCR_REGISTERS);
    check(find_label(ui_screen_root(SCR_REGISTERS),"CAPTURED") && find_label(ui_screen_root(SCR_REGISTERS),"0x0001_0000"),"halted register capture has provenance and actual displayed value");
    snprintf(name,sizeof name,"%spacket_register_fixture",prefix); shot(out,name);
    advance(2000); m.t_ms=g_now; emit(NULL,&m); advance(250);
    check(!app_state_is_stale(&g_st,g_now) && find_label(ui_screen_root(SCR_REGISTERS),"STALE"),"fresh status does not freshen an older register capture");
    snprintf(name,sizeof name,"%spacket_stale_capture_fixture",prefix); shot(out,name);
    printf("== packet UI fixture: %d passed, %d failed ==\n",g_pass,g_fail);
    return g_fail ? 1 : 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <out_dir> [--portrait]\n", argv[0]);
        return 2;
    }
    const char *out = argv[1];
    bool portrait=false,packet=false;
    for(int i=2;i<argc;i++) { if(strcmp(argv[i],"--portrait")==0) portrait=true; if(strcmp(argv[i],"--packet-fixture")==0) packet=true; }
    g_port.backend_is_mock=!packet; g_port.test_fixture=packet; g_mock_paused=packet;
    W = portrait ? 720 : 1280;
    H = portrait ? 1280 : 720;
    const char *pfx = portrait ? "portrait_" : "";
    char name[64];

    lv_init();
    lv_tick_set_cb(tick_cb);
    lv_display_t *d = lv_display_create(W, H);
    g_fb = calloc((size_t)W * H, 2);
    size_t bsz = (size_t)W * 80 * 2;
    lv_display_set_buffers(d, malloc(bsz), NULL, (uint32_t)bsz, LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(d, flush_cb);
    lv_indev_t *in = lv_indev_create();
    lv_indev_set_type(in, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(in, read_cb);

    app_state_init(&g_st);
    mock_device_init(&g_dev, g_now);
    ui_init(&g_st, &g_port);
    if(packet) return packet_fixture(out,pfx);

    printf("== T1 UI simulator, %d x %d ==\n", W, H);

    /* 1. Boot: connecting, then connected with MOCK data. */
    advance(300);
    check(g_st.hw.link == LINK_CONNECTING, "boot shows CONNECTING first");
    snprintf(name, sizeof name, "%s00_connecting", pfx);
    shot(out, name);
    advance(1500);
    check(g_st.hw.link == LINK_CONNECTED && g_st.hw.have_id, "link CONNECTED with identity after handshake");
    check(g_st.hw.snap.prov == PROV_MOCK, "snapshots are tagged MOCK");
    check(g_st.hw.snap.regs[0] == 0, "x0 reads zero");

    /* 2. Every screen: navigate by touch, check MOCK labelling, no LIVE. */
    check(tap_text("Engineering") && g_st.mode == MODE_ENGINEERING, "tap Engineering switches mode");
    for (int i = 0; i < SCR_COUNT; i++) {
        bool ok = goto_screen(i);
        advance(400);
        lv_obj_t *root = ui_screen_root(i);
        bool badge = visible("MOCK DATA") && visible("MOCK MODE:");
        bool tagged = find_label(root, "MOCK") || find_label(root, "LOCKED") ||
                      find_label(root, "EXPLANATION");
        bool live = any_word(lv_screen_active(), "LIVE");
        check(ok && badge && tagged && !live, "screen %-15s reachable by touch, MOCK badge + banner, own tag, no LIVE",
              g_screens[i].name);
        snprintf(name, sizeof name, "%s%02d_%s", pfx, i + 1, g_screens[i].name);
        for (char *p = name; *p; p++) {
            if (*p == ' ') {
                *p = '_';
            }
        }
        shot(out, name);
    }

    /* Locked screens offer no action buttons. */
    goto_screen(SCR_DIAG);
    check(!find_label(ui_screen_root(SCR_DIAG), "Run") && find_label(ui_screen_root(SCR_DIAG), "T10"),
          "locked Diagnostics screen explains T10 and has no action");

    /* 3. Registers: select a register, switch to decimal. */
    goto_screen(SCR_REGISTERS);
    check(tap_text("x10  a0") && g_st.reg_selected == 10, "tap x10 selects it");
    check(tap_text("Decimal") && g_st.reg_decimal, "tap Decimal switches the register view");
    advance(300);
    check(visible("x10 (a0) = "), "detail line shows x10 in binary");
    snprintf(name, sizeof name, "%s20_registers_selected", pfx);
    shot(out, name);

    /* 4. Mode switch keeps the model, the terminal and the screen state. */
    g_mock_paused = true;
    advance(300); /* drain anything in flight */
    uint32_t h0 = hw_model_hash(&g_st.hw);
    size_t con0 = g_st.hw.console_len;
    uint32_t gen0 = g_dev.snap.generation;
    check(tap_text("Demo") && g_st.mode == MODE_DEMO, "tap Demo switches mode");
    check(g_st.screen == SCR_HOME, "Registers is not in Demo, so the view moves to Home");
    lv_obj_t *nb = nav_button(SCR_REGISTERS);
    check(nb == NULL, "Demo hides engineering screens from the navigation");
    goto_screen(SCR_TERMINAL);
    check(tap_text("Engineering") && g_st.mode == MODE_ENGINEERING, "back to Engineering");
    check(g_st.screen == SCR_TERMINAL, "Terminal is in both modes, so it stays on screen");
    goto_screen(SCR_REGISTERS);
    check(g_st.reg_selected == 10 && g_st.reg_decimal, "register selection and view survive the round trip");
    check(hw_model_hash(&g_st.hw) == h0 && g_st.hw.console_len == con0 && g_dev.snap.generation == gen0,
          "hardware model hash, terminal buffer and backend unchanged by mode switches");
    g_mock_paused = false;

    /* 5. Simulated transfer with touch still working during it. */
    goto_screen(SCR_PROGRAMS);
    check(tap_text("Simulate load"), "tap Simulate load (primes)");
    advance(1200);
    check(g_st.hw.op == OP_TRANSFER && g_st.hw.op_permille > 200 && g_st.hw.op_permille < 800,
          "transfer in progress (%u per mille)", g_st.hw.op_permille);
    snprintf(name, sizeof name, "%s21_transfer", pfx);
    shot(out, name);
    lv_obj_t *l = find_label(ui_screen_root(SCR_PROGRAMS), "Simulate load");
    check(l && lv_obj_has_state(lv_obj_get_parent(l), LV_STATE_DISABLED), "load buttons disabled during a transfer");
    check(goto_screen(SCR_TERMINAL) && goto_screen(SCR_REGISTERS) && goto_screen(SCR_PROGRAMS),
          "navigation responds during the transfer");
    advance(2500);
    check(g_st.hw.op == OP_DONE && g_st.hw.op_permille == 1000, "transfer completes");

    check(tap_text("Simulate failed load"), "tap Simulate failed load");
    advance(2000);
    check(g_st.hw.op == OP_FAILED && g_st.hw.op_permille >= 400 && g_st.hw.op_permille < 600,
          "failed transfer stops near 40%% and says FAILED");
    snprintf(name, sizeof name, "%s22_transfer_failed", pfx);
    shot(out, name);

    /* 6. Unplug during a transfer, stale data, reconnect. */
    check(tap_text("Simulate load"), "start another transfer");
    advance(500);
    goto_screen(SCR_HOME);
    /* A tap reaches the backend within 20 ms; its answer reaches the screen
     * at the next 5 Hz refresh, so allow 250 ms before looking. */
    bool tapped = tap_text("Unplug");
    advance(250);
    check(tapped && g_st.hw.link == LINK_DISCONNECTED, "Unplug drops the simulated link");
    check(g_st.hw.op == OP_FAILED, "unplug fails the transfer in progress");
    uint32_t regs_before[32];
    memcpy(regs_before, g_st.hw.snap.regs, sizeof regs_before);
    advance(2500);
    check(visible("STALE") && visible("MOCK - STALE"), "after unplug the data is kept but marked STALE");
    check(memcmp(regs_before, g_st.hw.snap.regs, sizeof regs_before) == 0, "kept data does not change while unplugged");
    snprintf(name, sizeof name, "%s23_unplugged_stale", pfx);
    shot(out, name);
    goto_screen(SCR_PROGRAMS);
    l = find_label(ui_screen_root(SCR_PROGRAMS), "Simulate load");
    check(l && lv_obj_has_state(lv_obj_get_parent(l), LV_STATE_DISABLED), "load buttons disabled while unplugged");
    goto_screen(SCR_HOME);
    check(tap_text("Reconnect"), "tap Reconnect");
    advance(1500);
    check(g_st.hw.link == LINK_CONNECTED && !app_state_is_stale(&g_st, g_now), "reconnects and data is fresh again");

    tapped = tap_text("Link error");
    advance(250);
    check(tapped && g_st.hw.link == LINK_ERROR && visible("LINK ERROR"), "Link error shows LINK ERROR");
    snprintf(name, sizeof name, "%s24_link_error", pfx);
    shot(out, name);
    advance(3300);
    check(g_st.hw.link == LINK_CONNECTED, "link error retries and recovers");

    /* 7. Queue overflow: a burst bigger than the queue is dropped and counted,
     *    and the UI keeps working. */
    for (int i = 0; i < 100; i++) {
        dev_msg_t m = { .type = MSG_CONSOLE, .t_ms = g_now };
        m.u.console.len = 6;
        memcpy(m.u.console.text, "MOCK!\n", 6);
        emit(NULL, &m);
    }
    check(g_drops > 0, "burst of 100 messages: %u dropped by the bounded queue", (unsigned)g_drops);
    check(goto_screen(SCR_SYSTEM), "navigation still works after the burst");
    advance(400);
    snprintf(name, sizeof name, "%s25_system_after_burst", pfx);
    shot(out, name);

    /* 8. Terminal clear. */
    goto_screen(SCR_TERMINAL);
    g_mock_paused = true;
    advance(1000); /* let the burst drain so only the Clear is measured */
    check(tap_text("Clear") && g_st.hw.console_len == 0, "Clear empties the terminal");
    g_mock_paused = false;
    advance(1500);
    check(g_st.hw.console_len > 0 && strncmp(g_st.hw.console, "MOCK", 4) == 0,
          "new console lines start with MOCK");

    ui_metrics_t m;
    ui_get_metrics(&m);
    printf("info  %u taps measured, %u commands refused, peak queue %u\n", (unsigned)m.touch_samples,
           (unsigned)m.cmd_refused, (unsigned)g_peak);
    printf("== %d passed, %d failed ==\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
