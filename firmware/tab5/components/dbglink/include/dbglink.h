/*
 * Debug link protocol version 1: frame codec, bounded stream receiver and a non-blocking
 * client with safe identical retries. Plain C99 with no allocation and no I/O, so the same
 * files build in ESP-IDF and in the host tests.
 *
 * Wire format: COBS(header || payload || crc32) || 0x00. See docs/tab5/DEBUG_PROTOCOL.md.
 */
#ifndef DBGLINK_H
#define DBGLINK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "dbglink_schema.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t version, channel, kind, flags;
    uint16_t opcode, status;
    uint32_t request_id;
    uint64_t session_id;
    uint16_t length, reserved;
    uint8_t payload[DBL_MAX_PAYLOAD];
} dbl_frame_t;

/* CRC-32/ISO-HDLC; pass 0 to start. dbl_crc32(0, "123456789", 9) == 0xCBF43926. */
uint32_t dbl_crc32(uint32_t crc, const uint8_t *data, size_t n);

/* COBS without the delimiter. out must hold n + n/254 + 1 bytes. Returns bytes written. */
size_t dbl_cobs_encode(const uint8_t *in, size_t n, uint8_t *out);
/* Returns decoded length, or -1 for invalid COBS or more than cap output bytes. */
int dbl_cobs_decode(const uint8_t *in, size_t n, uint8_t *out, size_t cap);

/* Fill a frame header for version 1; copies len payload bytes (len <= DBL_MAX_PAYLOAD). */
int dbl_frame_set(dbl_frame_t *f, uint8_t channel, uint8_t kind, uint16_t opcode,
                  uint16_t status, uint32_t request_id, uint64_t session_id,
                  const void *payload, uint16_t len);
/* header || payload || crc into raw[DBL_MAX_FRAME]. Returns length, 0 if length > 256. */
size_t dbl_frame_encode(const dbl_frame_t *f, uint8_t *raw);
/* COBS frame plus delimiter into wire[DBL_MAX_WIRE]. Returns length, 0 on error. */
size_t dbl_wire_encode(const dbl_frame_t *f, uint8_t *wire);
/* Checks a decoded frame in the fixed order; returns DBL_ERR_OK or the first failure. */
int dbl_frame_parse(const uint8_t *raw, size_t n, dbl_frame_t *f);
/* One encoded frame without its delimiter. */
int dbl_wire_decode(const uint8_t *enc, size_t n, dbl_frame_t *f);

/* Bounded receiver that decodes COBS as bytes arrive (at most one event per byte). */
typedef struct {
    uint8_t raw[DBL_MAX_FRAME];
    uint16_t raw_len;     /* decoded bytes so far */
    uint16_t enc_len;     /* encoded bytes so far */
    uint8_t block_left;   /* data bytes left in the current COBS block */
    uint8_t block_code;   /* code byte of the current block, 0 before the first one */
    bool enc_overflow, raw_overflow;
    uint32_t last_ms;
    bool have_time;
    uint32_t timeout_ms;
    uint32_t counts[DBL_FRAME_ERROR_COUNT]; /* counts[DBL_ERR_OK] = good frames */
} dbl_rx_t;

enum { DBL_RX_NONE = 0, DBL_RX_FRAME = 1, DBL_RX_ERROR = -1 };

void dbl_rx_init(dbl_rx_t *rx, uint32_t timeout_ms);
/* Feed one byte. Returns DBL_RX_FRAME (frame filled), DBL_RX_ERROR (*err set) or NONE. */
int dbl_rx_byte(dbl_rx_t *rx, uint8_t b, uint32_t now_ms, dbl_frame_t *frame, int *err);
/* Report an inter-byte timeout without another byte. */
int dbl_rx_poll(dbl_rx_t *rx, uint32_t now_ms, int *err);

/* Non-blocking client: one outstanding request, identical retries, stale replies dropped. */
typedef enum {
    DBL_CLIENT_IDLE = 0,       /* nothing outstanding */
    DBL_CLIENT_WAITING,        /* request outstanding, keep feeding bytes */
    DBL_CLIENT_RESEND,         /* send wire[0..wire_len) again now (identical bytes) */
    DBL_CLIENT_OUTCOME_UNKNOWN,/* no reply after every retry; the request may have run */
    DBL_CLIENT_MATCH,          /* reply matched; it is in the frame passed to on_frame */
    DBL_CLIENT_STALE,          /* frame did not match the outstanding request; ignore it */
    DBL_CLIENT_ERR_BUSY,       /* start() while a request is outstanding */
    DBL_CLIENT_ERR_NO_SESSION, /* start() without a session, or IDs exhausted */
    DBL_CLIENT_ERR_ARG         /* payload too long */
} dbl_client_result_t;

typedef struct {
    uint64_t session_id;
    uint32_t last_id;
    uint32_t timeout_ms;
    uint8_t max_retries;
    /* outstanding request */
    bool busy;
    uint8_t channel;
    uint16_t opcode;
    uint32_t request_id;
    uint32_t sent_ms;
    uint8_t attempts;
    uint8_t wire[DBL_MAX_WIRE];
    size_t wire_len;
    /* statistics */
    uint32_t sent, retries, stale, lost;
} dbl_client_t;

void dbl_client_init(dbl_client_t *c);
/* Use a fresh nonzero session ID (0 drops the session). Resets request IDs. */
void dbl_client_set_session(dbl_client_t *c, uint64_t session_id);
/* Read-only discovery: HELLO with session 0 and request 0. */
dbl_client_result_t dbl_client_discover(dbl_client_t *c, uint32_t now_ms);
/* Next request in the session. On WAITING, send wire[0..wire_len). */
dbl_client_result_t dbl_client_start(dbl_client_t *c, uint8_t channel, uint16_t opcode,
                                     const void *payload, uint16_t len, uint32_t now_ms);
/* Offer a received frame. MATCH ends the request; BAD_SESSION also drops the session. */
dbl_client_result_t dbl_client_on_frame(dbl_client_t *c, const dbl_frame_t *f);
/* Call periodically. RESEND: send wire again. OUTCOME_UNKNOWN: request abandoned. */
dbl_client_result_t dbl_client_tick(dbl_client_t *c, uint32_t now_ms);

#ifdef __cplusplus
}
#endif

#endif
