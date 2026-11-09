/* Screen table. Every planned screen from TAB5_FIRMWARE.md section 5 has an
 * entry; the ones that need hardware T1 does not have show a locked page. */
#ifndef SCREENS_H
#define SCREENS_H

#include <stdbool.h>
#include <stdint.h>

#include "lvgl.h"

#include "../state/app_state.h"

typedef enum {
    SCR_HOME = 0,
    SCR_PROGRAMS,
    SCR_TERMINAL,
    SCR_REGISTERS,
    SCR_COUNTERS,
    SCR_SYSTEM,
    SCR_ABOUT,
    SCR_CPU,
    SCR_MEMORY,
    SCR_PIPELINE,
    SCR_TRACE,
    SCR_DIAG,
    SCR_FAULT,
    SCR_REFERENCE,
    SCR_COUNT
} screen_id_t;

typedef struct {
    const char *name;
    const char *symbol;     /* LV_SYMBOL_* */
    bool        in_demo;    /* listed in Demo Mode */
    bool        locked;     /* needs hardware support T1 does not have */
    const char *milestone;  /* when it becomes real */
    const char *needs;      /* what it is waiting for (locked screens) */
    void (*create)(lv_obj_t *parent);
    void (*update)(const app_state_t *st, uint32_t now_ms);
} screen_def_t;

extern const screen_def_t g_screens[SCR_COUNT];

void scr_home_create(lv_obj_t *parent);
void scr_home_update(const app_state_t *st, uint32_t now_ms);
void scr_programs_create(lv_obj_t *parent);
void scr_programs_update(const app_state_t *st, uint32_t now_ms);
void scr_terminal_create(lv_obj_t *parent);
void scr_terminal_update(const app_state_t *st, uint32_t now_ms);
void scr_registers_create(lv_obj_t *parent);
void scr_registers_update(const app_state_t *st, uint32_t now_ms);
void scr_counters_create(lv_obj_t *parent);
void scr_counters_update(const app_state_t *st, uint32_t now_ms);
void scr_system_create(lv_obj_t *parent);
void scr_system_update(const app_state_t *st, uint32_t now_ms);
void scr_about_create(lv_obj_t *parent);

#endif
