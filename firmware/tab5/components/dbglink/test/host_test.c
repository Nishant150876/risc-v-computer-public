/*
 * Host tests for the C debug-link codec and client.
 *
 *   host_test vectors <frames.txt> <sessions.txt>   golden vectors and client unit tests
 *   host_test decode                                 one encoded frame (hex) per stdin line
 *   host_test stream                                 "<ms> <hex>" chunks on stdin, one stream
 *
 * decode/stream print "ok <fields>" or "err <NAME>" per event, matching the Python codec's
 * output format so the two can be compared on random input.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dbglink.h"

static int failures, checks;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; \
    fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); \
    fputc('\n', stderr); } } while (0)

static size_t unhex(const char *s, uint8_t *out, size_t cap)
{
    if (strcmp(s, "-") == 0) return 0;
    size_t n = strlen(s) / 2;
    if (n > cap) { fprintf(stderr, "hex too long\n"); exit(2); }
    for (size_t i = 0; i < n; i++) {
        unsigned v;
        sscanf(s + 2 * i, "%2x", &v);
        out[i] = (uint8_t)v;
    }
    return n;
}

static void print_frame(const dbl_frame_t *f)
{
    printf("ok %u %u %u %u %04x %04x %08" PRIx32 " %016" PRIx64 " ", f->version, f->channel,
           f->kind, f->flags, f->opcode, f->status, f->request_id, f->session_id);
    if (!f->length) putchar('-');
    for (unsigned i = 0; i < f->length; i++) printf("%02x", f->payload[i]);
    putchar('\n');
}

static int frames_equal(const dbl_frame_t *a, const dbl_frame_t *b)
{
    return a->version == b->version && a->channel == b->channel && a->kind == b->kind &&
           a->flags == b->flags && a->opcode == b->opcode && a->status == b->status &&
           a->request_id == b->request_id && a->session_id == b->session_id &&
           a->length == b->length && memcmp(a->payload, b->payload, a->length) == 0;
}

static int error_code(const char *name)
{
    for (unsigned i = 0; i < DBL_FRAME_ERROR_COUNT; i++)
        if (strcmp(dbl_frame_error_names[i], name) == 0) return (int)i;
    return -1;
}

/* Feed bytes one at a time; returns the number of events and fills the last frame/error. */
static int stream_feed(dbl_rx_t *rx, const uint8_t *b, size_t n, uint32_t now,
                       dbl_frame_t *last, int *last_err, int *frames)
{
    int events = 0;
    for (size_t i = 0; i < n; i++) {
        int err = 0, r = dbl_rx_byte(rx, b[i], now, last, &err);
        if (r == DBL_RX_FRAME) { events++; (*frames)++; *last_err = DBL_ERR_OK; }
        if (r == DBL_RX_ERROR) { events++; *last_err = err; }
    }
    return events;
}

