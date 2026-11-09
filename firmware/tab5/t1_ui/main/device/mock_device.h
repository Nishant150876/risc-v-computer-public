/*
 * MOCK device backend for milestone T1.
 *
 * Pretends to be an FPGA debug link so the UI can be built and tested
 * before the real protocol exists (T2+). Everything it produces is tagged
 * PROV_MOCK and every console line it writes starts with "MOCK".
 *
 * Pure C and time-driven: the caller passes the current time in ms, so the
 * same code runs in a FreeRTOS task on the Tab5 and in the desktop simulator.
 */
#ifndef MOCK_DEVICE_H
#define MOCK_DEVICE_H

#include "../state/app_state.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*mock_emit_fn)(void *ctx, const dev_msg_t *m);

typedef struct {
    link_state_t link;
    bool         announced;      /* first CONNECTING sent */
    uint32_t     link_t_ms;      /* when the current link state started */
    uint32_t     next_snap_ms;
    uint32_t     next_console_ms;
    uint32_t     rng;
    cpu_snapshot_t snap;
    uint32_t     prime_next;   /* next number to test for the console */
    /* simulated transfer */
    op_state_t   op;
    uint8_t      op_program;
    bool         op_will_fail;
    uint32_t     op_t0_ms;
    uint32_t     next_op_ms;
} mock_device_t;

#define MOCK_CONNECT_MS   800u
#define MOCK_SNAP_MS      200u   /* 5 Hz, the T1 refresh budget */
#define MOCK_CONSOLE_MS   350u
#define MOCK_RETRY_MS     2000u
#define MOCK_TRANSFER_MS  3000u
#define MOCK_CLOCK_HZ     62500000u

void mock_device_init(mock_device_t *d, uint32_t now_ms);
void mock_device_command(mock_device_t *d, const ui_cmd_t *c, uint32_t now_ms,
                         mock_emit_fn emit, void *ctx);
void mock_device_step(mock_device_t *d, uint32_t now_ms, mock_emit_fn emit, void *ctx);

/* Mock program list shown on the Programs screen. */
#define MOCK_PROGRAM_COUNT 4
typedef struct {
    const char *name;
    const char *desc;
    uint32_t    bytes;
} mock_program_t;
extern const mock_program_t mock_programs[MOCK_PROGRAM_COUNT];

#ifdef __cplusplus
}
#endif
#endif
