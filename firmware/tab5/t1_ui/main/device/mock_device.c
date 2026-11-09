/* MOCK device backend. See mock_device.h. */
#include "mock_device.h"

#include <stdio.h>
#include <string.h>

const mock_program_t mock_programs[MOCK_PROGRAM_COUNT] = {
    { "primes", "Counts primes below 10,000 and prints them.", 2304 },
    { "life",   "Conway's Game of Life on the VGA framebuffer.", 3072 },
    { "snake",  "Snake game, buttons on the Basys 3.",          3584 },
    { "hello",  "Prints a greeting over the UART console.",     512  },
};

static uint32_t rnd(mock_device_t *d)
{
    d->rng = d->rng * 1664525u + 1013904223u;
    return d->rng >> 8;
}

static void emit_link(mock_device_t *d, link_state_t st, const char *why, uint32_t now,
                      mock_emit_fn emit, void *ctx)
{
    d->link = st;
    d->link_t_ms = now;
    dev_msg_t m = { .type = MSG_LINK, .t_ms = now };
    m.u.link.state = st;
    snprintf(m.u.link.reason, sizeof m.u.link.reason, "%s", why);
    emit(ctx, &m);
}

static void emit_op(mock_device_t *d, uint32_t now, uint16_t permille, const char *detail,
                    mock_emit_fn emit, void *ctx)
{
    dev_msg_t m = { .type = MSG_OP, .t_ms = now };
    m.u.op.state = d->op;
    m.u.op.program = d->op_program;
    m.u.op.permille = permille;
    snprintf(m.u.op.detail, sizeof m.u.op.detail, "%s", detail);
    emit(ctx, &m);
}

static void emit_console(uint32_t now, const char *text, mock_emit_fn emit, void *ctx)
{
    size_t len = strlen(text);
    while (len > 0) {
        dev_msg_t m = { .type = MSG_CONSOLE, .t_ms = now };
        size_t n = len > CONSOLE_CHUNK ? CONSOLE_CHUNK : len;
        memcpy(m.u.console.text, text, n);
        m.u.console.len = (uint8_t)n;
        emit(ctx, &m);
        text += n;
        len -= n;
    }
}

void mock_device_init(mock_device_t *d, uint32_t now_ms)
{
    memset(d, 0, sizeof *d);
    d->rng = 0x5EED1234u;
    d->link = LINK_CONNECTING;
    d->link_t_ms = now_ms;
    d->prime_next = 2;
    d->snap.prov = PROV_MOCK;
    d->snap.regs_valid=true; d->snap.counter_mask=0xff; d->snap.pc_valid=3;
    d->snap.cpu = CPU_RUNNING;
    d->snap.pc = 0x00000100u;
    d->snap.regs[2] = 0x00003FF0u; /* sp near the top of a 16 KiB RAM */
    d->snap.regs[3] = 0x00000800u; /* gp */
}

static void begin_connect(mock_device_t *d, uint32_t now, mock_emit_fn emit, void *ctx)
{
    emit_link(d, LINK_CONNECTING, "MOCK handshake", now, emit, ctx);
}

static void fail_transfer(mock_device_t *d, uint32_t now, const char *why,
                          mock_emit_fn emit, void *ctx)
{
    uint32_t pm = (now - d->op_t0_ms) * 1000u / MOCK_TRANSFER_MS;
    d->op = OP_FAILED;
    emit_op(d, now, (uint16_t)(pm > 1000 ? 1000 : pm), why, emit, ctx);
}

void mock_device_command(mock_device_t *d, const ui_cmd_t *c, uint32_t now,
                         mock_emit_fn emit, void *ctx)
{
    switch (c->type) {
    case CMD_SIM_DISCONNECT:
        if (d->op == OP_TRANSFER) {
            fail_transfer(d, now, "link lost during transfer", emit, ctx);
        }
        emit_link(d, LINK_DISCONNECTED, "simulated cable unplug", now, emit, ctx);
        break;
    case CMD_SIM_RECONNECT:
        if (d->link != LINK_CONNECTED) {
            begin_connect(d, now, emit, ctx);
        }
        break;
    case CMD_SIM_LINK_ERROR:
        if (d->op == OP_TRANSFER) {
            fail_transfer(d, now, "CRC errors during transfer", emit, ctx);
        }
        emit_link(d, LINK_ERROR, "simulated CRC errors, retrying", now, emit, ctx);
        break;
    case CMD_SIM_TRANSFER:
    case CMD_SIM_TRANSFER_FAIL:
        if (c->arg >= MOCK_PROGRAM_COUNT) {
            break;
        }
        if (d->op == OP_TRANSFER) {
            break; /* one operation at a time; the UI disables the button too */
        }
        d->op_program = (uint8_t)c->arg;
        if (d->link != LINK_CONNECTED) {
            d->op = OP_FAILED;
            emit_op(d, now, 0, "link is not connected", emit, ctx);
            break;
        }
        d->op = OP_TRANSFER;
        d->op_will_fail = (c->type == CMD_SIM_TRANSFER_FAIL);
        d->op_t0_ms = now;
        d->next_op_ms = now;
        emit_op(d, now, 0, "simulated transfer started", emit, ctx);
        break;
    default:
        break;
    }
}

