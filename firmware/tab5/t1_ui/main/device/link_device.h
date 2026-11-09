/* Pure-C asynchronous worker backend. No LVGL, FreeRTOS, allocation or I/O.
 * Call tick/feed/command from one worker; emit immutable messages to the UI.
 * send must accept the entire bounded wire frame or accept no bytes. */
#ifndef LINK_DEVICE_H
#define LINK_DEVICE_H
#include "dbglink.h"
#include "state/app_state.h"

typedef bool (*link_send_fn)(void *ctx, const uint8_t *wire, size_t length);
typedef void (*link_emit_fn)(void *ctx, const dev_msg_t *message);
typedef enum { LD_DISCOVER,LD_CLAIM,LD_STATUS,LD_COUNTERS,LD_REGISTERS,LD_WAIT,LD_COMMAND,LD_ERROR } link_phase_t;
typedef struct {
    dbl_client_t client;
    dbl_rx_t rx;
    link_phase_t phase;
    dbl_hello_response_t descriptor;
    cpu_snapshot_t snapshot;
    uint64_t session;
    uint32_t due_ms,status_ms,received,rejected,command_refused;
    uint16_t pending_command;
    bool connected,uncertain;
    link_send_fn send;
    link_emit_fn emit;
    void *ctx;
} link_device_t;

void link_device_init(link_device_t *d, uint64_t session, uint32_t now_ms,
                      link_send_fn send, link_emit_fn emit, void *ctx);
void link_device_tick(link_device_t *d, uint32_t now_ms);
void link_device_feed(link_device_t *d, const uint8_t *bytes, size_t length, uint32_t now_ms);
bool link_device_command(link_device_t *d, const ui_cmd_t *command, uint32_t now_ms);
#endif
