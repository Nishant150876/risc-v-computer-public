/* Application model. See app_state.h. */
#include "app_state.h"

#include <string.h>

void app_state_init(app_state_t *s)
{
    memset(s, 0, sizeof *s);
    s->hw.link = LINK_DISCONNECTED;
    strcpy(s->hw.link_reason, "not started");
    s->mode = MODE_DEMO;
    s->screen = 0;
    s->reg_selected = -1;
}

static void copy_str(char *dst, size_t cap, const char *src)
{
    size_t n = strnlen(src, cap - 1);
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static void console_append(hw_model_t *hw, const char *text, size_t len)
{
    if (len > CONSOLE_BYTES) {
        hw->console_dropped += (uint32_t)(len - CONSOLE_BYTES);
        text += len - CONSOLE_BYTES;
        len = CONSOLE_BYTES;
    }
    if (hw->console_len + len > CONSOLE_BYTES) {
        /* Drop whole oldest lines so the view never starts mid-line. */
        size_t need = hw->console_len + len - CONSOLE_BYTES;
        const char *nl = memchr(hw->console + need, '\n', hw->console_len - need);
        size_t cut = nl ? (size_t)(nl - hw->console) + 1 : hw->console_len;
        memmove(hw->console, hw->console + cut, hw->console_len - cut);
        hw->console_len -= cut;
        hw->console_dropped += (uint32_t)cut;
    }
    memcpy(hw->console + hw->console_len, text, len);
    hw->console_len += len;
    hw->console[hw->console_len] = '\0';
    hw->console_gen++;
}

uint32_t counters_cpi_milli(const counters_t *c)
{
    if (c->instret == 0) {
        return 0;
    }
    return (uint32_t)((c->cycles * 1000u + c->instret / 2) / c->instret);
}

static void apply_snapshot(hw_model_t *hw, const cpu_snapshot_t *sn, uint32_t t_ms)
{
    uint32_t changed = 0;
    if (hw->snap.prov != PROV_NONE) {
        for (int i = 0; i < 32; i++) {
            if (sn->regs_valid && hw->snap.regs_valid && hw->snap.regs[i] != sn->regs[i]) {
                changed |= 1u << i;
            }
        }
    }
    /* Interval CPI from the counter deltas. A counter that moves backwards
     * means the CPU was reset; restart the history instead of plotting junk. */
    if ((sn->counter_mask & 3u) != 3u) {
        hw->cpi_count = 0;
    } else if (sn->ctr.cycles < hw->prev_ctr.cycles || sn->ctr.instret < hw->prev_ctr.instret || sn->cpu_epoch != hw->snap.cpu_epoch) {
        hw->cpi_count = 0;
    } else if (hw->snap.prov != PROV_NONE && (hw->snap.counter_mask & 3u) == 3u) {
        counters_t d = {
            .cycles  = sn->ctr.cycles - hw->prev_ctr.cycles,
            .instret = sn->ctr.instret - hw->prev_ctr.instret,
        };
        if (d.instret > 0) {
            uint32_t cpi = counters_cpi_milli(&d);
            if (cpi > 65535u) {
                cpi = 65535u;
            }
            if (hw->cpi_count < CPI_HISTORY) {
                hw->cpi_hist[hw->cpi_count++] = (uint16_t)cpi;
            } else {
                memmove(hw->cpi_hist, hw->cpi_hist + 1, (CPI_HISTORY - 1) * sizeof hw->cpi_hist[0]);
                hw->cpi_hist[CPI_HISTORY - 1] = (uint16_t)cpi;
            }
        }
    }
    hw->prev_ctr = sn->ctr;
    hw->snap = *sn;
    hw->snap.regs[0] = 0; /* x0 is always zero, whatever a backend says */
    hw->changed_regs = changed & ~1u;
    hw->snap_t_ms = t_ms;
}

void app_state_apply(app_state_t *s, const dev_msg_t *m)
{
    hw_model_t *hw = &s->hw;
    switch (m->type) {
    case MSG_LINK:
        if (hw->link != m->u.link.state) {
            hw->link_changes++;
        }
        hw->link = m->u.link.state;
        copy_str(hw->link_reason, sizeof hw->link_reason, m->u.link.reason);
        break;
    case MSG_IDENTITY:
        hw->id = m->u.id;
        hw->id.board[sizeof hw->id.board - 1] = '\0';
        hw->id.core[sizeof hw->id.core - 1] = '\0';
        hw->id.bitstream[sizeof hw->id.bitstream - 1] = '\0';
        hw->have_id = true;
        break;
    case MSG_SNAPSHOT:
        apply_snapshot(hw, &m->u.snap, m->t_ms);
        break;
    case MSG_CONSOLE: {
        size_t n = m->u.console.len;
        if (n > CONSOLE_CHUNK) {
            n = CONSOLE_CHUNK;
        }
        console_append(hw, m->u.console.text, n);
        break;
    }
    case MSG_OP:
        hw->op = m->u.op.state;
        hw->op_program = m->u.op.program;
        hw->op_permille = m->u.op.permille > 1000 ? 1000 : m->u.op.permille;
        copy_str(hw->op_detail, sizeof hw->op_detail, m->u.op.detail);
        break;
    default:
        return; /* unknown message: ignore, do not count */
    }
    hw->msgs_applied++;
}

uint32_t app_state_data_age(const app_state_t *s, uint32_t now_ms)
{
    if (s->hw.snap.prov == PROV_NONE) {
        return UINT32_MAX;
    }
    return now_ms - s->hw.snap_t_ms;
}

bool app_state_is_stale(const app_state_t *s, uint32_t now_ms)
{
    if (s->hw.snap.prov == PROV_NONE) {
        return false; /* nothing to be stale */
    }
    return s->hw.link != LINK_CONNECTED || app_state_data_age(s, now_ms) > STALE_AFTER_MS;
}

void app_state_console_clear(app_state_t *s)
{
    s->hw.console_len = 0;
    s->hw.console[0] = '\0';
    s->hw.console_gen++;
}

/* FNV-1a over the fields one at a time (not raw struct bytes, so padding
 * never affects the result). */
static uint32_t fnv(uint32_t h, const void *p, size_t n)
{
    const uint8_t *b = p;
    while (n--) {
        h ^= *b++;
        h *= 16777619u;
    }
    return h;
}
#define FNV(h, x) ((h) = fnv((h), &(x), sizeof(x)))

uint32_t hw_model_hash(const hw_model_t *hw)
{
    uint32_t h = 2166136261u;
    FNV(h, hw->link);
    h = fnv(h, hw->link_reason, strlen(hw->link_reason));
    FNV(h, hw->link_changes);
    h = fnv(h, hw->id.board, strlen(hw->id.board));
    h = fnv(h, hw->id.core, strlen(hw->id.core));
    h = fnv(h, hw->id.bitstream, strlen(hw->id.bitstream));
    FNV(h, hw->id.clock_hz);
    FNV(h, hw->id.capabilities);
    FNV(h, hw->id.can_halt); FNV(h, hw->id.can_step);
    FNV(h, hw->have_id);
    FNV(h, hw->snap.prov);
    FNV(h, hw->snap.generation);
    FNV(h, hw->snap.pc);
    FNV(h, hw->snap.last_pc);
    h = fnv(h, hw->snap.regs, sizeof hw->snap.regs);
    FNV(h, hw->snap.cpu);
    FNV(h, hw->snap.ctr.cycles);
    FNV(h, hw->snap.ctr.instret);
    FNV(h, hw->snap.ctr.stalls);
    FNV(h, hw->snap.ctr.flushes);
    FNV(h, hw->snap.ctr.loads);
    FNV(h, hw->snap.ctr.stores);
    FNV(h, hw->snap.ctr.branches);
    FNV(h, hw->snap.ctr.taken);
    FNV(h, hw->snap.ctr.jumps);
    FNV(h, hw->snap.pc_valid); FNV(h, hw->snap.regs_valid); FNV(h, hw->snap.counter_mask);
    FNV(h, hw->snap.regs_generation); FNV(h, hw->snap.counter_generation);
    FNV(h, hw->snap.regs_t_ms); FNV(h, hw->snap.counter_t_ms); FNV(h, hw->snap.cpu_epoch);
    FNV(h, hw->snap.image_valid); FNV(h, hw->snap.operation_state);
    FNV(h, hw->snap_t_ms);
    FNV(h, hw->changed_regs);
    FNV(h, hw->op);
    FNV(h, hw->op_program);
    FNV(h, hw->op_permille);
    h = fnv(h, hw->console, hw->console_len);
    FNV(h, hw->console_dropped);
    h = fnv(h, hw->cpi_hist, hw->cpi_count * sizeof hw->cpi_hist[0]);
    FNV(h, hw->msgs_applied);
    return h;
}

const char *prov_name(provenance_t p)
{
    switch (p) {
    case PROV_MOCK:       return "MOCK";
    case PROV_LIVE:       return "LIVE";
    case PROV_CAPTURED:   return "CAPTURED";
    case PROV_HISTORICAL: return "HISTORICAL";
    default:              return "NO DATA";
    }
}

const char *link_name(link_state_t l)
{
    switch (l) {
    case LINK_CONNECTING: return "CONNECTING";
    case LINK_CONNECTED:  return "CONNECTED";
    case LINK_ERROR:      return "LINK ERROR";
    default:              return "DISCONNECTED";
    }
}

const char *cpu_name(cpu_state_t c)
{
    switch (c) {
    case CPU_RESET_HELD: return "RESET HELD";
    case CPU_RUNNING:    return "RUNNING";
    case CPU_HALTED:     return "HALTED";
    case CPU_STEPPING:   return "STEPPING";
    case CPU_BREAKPOINT: return "BREAKPOINT";
    case CPU_TERMINATED: return "TERMINATED";
    case CPU_ERROR:      return "CPU ERROR";
    default:             return "UNKNOWN";
    }
}

const char *op_name(op_state_t o)
{
    switch (o) {
    case OP_TRANSFER: return "TRANSFER";
    case OP_DONE:     return "DONE";
    case OP_FAILED:   return "FAILED";
    default:          return "IDLE";
    }
}

const char *reg_abi_name(int i)
{
    static const char *const abi[32] = {
        "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
        "s0",   "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6",   "a7", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8",   "s9", "s10", "s11", "t3", "t4", "t5", "t6",
    };
    return (i >= 0 && i < 32) ? abi[i] : "?";
}