static void run_frames(const char *path)
{
    FILE *fp = fopen(path, "r");
    if (!fp) { perror(path); exit(2); }
    static char line[4096];
    static uint8_t a[1024], b[1024], c[1024];
    int ok = 0, err = 0, crc = 0, cobs = 0;
    while (fgets(line, sizeof line, fp)) {
        char tag[8], name[64];
        if (line[0] == '#' || sscanf(line, "%7s %63s", tag, name) != 2) continue;
        if (strcmp(tag, "crc") == 0) {
            char data[1024];
            unsigned long want;
            sscanf(line, "%*s %*s %1023s %lx", data, &want);
            size_t n = unhex(data, a, sizeof a);
            CHECK(dbl_crc32(0, a, n) == (uint32_t)want, "crc %s", name);
            /* Incremental CRC over two pieces must agree. */
            CHECK(dbl_crc32(dbl_crc32(0, a, n / 2), a + n / 2, n - n / 2) == (uint32_t)want,
                  "crc split %s", name);
            crc++;
        } else if (strcmp(tag, "cobs") == 0) {
            char raw[1024], enc[1024];
            sscanf(line, "%*s %*s %1023s %1023s", raw, enc);
            size_t n = unhex(raw, a, sizeof a), m = unhex(enc, b, sizeof b);
            size_t w = dbl_cobs_encode(a, n, c);
            CHECK(w == m && memcmp(c, b, m) == 0, "cobs encode %s", name);
            int d = dbl_cobs_decode(b, m, c, sizeof c);
            CHECK(d == (int)n && memcmp(c, a, n) == 0, "cobs decode %s", name);
            cobs++;
        } else if (strcmp(tag, "ok") == 0) {
            unsigned ver, ch, kind, flags, op, st;
            char rid[16], sid[24], payload[1024], wire[1024];
            sscanf(line, "%*s %*s %u %u %u %u %x %x %15s %23s %1023s %1023s", &ver, &ch, &kind,
                   &flags, &op, &st, rid, sid, payload, wire);
            dbl_frame_t f, g;
            size_t plen = unhex(payload, a, sizeof a), wlen = unhex(wire, b, sizeof b);
            CHECK(dbl_frame_set(&f, (uint8_t)ch, (uint8_t)kind, (uint16_t)op, (uint16_t)st,
                                (uint32_t)strtoul(rid, NULL, 16), strtoull(sid, NULL, 16), a,
                                (uint16_t)plen) == 0, "set %s", name);
            size_t w = dbl_wire_encode(&f, c);
            CHECK(w == wlen && memcmp(c, b, wlen) == 0, "wire encode %s", name);
            CHECK(wlen <= DBL_MAX_WIRE, "wire bound %s", name);
            CHECK(dbl_wire_decode(b, wlen - 1, &g) == DBL_ERR_OK && frames_equal(&f, &g),
                  "wire decode %s", name);
            dbl_rx_t rx;
            int frames = 0, last_err = -1;
            dbl_rx_init(&rx, DBL_INTERBYTE_TIMEOUT_MS);
            CHECK(stream_feed(&rx, b, wlen, 0, &g, &last_err, &frames) == 1 && frames == 1 &&
                  frames_equal(&f, &g), "stream %s", name);
            ok++;
        } else if (strcmp(tag, "err") == 0) {
            char want[32], enc[1024];
            sscanf(line, "%*s %*s %31s %1023s", want, enc);
            size_t n = unhex(enc, a, sizeof a);
            int code = error_code(want);
            dbl_frame_t g;
            int got = dbl_wire_decode(a, n, &g);
            CHECK(got == code, "decode %s: got %s want %s", name,
                  got >= 0 ? dbl_frame_error_names[got] : "?", want);
            dbl_rx_t rx;
            int frames = 0, last_err = -1;
            dbl_rx_init(&rx, DBL_INTERBYTE_TIMEOUT_MS);
            a[n] = 0;
            int ev = stream_feed(&rx, a, n + 1, 0, &g, &last_err, &frames);
            CHECK(ev == 1 && frames == 0 && last_err == code && rx.counts[code] == 1,
                  "stream %s: events %d err %d", name, ev, last_err);
            err++;
        }
    }
    fclose(fp);
    CHECK(ok >= 20 && err >= 15 && crc >= 5 && cobs >= 6, "vector counts %d %d %d %d", ok, err,
          crc, cobs);
    printf("frames.txt: %d ok, %d err, %d crc, %d cobs vectors\n", ok, err, crc, cobs);
}

/* Every wire in the session vectors, fed as one continuous stream, decodes back exactly. */
static void run_sessions(const char *path)
{
    FILE *fp = fopen(path, "r");
    if (!fp) { perror(path); exit(2); }
    static char line[4096];
    static uint8_t b[1024], c[1024];
    dbl_rx_t rx;
    dbl_rx_init(&rx, DBL_INTERBYTE_TIMEOUT_MS);
    int wires = 0, scenarios = 0;
    while (fgets(line, sizeof line, fp)) {
        char tag[16], hex[1024];
        if (line[0] == '#' || sscanf(line, "%15s", tag) != 1) continue;
        if (strcmp(tag, "scenario") == 0) { scenarios++; continue; }
        if (sscanf(line, "%*s %1023s", hex) != 1 || strcmp(hex, "none") == 0) continue;
        if (strcmp(tag, "send") && strcmp(tag, "expect")) continue;
        size_t n = unhex(hex, b, sizeof b);
        dbl_frame_t f;
        int frames = 0, last_err = -1;
        CHECK(stream_feed(&rx, b, n, 0, &f, &last_err, &frames) == 1 && frames == 1,
              "session wire %d", wires);
        CHECK(dbl_wire_encode(&f, c) == n && memcmp(b, c, n) == 0, "session re-encode %d", wires);
        wires++;
    }
    fclose(fp);
    CHECK(scenarios >= 10 && wires >= 60, "session counts %d %d", scenarios, wires);
    printf("sessions.txt: %d scenarios, %d wires\n", scenarios, wires);
}

