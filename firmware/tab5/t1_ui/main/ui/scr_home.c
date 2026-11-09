/* Home: identity, link/CPU/operation state, PC, summary counters, shortcuts. */
#include <stdio.h>

#include "ui_internal.h"

static lv_obj_t *s_badge[4];
static lv_obj_t *s_link, *s_reason, *s_cpu, *s_op;
static lv_obj_t *s_board, *s_core, *s_clock, *s_bit;
static lv_obj_t *s_pc, *s_last_pc, *s_gen;
static lv_obj_t *s_cycles, *s_instret, *s_cpi;
static lv_obj_t *s_halt,*s_resume,*s_step,*s_reset;

static void control_cb(lv_event_t *e)
{
    ui_send((ui_cmd_type_t)(intptr_t)lv_event_get_user_data(e),0);
}

static lv_obj_t *card(lv_obj_t *parent, const char *title, int i)
{
    lv_obj_t *p = ui_panel(parent, title, &s_badge[i]);
    lv_obj_set_width(p, LV_PCT(48));
    return p;
}

static void go_cb(lv_event_t *e)
{
    ui_goto((int)(intptr_t)lv_event_get_user_data(e));
}

void scr_home_create(lv_obj_t *parent)
{
    lv_obj_t *grid = ui_row(parent);
    lv_obj_set_flex_align(grid, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);

    lv_obj_t *c = card(grid, "State", 0);
    s_link = ui_kv(c, "Link");
    s_reason = ui_kv(c, "Reason");
    s_cpu = ui_kv(c, "CPU");
    s_op = ui_kv(c, "Operation");

    c = card(grid, "Identity", 1);
    s_board = ui_kv(c, "Board");
    s_core = ui_kv(c, "Core");
    s_clock = ui_kv(c, "Configured clock");
    s_bit = ui_kv(c, "Bitstream");

    c = card(grid, "Program counter", 2);
    ui_label(c, F_BODY, C_MUTED, "Next PC");
    s_pc = ui_label(c, F_BIG, C_TEXT, "-");
    s_last_pc = ui_kv(c, "Last retired PC");
    s_gen = ui_kv(c, "Snapshot");

    c = card(grid, "Summary counters", 3);
    ui_label(c, F_BODY, C_MUTED, "CPI (cycles / instructions)");
    s_cpi = ui_label(c, F_BIG, C_TEXT, "-");
    s_cycles = ui_kv(c, "Cycles");
    s_instret = ui_kv(c, "Instructions retired");

    lv_obj_t *sc = ui_panel(parent, "Shortcuts", NULL);
    lv_obj_set_width(sc, LV_PCT(100));
    lv_obj_t *badge = lv_obj_get_child(lv_obj_get_child(sc, 0), 1);
    lv_obj_add_flag(badge, LV_OBJ_FLAG_HIDDEN); /* navigation, not data */
    lv_obj_t *r = ui_row(sc);
    ui_button(r, LV_SYMBOL_KEYBOARD " Terminal", go_cb, (void *)(intptr_t)SCR_TERMINAL);
    ui_button(r, LV_SYMBOL_BARS " Counters", go_cb, (void *)(intptr_t)SCR_COUNTERS);
    ui_button(r, LV_SYMBOL_LIST " Programs", go_cb, (void *)(intptr_t)SCR_PROGRAMS);
    ui_button(r, LV_SYMBOL_IMAGE " About", go_cb, (void *)(intptr_t)SCR_ABOUT);

    if(!g_ui.port->backend_is_mock) {
        lv_obj_t *action_badge;
        lv_obj_t *panel=ui_panel(parent,"CPU control",&action_badge);
        lv_obj_add_flag(action_badge,LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_width(panel,LV_PCT(100));
        lv_obj_t *row=ui_row(panel);
        s_halt=ui_button(row,"Halt",control_cb,(void *)(intptr_t)CMD_CPU_HALT);
        s_resume=ui_button(row,"Resume",control_cb,(void *)(intptr_t)CMD_CPU_RESUME);
        s_step=ui_button(row,"Step one instruction",control_cb,(void *)(intptr_t)CMD_CPU_STEP);
        s_reset=ui_button(row,"Hold CPU reset",control_cb,(void *)(intptr_t)CMD_CPU_RESET);
        ui_note(panel,"Resume and step require a verified image. Unknown outcomes lock mutations until reconciled; no new command is silently repeated.");
    }
    ui_sim_controls(parent);
}

void scr_home_update(const app_state_t *st, uint32_t now)
{
    const hw_model_t *hw = &st->hw;
    char b[48];
    for (int i = 0; i < 4; i++) {
        ui_badge_update(s_badge[i], st, now);
    }
    ui_capture_badge(s_badge[3],st,(hw->snap.counter_mask & 3u)==3u,hw->snap.counter_t_ms,now);
    if(s_halt) {
        bool live=hw->link==LINK_CONNECTED && hw->snap.prov==PROV_LIVE;
        bool idle=hw->snap.operation_state==0 || hw->snap.operation_state==6 || hw->snap.operation_state==7;
        bool stopped=hw->snap.cpu==CPU_HALTED || hw->snap.cpu==CPU_BREAKPOINT;
        ui_button_set_enabled(s_halt,live && idle && hw->id.can_halt && hw->snap.cpu==CPU_RUNNING);
        ui_button_set_enabled(s_resume,live && idle && hw->id.can_halt && stopped && hw->snap.image_valid);
        ui_button_set_enabled(s_step,live && idle && hw->id.can_step && stopped && hw->snap.image_valid);
        ui_button_set_enabled(s_reset,live && idle && hw->id.can_halt);
    }

    ui_set_text(s_link, link_name(hw->link));
    lv_obj_set_style_text_color(s_link, lv_color_hex(hw->link == LINK_CONNECTED ? C_GREEN :
                                                      hw->link == LINK_CONNECTING ? C_AMBER : C_RED), 0);
    ui_set_text(s_reason, hw->link_reason);
    ui_set_text(s_cpu, hw->snap.prov == PROV_NONE ? "-" : cpu_name(hw->snap.cpu));
    if (hw->op == OP_TRANSFER) {
        snprintf(b, sizeof b, "TRANSFER %u%%", (unsigned)(hw->op_permille / 10u));
        ui_set_text(s_op, b);
    } else {
        ui_set_text(s_op, op_name(hw->op));
    }

    if (hw->have_id) {
        ui_set_text(s_board, hw->id.board);
        ui_set_text(s_core, hw->id.core);
        snprintf(b, sizeof b, "%lu.%01lu MHz", (unsigned long)(hw->id.clock_hz / 1000000u),
                 (unsigned long)(hw->id.clock_hz / 100000u % 10u));
        ui_set_text(s_clock, b);
        ui_set_text(s_bit, hw->id.bitstream);
    }

    if (hw->snap.prov != PROV_NONE) {
        if(hw->snap.pc_valid & 2u) fmt_hex32(b, sizeof b, hw->snap.pc); else snprintf(b,sizeof b,"-");
        ui_set_text(s_pc, b);
        if(hw->snap.pc_valid & 1u) fmt_hex32(b, sizeof b, hw->snap.last_pc); else snprintf(b,sizeof b,"-");
        ui_set_text(s_last_pc, b);
        snprintf(b, sizeof b, "#%lu", (unsigned long)hw->snap.generation);
        ui_set_text(s_gen, b);
        fmt_u64(b, sizeof b, hw->snap.ctr.cycles);
        ui_set_text(s_cycles, b);
        fmt_u64(b, sizeof b, hw->snap.ctr.instret);
        ui_set_text(s_instret, b);
        fmt_cpi(b, sizeof b, counters_cpi_milli(&hw->snap.ctr));
        ui_set_text(s_cpi, b);
        if((hw->snap.counter_mask & 3u)!=3u) { ui_set_text(s_cpi,"-"); ui_set_text(s_cycles,"-"); ui_set_text(s_instret,"-"); }
    }
    uint32_t c = app_state_is_stale(st, now) ? C_MUTED : C_TEXT;
    lv_obj_set_style_text_color(s_pc, lv_color_hex(c), 0);
    lv_obj_set_style_text_color(s_cpi, lv_color_hex(c), 0);
}
