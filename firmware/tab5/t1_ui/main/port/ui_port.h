/*
 * What the UI needs from the platform. The Tab5 build fills this in with
 * FreeRTOS queues and ESP heap calls (app_main.c); the desktop simulator
 * fills it in with plain functions (sim/sim_main.c). The UI never includes
 * FreeRTOS or ESP headers, so the same screens run in both.
 */
#ifndef UI_PORT_H
#define UI_PORT_H

#include <stdbool.h>
#include <stdint.h>

#include "../state/app_state.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t free_heap;        /* bytes, all capabilities */
    uint32_t min_free_heap;    /* lowest free_heap since boot */
    uint32_t free_internal;    /* internal SRAM */
    uint32_t free_psram;
    uint32_t worker_stack_free;  /* bytes never used by the worker task */
    uint32_t ui_stack_free;      /* bytes never used by the LVGL task */
    uint32_t msg_queue_drops;  /* worker -> UI messages dropped (queue full) */
    uint32_t msg_queue_peak;   /* most messages waiting at once */
} port_stats_t;

typedef struct {
    uint32_t (*now_ms)(void);
    uint64_t (*now_us)(void);
    /* Non-blocking. false = queue full; the command is not sent. */
    bool (*send_cmd)(const ui_cmd_t *cmd);
    /* Non-blocking. false = nothing waiting. */
    bool (*recv_msg)(dev_msg_t *msg);
    void (*get_stats)(port_stats_t *out);
    const char *build_info;    /* firmware version string */
    const char *platform;      /* "Tab5" or "desktop simulator" */
    bool backend_is_mock;      /* chosen backend, never inferred from incoming values */
    bool test_fixture;         /* native UI tests only; persistent fixture banner */
} ui_port_t;

#ifdef __cplusplus
}
#endif
#endif