static void test_receiver(void)
{
    dbl_frame_t f, g;
    uint8_t wire[DBL_MAX_WIRE];
    dbl_frame_set(&f, 0, 1, DBL_OP_STATUS, 0, 7, 9, "hi\0there", 8);
    size_t n = dbl_wire_encode(&f, wire);
    dbl_rx_t rx;
    int frames, e;

    /* Garbage, idle delimiters, then a good frame. */
    dbl_rx_init(&rx, 100);
    frames = 0;
    stream_feed(&rx, (const uint8_t *)"\x13\x37garbage\0\0\0", 12, 0, &g, &e, &frames);
    CHECK(frames == 0 && rx.counts[DBL_ERR_COBS_INVALID] == 1, "garbage");
    stream_feed(&rx, wire, n, 0, &g, &e, &frames);
    CHECK(frames == 1 && frames_equal(&f, &g), "recovery after garbage");

    /* Overflow: 1000 nonzero bytes are discarded through the next delimiter. */
    static uint8_t junk[1001];
    memset(junk, 1, 1000);
    junk[1000] = 0;
    frames = 0;
    stream_feed(&rx, junk, sizeof junk, 0, &g, &e, &frames);
    CHECK(frames == 0 && e == DBL_ERR_TOO_LONG && rx.counts[DBL_ERR_TOO_LONG] == 1, "overflow");
    stream_feed(&rx, wire, n, 0, &g, &e, &frames);
    CHECK(frames == 1 && frames_equal(&f, &g), "recovery after overflow");

    /* Inter-byte timeout: a gap of exactly 100 ms is fine, 101 ms discards. */
    frames = 0;
    stream_feed(&rx, wire, 10, 1000, &g, &e, &frames);
    stream_feed(&rx, wire + 10, n - 10, 1100, &g, &e, &frames);
    CHECK(frames == 1, "100 ms gap accepted");
    stream_feed(&rx, wire, 10, 2000, &g, &e, &frames);
    int err = 0;
    CHECK(dbl_rx_poll(&rx, 2100, &err) == DBL_RX_NONE, "poll at 100 ms");
    CHECK(dbl_rx_poll(&rx, 2101, &err) == DBL_RX_ERROR && err == DBL_ERR_TIMEOUT, "poll timeout");
    CHECK(dbl_rx_poll(&rx, 9000, &err) == DBL_RX_NONE, "poll after timeout is quiet");
    stream_feed(&rx, wire, 10, 3000, &g, &e, &frames);
    frames = 0;
    int ev = stream_feed(&rx, wire, n, 3101, &g, &e, &frames);
    CHECK(ev == 2 && frames == 1 && rx.counts[DBL_ERR_TIMEOUT] == 2, "timeout then frame");

    /* Time wrap: uint32 millisecond counters wrap without false timeouts. */
    dbl_rx_init(&rx, 100);
    frames = 0;
    stream_feed(&rx, wire, 5, 0xFFFFFFF0u, &g, &e, &frames);
    stream_feed(&rx, wire + 5, n - 5, 0x00000010u, &g, &e, &frames);
    CHECK(frames == 1, "time wrap");

    /* Oversize length is rejected on send. */
    f.length = DBL_MAX_PAYLOAD + 1;
    CHECK(dbl_wire_encode(&f, wire) == 0, "oversize encode refused");
    CHECK(dbl_frame_set(&f, 0, 0, 1, 0, 1, 1, wire, DBL_MAX_PAYLOAD + 1) == -1, "oversize set");
}

