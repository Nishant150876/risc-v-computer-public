/*
 * T0 bring-up probe for the M5Stack Tab5.
 *
 * Checks the four T0 peripherals on the real device:
 *   1. Display  - colour bars you confirm by eye (red, green, blue, white).
 *   2. Touch    - tap the four numbered corner targets; each turns green.
 *   3. microSD  - mount, write 64 KiB pattern, read back, compare, keep a report.
 *   4. UART     - UART1 on PORT.A G53 (TX) / G54 (RX), 115200 8N1, known-byte
 *                 loopback. Needs a jumper between G53 and G54 only.
 *
 * Every result is also printed on the serial monitor, prefixed "T0:".
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "bsp/esp-bsp.h"
#include "driver/gpio.h"
#include "driver/uart.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lvgl.h"
#include "sdmmc_cmd.h"

static const char *TAG = "T0";

/* ---- UART under test -------------------------------------------------- */
#define PROBE_UART       UART_NUM_1
#define PROBE_UART_TX    GPIO_NUM_53
#define PROBE_UART_RX    GPIO_NUM_54
#define PROBE_UART_BAUD  115200
#define LOOP_LEN         256

/* ---- microSD test ----------------------------------------------------- */
#define SD_TEST_BYTES    (64 * 1024)
#define SD_CHUNK         4096
#define SD_BIN_PATH      BSP_SD_MOUNT_POINT "/T0PROBE.BIN"
#define SD_REPORT_PATH   BSP_SD_MOUNT_POINT "/T0PROBE.TXT"

/* ---- UI state --------------------------------------------------------- */
#define N_TARGETS 4
static lv_obj_t *s_target[N_TARGETS];
static bool      s_hit[N_TARGETS];
static int       s_hits;
static lv_obj_t *s_lbl_touch;
static lv_obj_t *s_lbl_point;
static lv_obj_t *s_lbl_sd;
static lv_obj_t *s_lbl_uart;

static void set_label(lv_obj_t *lbl, uint32_t colour, const char *text)
{
    bsp_display_lock(0);
    lv_label_set_text(lbl, text);
    lv_obj_set_style_text_color(lbl, lv_color_hex(colour), 0);
    bsp_display_unlock();
}

#define GREEN  0x30D158
#define RED    0xFF453A
#define AMBER  0xFFD60A
#define WHITE  0xFFFFFF

/* ======================================================================= */
/* Touch                                                                   */
/* ======================================================================= */

/* Called from the LVGL task, which already holds the display lock. */
static void target_cb(lv_event_t *e)
{
    int i = (int)(intptr_t)lv_event_get_user_data(e);
    if (s_hit[i]) {
        return;
    }
    s_hit[i] = true;
    s_hits++;
    lv_obj_set_style_bg_color(s_target[i], lv_color_hex(GREEN), 0);
    ESP_LOGI(TAG, "T0: touch target %d hit (%d/%d)", i + 1, s_hits, N_TARGETS);

    if (s_hits == N_TARGETS) {
        lv_label_set_text(s_lbl_touch, "TOUCH: PASS (all 4 corners)");
        lv_obj_set_style_text_color(s_lbl_touch, lv_color_hex(GREEN), 0);
        ESP_LOGI(TAG, "T0: TOUCH PASS");
    } else {
        lv_label_set_text_fmt(s_lbl_touch, "TOUCH: %d / %d corners", s_hits, N_TARGETS);
    }
}

static void screen_press_cb(lv_event_t *e)
{
    (void)e;
    lv_point_t p;
    lv_indev_t *indev = lv_indev_active();
    if (indev == NULL) {
        return;
    }
    lv_indev_get_point(indev, &p);
    lv_label_set_text_fmt(s_lbl_point, "last touch: x=%d y=%d", (int)p.x, (int)p.y);
}

/* ======================================================================= */
/* UI                                                                      */
/* ======================================================================= */

static lv_obj_t *make_label(lv_obj_t *parent, const lv_font_t *font, int x, int y, const char *text)
{
    lv_obj_t *l = lv_label_create(parent);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(WHITE), 0);
    lv_label_set_text(l, text);
    lv_obj_set_pos(l, x, y);
    return l;
}

