/* About: a static, locally stored explanation of the project. This screen
 * explains the design; it is not a capture of anything. */
#include "ui_internal.h"

static lv_obj_t *section(lv_obj_t *parent, const char *title, const char *body)
{
    lv_obj_t *p = ui_panel(parent, title, NULL);
    lv_obj_set_width(p, LV_PCT(100));
    lv_obj_t *b = lv_obj_get_child(lv_obj_get_child(p, 0), 1);
    lv_label_set_text(b, "EXPLANATION");
    lv_obj_set_style_text_color(b, lv_color_hex(C_ACCENT), 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(0x0F2238), 0);
    lv_obj_t *n = ui_note(p, body);
    lv_obj_set_style_text_font(n, F_LABEL, 0);
    lv_obj_set_style_text_color(n, lv_color_hex(C_TEXT), 0);
    return p;
}

void scr_about_create(lv_obj_t *parent)
{
    section(parent, "What this is",
            "A RISC-V computer built from scratch: a 5-stage pipelined RV32I CPU written in "
            "SystemVerilog, running on a Basys 3 (Artix-7) FPGA with block-RAM memory, a UART "
            "console and VGA output. It runs C programs compiled with GCC.");
    section(parent, "What the Tab5 does",
            "The Tab5 is the portable control panel. It will load programs from microSD, show "
            "the CPU's console output, and read registers and performance counters over a "
            "framed debug link. The CPU itself always runs on the FPGA, never on the Tab5.");
    section(parent, "Where it stands",
            "CPU: single-cycle and 5-stage pipeline both pass their tests and run on the board "
            "(pipeline at 62.5 MHz, CPI about 1.3 measured on the board). Tab5: board bring-up (T0) and "
            "this user interface with MOCK data (T1). The live debug link is next (T2).");
    section(parent, "Who built it",
            "FPGA CPU, test benches, programs and Tab5 firmware designed and built by Nishant.");
}
