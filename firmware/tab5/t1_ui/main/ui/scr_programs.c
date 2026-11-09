/* Programs: the program list with a simulated, bounded transfer.
 * Real verify/load/run arrives with the T5 loader. */
#include <stdio.h>

#include "../device/mock_device.h"
#include "ui_internal.h"

static lv_obj_t *s_badge;
static lv_obj_t *s_bar;
static lv_obj_t *s_status;
static lv_obj_t *s_sim_ok[MOCK_PROGRAM_COUNT];
static lv_obj_t *s_sim_fail[MOCK_PROGRAM_COUNT];

static void sim_cb(lv_event_t *e)
{
    uint32_t v = (uint32_t)(intptr_t)lv_event_get_user_data(e);
    ui_send((v & 0x100u) ? CMD_SIM_TRANSFER_FAIL : CMD_SIM_TRANSFER, v & 0xFFu);
}

void scr_programs_create(lv_obj_t *parent)
{
    lv_obj_t *p = ui_panel(parent, "Transfer", &s_badge);
    lv_obj_set_width(p, LV_PCT(100));
    s_status = ui_label(p, F_LABEL, C_TEXT, "No transfer yet");
    s_bar = lv_bar_create(p);
    lv_obj_set_size(s_bar, LV_PCT(100), 24);
    lv_bar_set_range(s_bar, 0, 1000);
    lv_obj_set_style_bg_color(s_bar, lv_color_hex(C_PANEL2), LV_PART_MAIN);
    lv_obj_set_style_bg_color(s_bar, lv_color_hex(C_AMBER), LV_PART_INDICATOR);
    ui_note(p,g_ui.port->backend_is_mock ?
        "Transfers here are simulated: no bytes leave the Tab5. The demonstration list is MOCK." :
        "SD program launch is pending. Use the host loader for the simulation profile; these MOCK demonstration cards are disabled on a real link.");

    for (int i = 0; i < MOCK_PROGRAM_COUNT; i++) {
        const mock_program_t *mp = &mock_programs[i];
        lv_obj_t *c = ui_panel(parent, mp->name, NULL);
        lv_obj_set_width(c, LV_PCT(100));
        ui_note(c, mp->desc);
        lv_obj_t *sz = ui_label(c, F_BODY, C_MUTED, "");
        lv_label_set_text_fmt(sz, "%lu bytes (MOCK size)", (unsigned long)mp->bytes);
        lv_obj_t *r = ui_row(c);
        s_sim_ok[i] = ui_button(r, LV_SYMBOL_DOWNLOAD " Simulate load", sim_cb, (void *)(intptr_t)i);
        s_sim_fail[i] = ui_button(r, LV_SYMBOL_WARNING " Simulate failed load", sim_cb,
                                  (void *)(intptr_t)(i | 0x100));
        lv_obj_t *run = ui_button(r, LV_SYMBOL_PLAY " Run on FPGA", NULL, NULL);
        ui_button_set_enabled(run, false);
        ui_label(r, F_BODY, C_MUTED, "Run needs T5");
    }
}

void scr_programs_update(const app_state_t *st, uint32_t now)
{
    const hw_model_t *hw = &st->hw;
    char b[96];
    ui_badge_update(s_badge, st, now);
    if(!g_ui.port->backend_is_mock) {
        ui_set_text(s_status,hw->op_detail[0] ? hw->op_detail : "SD launcher pending");
        for(int i=0;i<MOCK_PROGRAM_COUNT;i++) { ui_button_set_enabled(s_sim_ok[i],false); ui_button_set_enabled(s_sim_fail[i],false); }
        return;
    }

    const char *name = hw->op_program < MOCK_PROGRAM_COUNT ? mock_programs[hw->op_program].name : "?";
    uint32_t col = C_TEXT;
    switch (hw->op) {
    case OP_TRANSFER:
        snprintf(b, sizeof b, "Loading %s: %u.%u%% - %s", name, (unsigned)(hw->op_permille / 10u),
                 (unsigned)(hw->op_permille % 10u), hw->op_detail);
        break;
    case OP_DONE:
        snprintf(b, sizeof b, LV_SYMBOL_OK " %s loaded (simulated) - %s", name, hw->op_detail);
        col = C_GREEN;
        break;
    case OP_FAILED:
        snprintf(b, sizeof b, LV_SYMBOL_CLOSE " %s failed - %s", name, hw->op_detail);
        col = C_RED;
        break;
    default:
        snprintf(b, sizeof b, "No transfer yet");
        break;
    }
    ui_set_text(s_status, b);
    lv_obj_set_style_text_color(s_status, lv_color_hex(col), 0);
    lv_bar_set_value(s_bar, hw->op_permille, LV_ANIM_OFF);

    /* One operation at a time, and only over a connected link. */
    bool can = g_ui.port->backend_is_mock && hw->op != OP_TRANSFER && hw->link == LINK_CONNECTED;
    for (int i = 0; i < MOCK_PROGRAM_COUNT; i++) {
        ui_button_set_enabled(s_sim_ok[i], can);
        ui_button_set_enabled(s_sim_fail[i], can);
    }
}
