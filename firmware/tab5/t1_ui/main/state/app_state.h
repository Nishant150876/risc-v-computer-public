/*
 * Application state for the Tab5 UI (milestone T1).
 *
 * Pure C, no LVGL, no FreeRTOS. Only the UI task owns an app_state_t. Other
 * tasks send it immutable messages (dev_msg_t) through a bounded queue, and
 * app_state_apply() folds each message into the model.
 */
#ifndef APP_STATE_H
#define APP_STATE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Where a value came from (TAB5_FIRMWARE.md section 4) ------------- */
typedef enum {
    PROV_NONE = 0,   /* nothing received yet */
    PROV_MOCK,       /* simulated; the only source at T1 */
    PROV_LIVE,       /* read from the FPGA just now (T5+) */
    PROV_CAPTURED,   /* frozen hardware snapshot (T8+) */
    PROV_HISTORICAL, /* stored earlier result */
} provenance_t;

/* ---- Three independent state machines --------------------------------- */
typedef enum {
    LINK_DISCONNECTED = 0,
    LINK_CONNECTING,
    LINK_CONNECTED,
    LINK_ERROR,
} link_state_t;

typedef enum {
    CPU_UNKNOWN = 0,
    CPU_RESET_HELD,
    CPU_RUNNING,
    CPU_HALTED,
    CPU_STEPPING, CPU_BREAKPOINT, CPU_TERMINATED, CPU_ERROR,
} cpu_state_t;

typedef enum {
    OP_IDLE = 0,
    OP_TRANSFER,     /* simulated program transfer in progress */
    OP_DONE,
    OP_FAILED,
} op_state_t;

/* ---- UI view mode: two views of the same state ------------------------ */
typedef enum {
    MODE_DEMO = 0,
    MODE_ENGINEERING,
} ui_mode_t;

/* ---- Counters (names follow sw/common cpi_report and Phase 5) --------- */
typedef struct {
    uint64_t cycles;
    uint64_t instret;
    uint64_t stalls;     /* load-use stall cycles */
    uint64_t flushes;    /* branch/jump flush cycles */
    uint64_t loads;
    uint64_t stores;
    uint64_t branches;
    uint64_t taken;
    uint64_t jumps;
} counters_t;

/* One coherent snapshot. Sent by value, never shared. */
typedef struct {
    provenance_t prov;
    uint32_t     generation;   /* increments per snapshot */
    uint32_t     pc;           /* next PC */
    uint32_t     last_pc;      /* last retired PC */
    uint32_t     regs[32];
    cpu_state_t  cpu;
    counters_t   ctr;
    uint8_t      pc_valid;     /* bit 0 last retired PC, bit 1 next PC */
    bool         regs_valid;
    uint16_t     counter_mask; /* row bits: cycles/inst/stalls/flush/loads/stores/branches/taken/jumps */
    uint32_t     regs_generation, counter_generation;
    uint32_t     regs_t_ms, counter_t_ms, cpu_epoch;
    bool         image_valid;
    uint8_t      operation_state;
} cpu_snapshot_t;

typedef struct {
    char     board[24];
    char     core[24];
    char     bitstream[24];
    uint32_t clock_hz;
    uint32_t protocol_version;
    uint32_t capabilities;
    bool can_halt, can_step;
} identity_t;

/* ---- Messages from worker tasks to the UI task ------------------------ */
typedef enum {
    MSG_LINK = 1,
    MSG_IDENTITY,
    MSG_SNAPSHOT,
    MSG_CONSOLE,
    MSG_OP,
} dev_msg_type_t;

#define CONSOLE_CHUNK 48

typedef struct {
    dev_msg_type_t type;
    uint32_t       t_ms;
    union {
        struct { link_state_t state; char reason[40]; } link;
        identity_t     id;
        cpu_snapshot_t snap;
        struct { uint8_t len; char text[CONSOLE_CHUNK]; } console;
        struct { op_state_t state; uint8_t program; uint16_t permille; char detail[40]; } op;
    } u;
} dev_msg_t;

/* ---- Commands from the UI task to the worker -------------------------- */
/* At T1 these are SIMULATION controls only. None of them pretends to touch
 * real hardware; real mutations arrive with T3/T4/T5 and a live backend. */
typedef enum {
    CMD_SIM_DISCONNECT = 1,
    CMD_SIM_RECONNECT,
    CMD_SIM_LINK_ERROR,
    CMD_SIM_TRANSFER,      /* arg = program index */
    CMD_SIM_TRANSFER_FAIL, /* arg = program index; fails part way */
    CMD_CPU_HALT, CMD_CPU_RESUME, CMD_CPU_STEP, CMD_CPU_RESET,
    CMD_LINK_RECONNECT,
} ui_cmd_type_t;

typedef struct {
    ui_cmd_type_t type;
    uint32_t      arg;
} ui_cmd_t;

/* ---- The model -------------------------------------------------------- */
#define CONSOLE_BYTES 4096   /* bounded terminal buffer */
#define CPI_HISTORY   60

typedef struct {
    /* hardware-side model (must not change on a mode switch) */
    link_state_t   link;
    char           link_reason[40];
    uint32_t       link_changes;
    identity_t     id;
    bool           have_id;
    cpu_snapshot_t snap;
    uint32_t       snap_t_ms;     /* when the snapshot arrived */
    uint32_t       changed_regs;  /* bit i: x[i] changed in the last snapshot */
    op_state_t     op;
    uint8_t        op_program;
    uint16_t       op_permille;
    char           op_detail[40];

    /* terminal: ring of the newest CONSOLE_BYTES characters */
    char           console[CONSOLE_BYTES + 1];
    size_t         console_len;
    uint32_t       console_dropped;  /* characters pushed out of the ring */
    uint32_t       console_gen;

    /* CPI history for the counters screen, in milli-CPI */
    uint16_t       cpi_hist[CPI_HISTORY];
    uint8_t        cpi_count;
    counters_t     prev_ctr;

    uint32_t       msgs_applied;
} hw_model_t;

typedef struct {
    hw_model_t hw;
    /* view-side state */
    ui_mode_t  mode;
    int        screen;           /* screen id, see ui/screens.h */
    bool       reg_decimal;      /* registers view: hex or decimal */
    int        reg_selected;     /* -1 = none */
} app_state_t;

void        app_state_init(app_state_t *s);
void        app_state_apply(app_state_t *s, const dev_msg_t *m);
/* Age of the displayed snapshot in ms; UINT32_MAX if none. */
uint32_t    app_state_data_age(const app_state_t *s, uint32_t now_ms);
/* Data is stale when the link is not up or the newest snapshot is old. */
bool        app_state_is_stale(const app_state_t *s, uint32_t now_ms);
/* Milli-CPI from a counter pair, 0 if no instructions. */
uint32_t    counters_cpi_milli(const counters_t *c);
void        app_state_console_clear(app_state_t *s);
/* Checksum of the hardware-side model, used to prove mode switches keep it. */
uint32_t    hw_model_hash(const hw_model_t *hw);

const char *prov_name(provenance_t p);
const char *link_name(link_state_t l);
const char *cpu_name(cpu_state_t c);
const char *op_name(op_state_t o);
const char *reg_abi_name(int i);

#define STALE_AFTER_MS 1500u

#ifdef __cplusplus
}
#endif
#endif