static void respond(const dbl_client_t *c, uint16_t status, dbl_frame_t *r)
{
    dbl_frame_t req;
    dbl_wire_decode(c->wire, c->wire_len - 1, &req);
    dbl_frame_set(r, req.channel, DBL_KIND_RESPONSE, req.opcode, status, req.request_id,
                  req.session_id, req.payload, req.length);
}

static void test_client(void)
{
    dbl_client_t c;
    dbl_frame_t r, req;
    dbl_client_init(&c);
    CHECK(dbl_client_start(&c, 0, DBL_OP_PING, NULL, 0, 0) == DBL_CLIENT_ERR_NO_SESSION,
          "no session");

    CHECK(dbl_client_discover(&c, 0) == DBL_CLIENT_WAITING, "discover");
    dbl_wire_decode(c.wire, c.wire_len - 1, &req);
    CHECK(req.session_id == 0 && req.request_id == 0 && req.opcode == DBL_OP_HELLO, "discover frame");
    respond(&c, 0, &r);
    CHECK(dbl_client_on_frame(&c, &r) == DBL_CLIENT_MATCH, "discover match");

    dbl_client_set_session(&c, 0xA1A2A3A4A5A6A7A8ull);
    CHECK(dbl_client_start(&c, 0, DBL_OP_HELLO, NULL, 0, 0) == DBL_CLIENT_WAITING, "claim");
    CHECK(dbl_client_start(&c, 0, DBL_OP_PING, NULL, 0, 0) == DBL_CLIENT_ERR_BUSY, "one outstanding");
    respond(&c, 0, &r);
    CHECK(dbl_client_on_frame(&c, &r) == DBL_CLIENT_MATCH && c.last_id == 1, "claim match");

    /* Lost reply: identical bytes are resent three times, then OUTCOME_UNKNOWN. */
    CHECK(dbl_client_start(&c, 0, DBL_OP_PING, "abc", 3, 1000) == DBL_CLIENT_WAITING, "ping");
    uint8_t first[DBL_MAX_WIRE];
    size_t first_len = c.wire_len;
    memcpy(first, c.wire, first_len);
    CHECK(dbl_client_tick(&c, 1499) == DBL_CLIENT_WAITING, "not yet");
    uint32_t t = 1500;
    for (int i = 0; i < 3; i++, t += 500) {
        CHECK(dbl_client_tick(&c, t) == DBL_CLIENT_RESEND, "resend %d", i);
        CHECK(c.wire_len == first_len && memcmp(c.wire, first, first_len) == 0, "identical %d", i);
    }
    CHECK(dbl_client_tick(&c, t) == DBL_CLIENT_OUTCOME_UNKNOWN && c.lost == 1 && c.sent == 6,
          "outcome unknown");
    CHECK(dbl_client_tick(&c, t + 1) == DBL_CLIENT_IDLE, "idle after give-up");

    /* A late reply to the abandoned request, or any mismatch, is stale. */
    CHECK(dbl_client_start(&c, 0, DBL_OP_STATUS, NULL, 0, t) == DBL_CLIENT_WAITING, "status");
    dbl_wire_decode(c.wire, c.wire_len - 1, &req);
    CHECK(req.request_id == 3, "IDs keep increasing after a give-up");
    dbl_frame_t stale;
    dbl_frame_set(&stale, 0, DBL_KIND_RESPONSE, DBL_OP_PING, 0, 2, c.session_id, "abc", 3);
    CHECK(dbl_client_on_frame(&c, &stale) == DBL_CLIENT_STALE, "late reply");
    respond(&c, 0, &r);
    r.session_id ^= 1;
    CHECK(dbl_client_on_frame(&c, &r) == DBL_CLIENT_STALE, "wrong session");
    respond(&c, 0, &r);
    r.kind = DBL_KIND_EVENT;
    CHECK(dbl_client_on_frame(&c, &r) == DBL_CLIENT_STALE, "event is not an ack");
    respond(&c, 0, &r);
    r.opcode = DBL_OP_PING;
    CHECK(dbl_client_on_frame(&c, &r) == DBL_CLIENT_STALE, "wrong opcode");
    respond(&c, DBL_ST_BAD_SESSION, &r);
    CHECK(dbl_client_on_frame(&c, &r) == DBL_CLIENT_MATCH && c.session_id == 0, "bad session drops");
    CHECK(c.stale == 4, "stale count %u", c.stale);

    /* ID exhaustion requires a new session. */
    dbl_client_set_session(&c, 5);
    c.last_id = UINT32_MAX - 1;
    CHECK(dbl_client_start(&c, 0, DBL_OP_PING, NULL, 0, 0) == DBL_CLIENT_WAITING, "last id");
    respond(&c, 0, &r);
    dbl_client_on_frame(&c, &r);
    CHECK(dbl_client_start(&c, 0, DBL_OP_PING, NULL, 0, 0) == DBL_CLIENT_ERR_NO_SESSION, "wrap");
    dbl_client_set_session(&c, 6);
    CHECK(dbl_client_start(&c, 0, DBL_OP_PING, NULL, 0, 0) == DBL_CLIENT_WAITING,
          "fresh session");
}

