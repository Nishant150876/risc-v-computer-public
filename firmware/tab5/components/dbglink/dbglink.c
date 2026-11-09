/* Debug link protocol version 1: codec and stream receiver. See include/dbglink.h. */
#include "dbglink.h"

#include <string.h>

/* Nibble-at-a-time CRC-32/ISO-HDLC (reflected 0xEDB88320): 64-byte table. */
static const uint32_t crc_nibble[16] = {
    0x00000000u, 0x1DB71064u, 0x3B6E20C8u, 0x26D930ACu, 0x76DC4190u, 0x6B6B51F4u,
    0x4DB26158u, 0x5005713Cu, 0xEDB88320u, 0xF00F9344u, 0xD6D6A3E8u, 0xCB61B38Cu,
    0x9B64C2B0u, 0x86D3D2D4u, 0xA00AE278u, 0xBDBDF21Cu,
};

uint32_t dbl_crc32(uint32_t crc, const uint8_t *data, size_t n)
{
    crc = ~crc;
    for (size_t i = 0; i < n; i++) {
        crc ^= data[i];
        crc = (crc >> 4) ^ crc_nibble[crc & 0x0Fu];
        crc = (crc >> 4) ^ crc_nibble[crc & 0x0Fu];
    }
    return ~crc;
}

size_t dbl_cobs_encode(const uint8_t *in, size_t n, uint8_t *out)
{
    size_t w = 1, code_at = 0;
    uint8_t code = 1;
    for (size_t i = 0; i < n; i++) {
        if (in[i] != 0) {
            out[w++] = in[i];
            code++;
            if (code != 0xFFu) continue;
            out[code_at] = code;
            if (i + 1 == n) return w;      /* full block ends the input: no empty group */
        } else {
            out[code_at] = code;
        }
        code_at = w++;
        code = 1;
    }
    out[code_at] = code;
    return w;
}

int dbl_cobs_decode(const uint8_t *in, size_t n, uint8_t *out, size_t cap)
{
    size_t r = 0, w = 0;
    while (r < n) {
        uint8_t code = in[r++];
        if (code == 0 || (size_t)(code - 1) > n - r) return -1;
        for (uint8_t k = 1; k < code; k++) {
            if (in[r] == 0 || w == cap) return -1;
            out[w++] = in[r++];
        }
        if (code != 0xFFu && r < n) {
            if (w == cap) return -1;
            out[w++] = 0;
        }
    }
    return (int)w;
}

static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) { put16(p, (uint16_t)v); put16(p + 2, (uint16_t)(v >> 16)); }
static uint16_t get16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t get32(const uint8_t *p) { return get16(p) | ((uint32_t)get16(p + 2) << 16); }

int dbl_frame_set(dbl_frame_t *f, uint8_t channel, uint8_t kind, uint16_t opcode,
                  uint16_t status, uint32_t request_id, uint64_t session_id,
                  const void *payload, uint16_t len)
{
    if (len > DBL_MAX_PAYLOAD || (len && !payload)) return -1;
    f->version = DBL_PROTOCOL_VERSION;
    f->channel = channel;
    f->kind = kind;
    f->flags = 0;
    f->opcode = opcode;
    f->status = status;
    f->request_id = request_id;
    f->session_id = session_id;
    f->length = len;
    f->reserved = 0;
    if (len) memcpy(f->payload, payload, len);
    return 0;
}

size_t dbl_frame_encode(const dbl_frame_t *f, uint8_t *raw)
{
    if (f->length > DBL_MAX_PAYLOAD) return 0;
    raw[0] = f->version;
    raw[1] = f->channel;
    raw[2] = f->kind;
    raw[3] = f->flags;
    put16(raw + 4, f->opcode);
    put16(raw + 6, f->status);
    put32(raw + 8, f->request_id);
    put32(raw + 12, (uint32_t)f->session_id);
    put32(raw + 16, (uint32_t)(f->session_id >> 32));
    put16(raw + 20, f->length);
    put16(raw + 22, f->reserved);
    memcpy(raw + DBL_HEADER_BYTES, f->payload, f->length);
    size_t n = DBL_HEADER_BYTES + f->length;
    put32(raw + n, dbl_crc32(0, raw, n));
    return n + DBL_CRC_BYTES;
}

size_t dbl_wire_encode(const dbl_frame_t *f, uint8_t *wire)
{
    uint8_t raw[DBL_MAX_FRAME];
    size_t n = dbl_frame_encode(f, raw);
    if (n == 0) return 0;
    size_t w = dbl_cobs_encode(raw, n, wire);
    wire[w++] = 0;
    return w;
}