static bool is_prime(uint32_t n)
{
    if (n < 2) {
        return false;
    }
    for (uint32_t k = 2; k * k <= n; k++) {
        if (n % k == 0) {
            return false;
        }
    }
    return true;
}

static void advance_cpu(mock_device_t *d)
{
    cpu_snapshot_t *s = &d->snap;
    /* About 1/5 s of a 62.5 MHz core with a CPI near the Phase 5 number. */
    uint32_t cyc = MOCK_CLOCK_HZ / 5u;
    uint32_t cpi_milli = 1250u + rnd(d) % 150u;        /* 1.250 .. 1.399 */
    uint32_t inst = (uint32_t)((uint64_t)cyc * 1000u / cpi_milli);
    s->ctr.cycles  += cyc;
    s->ctr.instret += inst;
    s->ctr.stalls  += (cyc - inst) * 2u / 5u;
    s->ctr.flushes += (cyc - inst) - (cyc - inst) * 2u / 5u;
    s->ctr.loads   += inst / 5u;
    s->ctr.stores  += inst / 9u;
    s->ctr.branches += inst / 6u;
    s->ctr.taken   += inst / 10u;
    s->generation++;

    s->last_pc = s->pc;
    s->pc = 0x00000100u + (rnd(d) % 0x0C0u) * 4u;
    /* Change a few registers each time so the highlight has something to do. */
    int n = 1 + (int)(rnd(d) % 4u);
    for (int i = 0; i < n; i++) {
        int r = 5 + (int)(rnd(d) % 27u);         /* never x0..x4 */
        s->regs[r] = (r >= 10 && r <= 17) ? rnd(d) % 10000u : rnd(d) * 2654435761u;
    }
    s->regs[0] = 0;
}

void mock_device_step(mock_device_t *d, uint32_t now, mock_emit_fn emit, void *ctx)
{
    /* Link state machine. The first step announces the handshake so the
     * screen shows CONNECTING rather than the initial DISCONNECTED. */
    if (!d->announced) {
        d->announced = true;
        if (d->link == LINK_CONNECTING) {
            emit_link(d, LINK_CONNECTING, "MOCK handshake", d->link_t_ms, emit, ctx);
        }
    }
    if (d->link == LINK_CONNECTING && now - d->link_t_ms >= MOCK_CONNECT_MS) {
        dev_msg_t m = { .type = MSG_IDENTITY, .t_ms = now };
        snprintf(m.u.id.board, sizeof m.u.id.board, "Basys 3 (MOCK)");
        snprintf(m.u.id.core, sizeof m.u.id.core, "RV32I 5-stage (MOCK)");
        snprintf(m.u.id.bitstream, sizeof m.u.id.bitstream, "mock-0000");
        m.u.id.clock_hz = MOCK_CLOCK_HZ;
        m.u.id.protocol_version = 0;
        emit(ctx, &m);
        emit_link(d, LINK_CONNECTED, "MOCK backend", now, emit, ctx);
        d->next_snap_ms = now;
        d->next_console_ms = now;
    } else if (d->link == LINK_ERROR && now - d->link_t_ms >= MOCK_RETRY_MS) {
        begin_connect(d, now, emit, ctx);
    }

    if (d->link != LINK_CONNECTED) {
        return;
    }

    /* 5 Hz snapshots. Catch up by at most one per call so a stalled caller
     * does not burst the queue. */
    if ((int32_t)(now - d->next_snap_ms) >= 0) {
        advance_cpu(d);
        dev_msg_t m = { .type = MSG_SNAPSHOT, .t_ms = now };
        m.u.snap = d->snap;
        emit(ctx, &m);
        d->next_snap_ms = now + MOCK_SNAP_MS;
    }

    /* Console: one line per tick, clearly marked MOCK. */
    if ((int32_t)(now - d->next_console_ms) >= 0) {
        char line[64];
        while (!is_prime(d->prime_next)) {
            d->prime_next++;
        }
        snprintf(line, sizeof line, "MOCK> prime %lu\n", (unsigned long)d->prime_next);
        d->prime_next = d->prime_next >= 9973u ? 2u : d->prime_next + 1u;
        emit_console(now, line, emit, ctx);
        d->next_console_ms = now + MOCK_CONSOLE_MS;
    }

    /* Simulated transfer progress at 10 Hz. */
    if (d->op == OP_TRANSFER && (int32_t)(now - d->next_op_ms) >= 0) {
        uint32_t pm = (now - d->op_t0_ms) * 1000u / MOCK_TRANSFER_MS;
        if (d->op_will_fail && pm >= 400u) {
            fail_transfer(d, now, "simulated timeout at chunk 5", emit, ctx);
        } else if (pm >= 1000u) {
            d->op = OP_DONE;
            emit_op(d, now, 1000, "simulated CRC match", emit, ctx);
        } else {
            emit_op(d, now, (uint16_t)pm, "sending chunks (MOCK)", emit, ctx);
        }
        d->next_op_ms = now + 100u;
    }
}