static void build_ui(void)
{
    bsp_display_lock(0);

    lv_obj_t *scr = lv_screen_active();
    const int w = lv_display_get_horizontal_resolution(NULL);
    const int h = lv_display_get_vertical_resolution(NULL);
    ESP_LOGI(TAG, "T0: display resolution %d x %d", w, h);

    lv_obj_set_style_bg_color(scr, lv_color_hex(0x000000), 0);
    lv_obj_remove_flag(scr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(scr, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(scr, screen_press_cb, LV_EVENT_PRESSING, NULL);

    /* Display check: four bars across the middle band. */
    const uint32_t bar_col[4] = { 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF };
    const int bar_w = w / 4;
    const int bar_h = h / 6;
    const int bar_y = h / 2 - bar_h / 2;
    for (int i = 0; i < 4; i++) {
        lv_obj_t *b = lv_obj_create(scr);
        lv_obj_remove_style_all(b);
        lv_obj_set_style_bg_opa(b, LV_OPA_COVER, 0);
        lv_obj_set_style_bg_color(b, lv_color_hex(bar_col[i]), 0);
        lv_obj_set_size(b, bar_w, bar_h);
        lv_obj_set_pos(b, i * bar_w, bar_y);
        lv_obj_remove_flag(b, LV_OBJ_FLAG_CLICKABLE);
    }

    /* Touch check: four numbered targets in the corners. */
    const int t = (w < h ? w : h) / 6;
    const int pos[N_TARGETS][2] = {
        { 0, 0 }, { w - t, 0 }, { 0, h - t }, { w - t, h - t },
    };
    for (int i = 0; i < N_TARGETS; i++) {
        lv_obj_t *o = lv_obj_create(scr);
        lv_obj_remove_style_all(o);
        lv_obj_set_style_bg_opa(o, LV_OPA_COVER, 0);
        lv_obj_set_style_bg_color(o, lv_color_hex(0x3A3A3C), 0);
        lv_obj_set_size(o, t, t);
        lv_obj_set_pos(o, pos[i][0], pos[i][1]);
        lv_obj_add_flag(o, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_add_event_cb(o, target_cb, LV_EVENT_PRESSED, (void *)(intptr_t)i);
        lv_obj_t *n = lv_label_create(o);
        lv_obj_set_style_text_font(n, &lv_font_montserrat_26, 0);
        lv_obj_set_style_text_color(n, lv_color_hex(WHITE), 0);
        lv_label_set_text_fmt(n, "%d", i + 1);
        lv_obj_center(n);
        s_target[i] = o;
    }

    /* Status text between the top targets and the bars. */
    const int x0 = t + 20;
    const int line = 40;
    make_label(scr, &lv_font_montserrat_26, x0, 10, "Tab5 T0 probe");
    make_label(scr, &lv_font_montserrat_20, x0, 10 + line,
               "DISPLAY: bars should read red, green, blue, white");
    s_lbl_touch = make_label(scr, &lv_font_montserrat_20, x0, 10 + 2 * line,
                             "TOUCH: tap corners 1-4");
    s_lbl_sd    = make_label(scr, &lv_font_montserrat_20, x0, 10 + 3 * line, "SD: waiting");
    s_lbl_uart  = make_label(scr, &lv_font_montserrat_20, x0, 10 + 4 * line, "UART: waiting");
    s_lbl_point = make_label(scr, &lv_font_montserrat_20, x0, bar_y + bar_h + 20, "last touch: none");
    lv_obj_set_style_text_color(s_lbl_sd, lv_color_hex(AMBER), 0);
    lv_obj_set_style_text_color(s_lbl_uart, lv_color_hex(AMBER), 0);

    bsp_display_unlock();
}

/* ======================================================================= */
/* microSD                                                                 */
/* ======================================================================= */

static uint32_t xorshift32(uint32_t *s)
{
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return *s = x;
}

static void fill_chunk(uint8_t *buf, uint32_t *seed)
{
    for (int i = 0; i < SD_CHUNK; i += 4) {
        uint32_t v = xorshift32(seed);
        memcpy(&buf[i], &v, 4);
    }
}

static void sd_task(void *arg)
{
    (void)arg;
    char msg[160];
    static uint8_t wbuf[SD_CHUNK];
    static uint8_t rbuf[SD_CHUNK];

    esp_err_t err = bsp_sdcard_mount();
    if (err != ESP_OK) {
        snprintf(msg, sizeof msg, "SD: FAIL mount (%s) - card inserted? FAT32?", esp_err_to_name(err));
        ESP_LOGE(TAG, "T0: %s", msg);
        set_label(s_lbl_sd, RED, msg);
        vTaskDelete(NULL);
        return;
    }

    sdmmc_card_t *card = bsp_sdcard_get_handle();
    if (card) {
        sdmmc_card_print_info(stdout, card);
    }

    /* Write pass */
    uint32_t seed = 0x1234ABCDu;
    int64_t t0 = esp_timer_get_time();
    FILE *f = fopen(SD_BIN_PATH, "wb");
    bool ok = (f != NULL);
    for (int n = 0; ok && n < SD_TEST_BYTES / SD_CHUNK; n++) {
        fill_chunk(wbuf, &seed);
        ok = fwrite(wbuf, 1, SD_CHUNK, f) == SD_CHUNK;
    }
    if (f) {
        fflush(f);
        fsync(fileno(f));
        fclose(f);
    }
    int64_t t1 = esp_timer_get_time();

    /* Read-back pass */
    int bad_at = -1;
    if (ok) {
        seed = 0x1234ABCDu;
        f = fopen(SD_BIN_PATH, "rb");
        ok = (f != NULL);
        for (int n = 0; ok && n < SD_TEST_BYTES / SD_CHUNK; n++) {
            fill_chunk(wbuf, &seed);
            ok = fread(rbuf, 1, SD_CHUNK, f) == SD_CHUNK;
            if (ok && memcmp(wbuf, rbuf, SD_CHUNK) != 0) {
                bad_at = n * SD_CHUNK;
                ok = false;
            }
        }
        if (f) {
            fclose(f);
        }
    }
    int64_t t2 = esp_timer_get_time();
    remove(SD_BIN_PATH);

    if (ok) {
        snprintf(msg, sizeof msg, "SD: PASS 64 KiB write+verify (wr %lld ms, rd %lld ms)",
                 (long long)((t1 - t0) / 1000), (long long)((t2 - t1) / 1000));
        set_label(s_lbl_sd, GREEN, msg);
    } else if (bad_at >= 0) {
        snprintf(msg, sizeof msg, "SD: FAIL data mismatch near byte %d", bad_at);
        set_label(s_lbl_sd, RED, msg);
    } else {
        snprintf(msg, sizeof msg, "SD: FAIL file open/read/write error");
        set_label(s_lbl_sd, RED, msg);
    }
    ESP_LOGI(TAG, "T0: %s", msg);

    /* Leave a small report on the card as evidence. */
    FILE *r = fopen(SD_REPORT_PATH, "w");
    if (r) {
        fprintf(r, "Tab5 T0 probe\n%s\n", msg);
        if (card) {
            fprintf(r, "card: %s, %llu MB\n", card->cid.name,
                    (unsigned long long)card->csd.capacity * card->csd.sector_size / (1024 * 1024));
        }
        fclose(r);
        ESP_LOGI(TAG, "T0: report written to %s", SD_REPORT_PATH);
    }

    bsp_sdcard_unmount();
    vTaskDelete(NULL);
}

/* ======================================================================= */
/* UART loopback                                                           */
/* ======================================================================= */

static void uart_task(void *arg)
{
    (void)arg;
    const uart_config_t cfg = {
        .baud_rate  = PROBE_UART_BAUD,
        .data_bits  = UART_DATA_8_BITS,
        .parity     = UART_PARITY_DISABLE,
        .stop_bits  = UART_STOP_BITS_1,
        .flow_ctrl  = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    ESP_ERROR_CHECK(uart_driver_install(PROBE_UART, 1024, 0, 0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(PROBE_UART, &cfg));
    ESP_ERROR_CHECK(uart_set_pin(PROBE_UART, PROBE_UART_TX, PROBE_UART_RX,
                                 UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
    gpio_pullup_en(PROBE_UART_RX); /* idle high when nothing is connected */

    uint8_t tx[LOOP_LEN];
    uint8_t rx[LOOP_LEN];
    for (int i = 0; i < LOOP_LEN; i++) {
        tx[i] = (uint8_t)i;
    }

    int pass = 0, runs = 0;
    char msg[128];
    for (;;) {
        uart_flush_input(PROBE_UART);
        uart_write_bytes(PROBE_UART, tx, LOOP_LEN);
        uart_wait_tx_done(PROBE_UART, pdMS_TO_TICKS(200));
        int got = uart_read_bytes(PROBE_UART, rx, LOOP_LEN, pdMS_TO_TICKS(200));
        runs++;

        if (got == LOOP_LEN && memcmp(tx, rx, LOOP_LEN) == 0) {
            pass++;
            snprintf(msg, sizeof msg, "UART: PASS loopback G53->G54, %d/%d runs", pass, runs);
            set_label(s_lbl_uart, GREEN, msg);
        } else if (got <= 0) {
            snprintf(msg, sizeof msg, "UART: no echo - fit jumper G53<->G54 (%d/%d)", pass, runs);
            set_label(s_lbl_uart, AMBER, msg);
        } else {
            int first = 0;
            while (first < got && rx[first] == tx[first]) {
                first++;
            }
            snprintf(msg, sizeof msg, "UART: FAIL got %d/%d bytes, first bad at %d", got, LOOP_LEN, first);
            set_label(s_lbl_uart, RED, msg);
        }
        ESP_LOGI(TAG, "T0: %s", msg);
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

/* ======================================================================= */

void app_main(void)
{
    ESP_LOGI(TAG, "T0: probe start; look above for the BSP 'Discovered board version' line");

    bsp_display_start();
    bsp_display_backlight_on();
    build_ui();

    xTaskCreate(sd_task, "t0_sd", 6144, NULL, 4, NULL);
    xTaskCreate(uart_task, "t0_uart", 4096, NULL, 4, NULL);
}
