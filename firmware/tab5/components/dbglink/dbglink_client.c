/* Debug link protocol version 1: non-blocking client. See include/dbglink.h. */
#include "dbglink.h"

#include <string.h>

void dbl_client_init(dbl_client_t *c)
{
    memset(c, 0, sizeof *c);
    c->timeout_ms = DBL_RESPONSE_TIMEOUT_MS;
    c->max_retries = DBL_MAX_RETRIES;
}

void dbl_client_set_session(dbl_client_t *c, uint64_t session_id)
{
    c->session_id = session_id;
    c->last_id = 0;
}

static dbl_client_result_t send_new(dbl_client_t *c, uint8_t channel, uint16_t opcode,
                                    uint32_t request_id, uint64_t session_id,
                                    const void *payload, uint16_t len, uint32_t now_ms)
{
    dbl_frame_t f;
    if (c->busy) return DBL_CLIENT_ERR_BUSY;
    if (dbl_frame_set(&f, channel, DBL_KIND_REQUEST, opcode, 0, request_id, session_id,
                      payload, len) != 0)
        return DBL_CLIENT_ERR_ARG;
    c->wire_len = dbl_wire_encode(&f, c->wire);
    c->channel = channel;
    c->opcode = opcode;
    c->request_id = request_id;
    c->sent_ms = now_ms;
    c->attempts = 1;
    c->busy = true;
    c->sent++;
    return DBL_CLIENT_WAITING;
}

dbl_client_result_t dbl_client_discover(dbl_client_t *c, uint32_t now_ms)
{
    if (c->busy) return DBL_CLIENT_ERR_BUSY;
    /* Discovery is outside the session: it does not consume a request ID. */
    uint64_t saved = c->session_id;
    dbl_client_result_t r = send_new(c, DBL_CH_CONTROL, DBL_OP_HELLO, 0, 0, NULL, 0, now_ms);
    c->session_id = saved;
    return r;
}

dbl_client_result_t dbl_client_start(dbl_client_t *c, uint8_t channel, uint16_t opcode,
                                     const void *payload, uint16_t len, uint32_t now_ms)
{
    if (c->busy) return DBL_CLIENT_ERR_BUSY;
    if (c->session_id == 0 || c->last_id == UINT32_MAX) return DBL_CLIENT_ERR_NO_SESSION;
    if (len > DBL_MAX_PAYLOAD) return DBL_CLIENT_ERR_ARG;
    dbl_client_result_t r = send_new(c, channel, opcode, c->last_id + 1, c->session_id,
                                     payload, len, now_ms);
    if (r == DBL_CLIENT_WAITING) c->last_id++;
    return r;
}

dbl_client_result_t dbl_client_on_frame(dbl_client_t *c, const dbl_frame_t *f)
{
    uint64_t want_session = c->request_id ? c->session_id : 0;
    if (!c->busy || f->kind != DBL_KIND_RESPONSE || f->request_id != c->request_id ||
        f->session_id != want_session || f->opcode != c->opcode || f->channel != c->channel) {
        c->stale++;
        return DBL_CLIENT_STALE;
    }
    c->busy = false;
    if (f->status == DBL_ST_BAD_SESSION && c->request_id != 0) dbl_client_set_session(c, 0);
    return DBL_CLIENT_MATCH;
}

dbl_client_result_t dbl_client_tick(dbl_client_t *c, uint32_t now_ms)
{
    if (!c->busy) return DBL_CLIENT_IDLE;
    if ((uint32_t)(now_ms - c->sent_ms) < c->timeout_ms) return DBL_CLIENT_WAITING;
    if (c->attempts > c->max_retries) {
        c->busy = false;
        c->lost++;
        return DBL_CLIENT_OUTCOME_UNKNOWN;
    }
    c->attempts++;
    c->retries++;
    c->sent++;
    c->sent_ms = now_ms;
    return DBL_CLIENT_RESEND;
}