int dbl_frame_parse(const uint8_t *raw, size_t n, dbl_frame_t *f)
{
    if (n > DBL_MAX_FRAME) return DBL_ERR_TOO_LONG;
    if (n < DBL_HEADER_BYTES + DBL_CRC_BYTES) return DBL_ERR_TOO_SHORT;
    uint16_t len = get16(raw + 20);
    if (len > DBL_MAX_PAYLOAD || (size_t)DBL_HEADER_BYTES + len + DBL_CRC_BYTES != n)
        return DBL_ERR_BAD_LENGTH;
    if (dbl_crc32(0, raw, n - DBL_CRC_BYTES) != get32(raw + n - DBL_CRC_BYTES))
        return DBL_ERR_BAD_CRC;
    if (raw[0] != DBL_PROTOCOL_VERSION) return DBL_ERR_BAD_VERSION;
    if (raw[3] != 0 || get16(raw + 22) != 0) return DBL_ERR_BAD_RESERVED;
    if (raw[1] > DBL_CH_EVENT) return DBL_ERR_BAD_CHANNEL;
    if (raw[2] > DBL_KIND_EVENT) return DBL_ERR_BAD_KIND;
    f->version = raw[0];
    f->channel = raw[1];
    f->kind = raw[2];
    f->flags = 0;
    f->opcode = get16(raw + 4);
    f->status = get16(raw + 6);
    f->request_id = get32(raw + 8);
    f->session_id = get32(raw + 12) | ((uint64_t)get32(raw + 16) << 32);
    f->length = len;
    f->reserved = 0;
    memcpy(f->payload, raw + DBL_HEADER_BYTES, len);
    return DBL_ERR_OK;
}

int dbl_wire_decode(const uint8_t *enc, size_t n, dbl_frame_t *f)
{
    uint8_t raw[DBL_MAX_FRAME + 1];
    if (n > DBL_MAX_ENCODED) return DBL_ERR_TOO_LONG;
    int len = dbl_cobs_decode(enc, n, raw, sizeof raw);
    if (len < 0) return DBL_ERR_COBS_INVALID;
    return dbl_frame_parse(raw, (size_t)len, f);
}

/* ---- stream receiver ---- */

static void rx_clear(dbl_rx_t *rx)
{
    rx->raw_len = rx->enc_len = 0;
    rx->block_left = rx->block_code = 0;
    rx->enc_overflow = rx->raw_overflow = false;
}

void dbl_rx_init(dbl_rx_t *rx, uint32_t timeout_ms)
{
    memset(rx, 0, sizeof *rx);
    rx->timeout_ms = timeout_ms;
}

static bool rx_partial(const dbl_rx_t *rx) { return rx->enc_len != 0 || rx->enc_overflow; }

static int rx_fail(dbl_rx_t *rx, int code, int *err)
{
    rx->counts[code]++;
    *err = code;
    rx_clear(rx);
    return DBL_RX_ERROR;
}

static void rx_out(dbl_rx_t *rx, uint8_t v)
{
    if (rx->raw_len == DBL_MAX_FRAME) rx->raw_overflow = true;
    else rx->raw[rx->raw_len++] = v;
}

int dbl_rx_poll(dbl_rx_t *rx, uint32_t now_ms, int *err)
{
    if (rx->have_time && rx_partial(rx) && (uint32_t)(now_ms - rx->last_ms) > rx->timeout_ms)
        return rx_fail(rx, DBL_ERR_TIMEOUT, err);
    return DBL_RX_NONE;
}

int dbl_rx_byte(dbl_rx_t *rx, uint8_t b, uint32_t now_ms, dbl_frame_t *frame, int *err)
{
    int timed_out = dbl_rx_poll(rx, now_ms, err);
    rx->last_ms = now_ms;
    rx->have_time = true;
    if (timed_out) {
        if (b != 0) {   /* the byte starts the next frame */
            rx->enc_len = 1;
            rx->block_code = b;
            rx->block_left = (uint8_t)(b - 1);
        }
        return timed_out;
    }

    if (b == 0) {
        if (!rx_partial(rx)) return DBL_RX_NONE;           /* idle fill */
        if (rx->enc_overflow) return rx_fail(rx, DBL_ERR_TOO_LONG, err);
        if (rx->block_left) return rx_fail(rx, DBL_ERR_COBS_INVALID, err);
        if (rx->raw_overflow) return rx_fail(rx, DBL_ERR_TOO_LONG, err);
        int code = dbl_frame_parse(rx->raw, rx->raw_len, frame);
        if (code != DBL_ERR_OK) return rx_fail(rx, code, err);
        rx->counts[DBL_ERR_OK]++;
        rx_clear(rx);
        return DBL_RX_FRAME;
    }

    if (rx->enc_overflow) return DBL_RX_NONE;
    if (rx->enc_len == DBL_MAX_ENCODED) {
        rx->enc_overflow = true;
        return DBL_RX_NONE;
    }
    rx->enc_len++;
    if (rx->block_left) {
        rx_out(rx, b);
        rx->block_left--;
    } else {
        /* A new code byte: the previous block (if any, and not 0xFF) ended with a zero. */
        if (rx->block_code != 0 && rx->block_code != 0xFFu) rx_out(rx, 0);
        rx->block_code = b;
        rx->block_left = (uint8_t)(b - 1);
    }
    return DBL_RX_NONE;
}
