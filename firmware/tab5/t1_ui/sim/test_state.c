/*
 * Unit tests for state/app_state.c and device/mock_device.c. No LVGL.
 * Exit status 0 only when every check passes.
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "device/mock_device.h"
#include "state/app_state.h"

static int g_pass, g_fail;

static void check(bool ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s  ", ok ? "PASS" : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    ok ? g_pass++ : g_fail++;
}

/* Collect emitted messages straight into a model. */
static app_state_t g_st;
static int g_n_msgs;
static dev_msg_t g_last;

static void into_state(void *ctx, const dev_msg_t *m)
{
    (void)ctx;
    app_state_apply(&g_st, m);
    g_last = *m;
    g_n_msgs++;
}

static void run(mock_device_t *d, uint32_t *now, uint32_t ms)
{
    for (uint32_t t = 0; t < ms; t += 20) {
        *now += 20;
        mock_device_step(d, *now, into_state, NULL);
    }
}

static void console(app_state_t *s, const char *text)
{
    dev_msg_t m = { .type = MSG_CONSOLE };
    size_t n = strlen(text);
    m.u.console.len = (uint8_t)n;
    memcpy(m.u.console.text, text, n);
    app_state_apply(s, &m);
}

int main(void)
{
    printf("== T1 state and MOCK backend tests ==\n");

    /* ---- model ---- */
    app_state_t s;
    app_state_init(&s);
    check(s.hw.link == LINK_DISCONNECTED && s.mode == MODE_DEMO, "init: disconnected, Demo mode");
    check(app_state_data_age(&s, 1000) == UINT32_MAX && !app_state_is_stale(&s, 1000),
          "init: no data is 'no data', not 'stale'");

    dev_msg_t m = { .type = MSG_SNAPSHOT, .t_ms = 100 };
    m.u.snap.prov = PROV_MOCK;
    m.u.snap.regs_valid=true; m.u.snap.counter_mask=0xff; m.u.snap.pc_valid=3;
    m.u.snap.regs[0] = 0xDEADBEEF;
    m.u.snap.regs[5] = 7;
    m.u.snap.ctr.cycles = 1317;
    m.u.snap.ctr.instret = 1000;
    app_state_apply(&s, &m);
    check(s.hw.snap.regs[0] == 0, "x0 forced to zero even if a backend sends junk");
    check(counters_cpi_milli(&s.hw.snap.ctr) == 1317, "CPI 1317/1000 = 1.317");
    check(s.hw.changed_regs == 0, "first snapshot marks nothing as changed");

    m.t_ms = 300;
    m.u.snap.regs[5] = 8;
    m.u.snap.regs[6] = 1;
    m.u.snap.ctr.cycles = 2617;
    m.u.snap.ctr.instret = 2000;
    app_state_apply(&s, &m);
    check(s.hw.changed_regs == ((1u << 5) | (1u << 6)), "changed mask = x5, x6");
    check(s.hw.cpi_count == 1 && s.hw.cpi_hist[0] == 1300, "interval CPI 1300/1000 = 1.300");

    m.u.snap.ctr.cycles = 10; /* counters went backwards: CPU reset */
    m.u.snap.ctr.instret = 10;
    app_state_apply(&s, &m);
    check(s.hw.cpi_count == 0, "counter reset restarts the CPI history");

    s.hw.link = LINK_CONNECTED;
    check(!app_state_is_stale(&s, 300 + STALE_AFTER_MS), "fresh at exactly the stale limit");
    check(app_state_is_stale(&s, 301 + STALE_AFTER_MS), "stale just past the limit");
    s.hw.link = LINK_DISCONNECTED;
    check(app_state_is_stale(&s, 310), "stale as soon as the link is down");

    /* mode/view changes never touch the hardware model */
    uint32_t h = hw_model_hash(&s.hw);
    s.mode = MODE_ENGINEERING;
    s.screen = 3;
    s.reg_decimal = true;
    s.reg_selected = 4;
    check(hw_model_hash(&s.hw) == h, "view-state changes leave the model hash unchanged");
    console(&s, "x");
    check(hw_model_hash(&s.hw) != h, "model hash does change with real model changes");

    /* console ring: bounded, drops whole oldest lines */
    app_state_init(&s);
    char line[CONSOLE_CHUNK + 1];
    int lines = 0;
    for (int i = 0; i < 400; i++) {
        snprintf(line, sizeof line, "MOCK line %04d\n", i); /* 15 bytes */
        console(&s, line);
        lines++;
    }
    check(s.hw.console_len <= CONSOLE_BYTES, "console stays within %d bytes (%u)", CONSOLE_BYTES,
          (unsigned)s.hw.console_len);
    check(s.hw.console_dropped == 400u * 15u - s.hw.console_len, "dropped count is exact (%u)",
          (unsigned)s.hw.console_dropped);
    check(strncmp(s.hw.console, "MOCK line ", 10) == 0, "buffer starts on a whole line");
    check(strstr(s.hw.console, "MOCK line 0399\n") != NULL, "newest line kept");
    check(strlen(s.hw.console) == s.hw.console_len, "buffer is NUL-terminated at its length");

    /* unknown message type ignored */
    uint32_t applied = s.hw.msgs_applied;
    dev_msg_t bad = { .type = (dev_msg_type_t)99 };
    app_state_apply(&s, &bad);
    check(s.hw.msgs_applied == applied, "unknown message ignored");

    /* oversized console length is clamped */
    dev_msg_t big = { .type = MSG_CONSOLE };
    memset(big.u.console.text, 'A', CONSOLE_CHUNK);
    big.u.console.len = 255;
    size_t before = s.hw.console_len + s.hw.console_dropped;
    app_state_apply(&s, &big);
    check(s.hw.console_len + s.hw.console_dropped == before + CONSOLE_CHUNK, "console length clamped to chunk size");

    /* ---- MOCK backend ---- */
    app_state_init(&g_st);
    mock_device_t d;
    uint32_t now = 0;
    mock_device_init(&d, now);
    run(&d, &now, 700);
    check(g_st.hw.link != LINK_CONNECTED, "not connected before the handshake time");
    run(&d, &now, 200);
    check(g_st.hw.link == LINK_CONNECTED && g_st.hw.have_id, "connected with identity after ~0.8 s");
    check(strstr(g_st.hw.id.board, "MOCK") != NULL, "identity says MOCK");
    run(&d, &now, 2000);
    check(g_st.hw.snap.prov == PROV_MOCK && g_st.hw.snap.generation >= 9 && g_st.hw.snap.generation <= 11,
          "about 5 snapshots per second (%u in 2 s)", (unsigned)g_st.hw.snap.generation);
    check(strncmp(g_st.hw.console, "MOCK> prime 2\nMOCK> prime 3\n", 28) == 0, "console lines say MOCK");

    ui_cmd_t c = { .type = CMD_SIM_TRANSFER, .arg = 0 };
    mock_device_command(&d, &c, now, into_state, NULL);
    check(g_st.hw.op == OP_TRANSFER, "transfer starts");
    mock_device_command(&d, &c, now, into_state, NULL);
    check(g_st.hw.op == OP_TRANSFER && g_last.type == MSG_OP && g_last.u.op.permille == 0,
          "second transfer while busy is ignored");
    run(&d, &now, MOCK_TRANSFER_MS + 200);
    check(g_st.hw.op == OP_DONE && g_st.hw.op_permille == 1000, "transfer completes");

    c.type = CMD_SIM_TRANSFER_FAIL;
    mock_device_command(&d, &c, now, into_state, NULL);
    run(&d, &now, 2000);
    check(g_st.hw.op == OP_FAILED && g_st.hw.op_permille >= 400, "failing transfer fails at 40%%");

    c.type = CMD_SIM_TRANSFER;
    c.arg = 99;
    op_state_t before_op = g_st.hw.op;
    mock_device_command(&d, &c, now, into_state, NULL);
    check(g_st.hw.op == before_op, "out-of-range program index ignored");

    c.arg = 1;
    mock_device_command(&d, &c, now, into_state, NULL);
    run(&d, &now, 500);
    c.type = CMD_SIM_DISCONNECT;
    mock_device_command(&d, &c, now, into_state, NULL);
    check(g_st.hw.link == LINK_DISCONNECTED && g_st.hw.op == OP_FAILED, "unplug fails the transfer");
    uint32_t gen = g_st.hw.snap.generation;
    run(&d, &now, 3000);
    check(g_st.hw.snap.generation == gen, "no snapshots while unplugged");

    c.type = CMD_SIM_TRANSFER;
    mock_device_command(&d, &c, now, into_state, NULL);
    check(g_st.hw.op == OP_FAILED && strstr(g_st.hw.op_detail, "not connected"), "transfer refused while unplugged");

    c.type = CMD_SIM_RECONNECT;
    mock_device_command(&d, &c, now, into_state, NULL);
    run(&d, &now, 1000);
    check(g_st.hw.link == LINK_CONNECTED && g_st.hw.snap.generation > gen, "reconnect resumes snapshots");

    c.type = CMD_SIM_LINK_ERROR;
    mock_device_command(&d, &c, now, into_state, NULL);
    check(g_st.hw.link == LINK_ERROR, "link error state");
    run(&d, &now, MOCK_RETRY_MS + MOCK_CONNECT_MS + 100);
    check(g_st.hw.link == LINK_CONNECTED, "link error retries and reconnects");

    /* x0..x4 are never touched by the mock */
    check(g_st.hw.snap.regs[0] == 0 && g_st.hw.snap.regs[2] == 0x00003FF0u, "x0 zero, sp kept");

    printf("== %d passed, %d failed ==\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