static void test_schema_header(void)
{
    uint8_t p[DBL_HELLO_RESPONSE_BYTES] = {1, 0, 36, 0, 1, 0, 0x32, 0x54, 1, 0, 0, 0};
    p[12] = 0xA0; p[13] = 0xAC; p[14] = 0xB9; p[15] = 0x03; /* 62 500 000 */
    dbl_hello_response_t h;
    CHECK(dbl_unpack_hello_response(p, sizeof p, &h) == 0 && h.build_id == 0x54320001u &&
          h.clock_hz == 62500000u && h.descriptor_bytes == 36, "hello unpack");
    CHECK(dbl_unpack_hello_response(p, sizeof p - 1, &h) == -1, "hello size check");
    CHECK(DBL_MAX_FRAME == DBL_HEADER_BYTES + DBL_MAX_PAYLOAD + DBL_CRC_BYTES, "frame bound");
    CHECK(DBL_CAP_BASE_STATUS == 1u && DBL_CAP_REFERENCE_CAPTURE == 0x8000u, "capability bits");
    CHECK(dbl_crc32(0, (const uint8_t *)"123456789", 9) == 0xCBF43926u, "crc check value");
}

static void run_decode(void)
{
    static char line[8192];
    static uint8_t b[4096];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        size_t n = unhex(line[0] ? line : "-", b, sizeof b);
        dbl_frame_t f;
        int r = dbl_wire_decode(b, n, &f);
        if (r == DBL_ERR_OK) print_frame(&f);
        else printf("err %s\n", dbl_frame_error_names[r]);
    }
}

static void run_stream(void)
{
    static char line[16384];
    static uint8_t b[8192];
    dbl_rx_t rx;
    dbl_rx_init(&rx, DBL_INTERBYTE_TIMEOUT_MS);
    while (fgets(line, sizeof line, stdin)) {
        unsigned long now;
        static char hex[16384];
        if (sscanf(line, "%lu %16383s", &now, hex) != 2) continue;
        size_t n = unhex(hex, b, sizeof b);
        for (size_t i = 0; i < n; i++) {
            dbl_frame_t f;
            int err, r = dbl_rx_byte(&rx, b[i], (uint32_t)now, &f, &err);
            if (r == DBL_RX_FRAME) print_frame(&f);
            if (r == DBL_RX_ERROR) printf("err %s\n", dbl_frame_error_names[err]);
        }
    }
}

int main(int argc, char **argv)
{
    if (argc == 4 && strcmp(argv[1], "vectors") == 0) {
        run_frames(argv[2]);
        run_sessions(argv[3]);
        test_receiver();
        test_client();
        test_schema_header();
        printf("%s: %d checks, %d failures\n", failures ? "FAIL" : "PASS", checks, failures);
        return failures != 0;
    }
    if (argc == 2 && strcmp(argv[1], "decode") == 0) { run_decode(); return 0; }
    if (argc == 2 && strcmp(argv[1], "stream") == 0) { run_stream(); return 0; }
    fprintf(stderr, "usage: host_test vectors <frames.txt> <sessions.txt> | decode | stream\n");
    return 2;
}
