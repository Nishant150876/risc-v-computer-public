/*
 * Tab5 UI, milestone T1: responsive touchscreen UI with labelled MOCK data.
 *
 * Tasks (TAB5_FIRMWARE.md section 3):
 *   taskLVGL  - from esp_lvgl_port; the only task that touches LVGL. Runs the
 *               UI, which drains the message queue at 5 Hz.
 *   t1_mock   - the MOCK device backend. Reads UI commands, produces
 *               immutable snapshot/console/link messages.
 *   t1_stats  - prints "T1:" measurement lines every 5 s for the gate record.
 *
 * The two queues are bounded and never block the UI: a full message queue
 * drops the message and counts it; a full command queue refuses the tap.
 */
#include <stdio.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_app_desc.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "lvgl.h"

#include "device/mock_device.h"
#include "device/link_uart.h"
#include "port/ui_port.h"
#include "state/app_state.h"
#include "ui/ui.h"

static const char *TAG = "T1";

#define MSG_QUEUE_LEN   32
#define CMD_QUEUE_LEN   8
#define MOCK_PERIOD_MS  20
#define LVGL_STACK      (12 * 1024)
#define MOCK_STACK      4096

static QueueHandle_t s_msg_q;
static QueueHandle_t s_cmd_q;
static TaskHandle_t  s_mock_task;
static TaskHandle_t  s_lvgl_task;
static volatile uint32_t s_msg_drops;
static volatile uint32_t s_msg_peak;
static app_state_t   s_state;   /* owned by the LVGL task after ui_init() */
static char          s_build[48];

/* ---- ui_port_t for the Tab5 ------------------------------------------- */
static uint32_t port_now_ms(void) { return (uint32_t)(esp_timer_get_time() / 1000); }
static uint64_t port_now_us(void) { return (uint64_t)esp_timer_get_time(); }

static bool port_send_cmd(const ui_cmd_t *c)
{
    return xQueueSend(s_cmd_q, c, 0) == pdTRUE;
}

static bool port_recv_msg(dev_msg_t *m)
{
    return xQueueReceive(s_msg_q, m, 0) == pdTRUE;
}

static void port_get_stats(port_stats_t *o)
{
    o->free_heap = (uint32_t)esp_get_free_heap_size();
    o->min_free_heap = (uint32_t)esp_get_minimum_free_heap_size();
    o->free_internal = (uint32_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    o->free_psram = (uint32_t)heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    o->worker_stack_free = s_mock_task ? (uint32_t)uxTaskGetStackHighWaterMark(s_mock_task) : 0;
    o->ui_stack_free = s_lvgl_task ? (uint32_t)uxTaskGetStackHighWaterMark(s_lvgl_task) : 0;
    o->msg_queue_drops = s_msg_drops;
    o->msg_queue_peak = s_msg_peak;
}

static ui_port_t s_port = {
    .now_ms = port_now_ms,
    .now_us = port_now_us,
    .send_cmd = port_send_cmd,
    .recv_msg = port_recv_msg,
    .get_stats = port_get_stats,
    .build_info = s_build,
    .platform = "M5Stack Tab5 (ESP32-P4)",
#if CONFIG_T1_BACKEND_UART
    .backend_is_mock = false,
#else
    .backend_is_mock = true,
#endif
};

/* ---- MOCK backend task ------------------------------------------------ */
static void emit(void *ctx, const dev_msg_t *m)
{
    (void)ctx;
    if (xQueueSend(s_msg_q, m, 0) != pdTRUE) {
        s_msg_drops++;
    }
    UBaseType_t n = uxQueueMessagesWaiting(s_msg_q);
    if (n > s_msg_peak) {
        s_msg_peak = n;
    }
}

#if !CONFIG_T1_BACKEND_UART
static void mock_task(void *arg)
{
    (void)arg;
    mock_device_t dev;
    mock_device_init(&dev, port_now_ms());
    for (;;) {
        ui_cmd_t c;
        /* Waiting on the command queue is also the task's sleep. */
        while (xQueueReceive(s_cmd_q, &c, pdMS_TO_TICKS(MOCK_PERIOD_MS)) == pdTRUE) {
            mock_device_command(&dev, &c, port_now_ms(), emit, NULL);
            ESP_LOGI(TAG, "T1: sim command %d arg %lu", (int)c.type, (unsigned long)c.arg);
        }
        mock_device_step(&dev, port_now_ms(), emit, NULL);
    }
}
#endif

/* ---- Measurement log -------------------------------------------------- */
static void stats_task(void *arg)
{
    (void)arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        port_stats_t ps;
        ui_metrics_t m;
        port_get_stats(&ps);
        bsp_display_lock(0);
        ui_get_metrics(&m);
        int screen = s_state.screen;
        int mode = (int)s_state.mode;
        uint32_t hash = hw_model_hash(&s_state.hw);
        bsp_display_unlock();
        ESP_LOGI(TAG, "T1: heap free %lu min %lu internal %lu psram %lu | stack free worker %lu lvgl %lu",
                 (unsigned long)ps.free_heap, (unsigned long)ps.min_free_heap,
                 (unsigned long)ps.free_internal, (unsigned long)ps.free_psram,
                 (unsigned long)ps.worker_stack_free, (unsigned long)ps.ui_stack_free);
        ESP_LOGI(TAG, "T1: frame last %lu us max %lu us | touch->frame last %lu ms max %lu ms (%lu taps)"
                      " | msg drops %lu peak %lu | cmd refused %lu | screen %d mode %d model %08lx",
                 (unsigned long)m.render_last_us, (unsigned long)m.render_max_us,
                 (unsigned long)m.touch_last_ms, (unsigned long)m.touch_max_ms,
                 (unsigned long)m.touch_samples, (unsigned long)ps.msg_queue_drops,
                 (unsigned long)ps.msg_queue_peak, (unsigned long)m.cmd_refused, screen, mode,
                 (unsigned long)hash);
    }
}

/* ---- Start-up --------------------------------------------------------- */
/* Runs once inside taskLVGL, so it can record that task's handle for the
 * stack measurement without depending on the task's name. */
static void grab_lvgl_task(lv_timer_t *t)
{
    (void)t;
    s_lvgl_task = xTaskGetCurrentTaskHandle();
}

static lv_display_rotation_t rotation(void)
{
#if CONFIG_T1_UI_ROTATION_90
    return LV_DISPLAY_ROTATION_90;
#elif CONFIG_T1_UI_ROTATION_180
    return LV_DISPLAY_ROTATION_180;
#elif CONFIG_T1_UI_ROTATION_270
    return LV_DISPLAY_ROTATION_270;
#else
    return LV_DISPLAY_ROTATION_0;
#endif
}

void app_main(void)
{
    const esp_app_desc_t *app = esp_app_get_description();
    snprintf(s_build, sizeof s_build, "t1_ui %.20s %.11s", app->version, app->date);
    ESP_LOGI(TAG, "T1: start, %s", s_build);

    s_msg_q = xQueueCreate(MSG_QUEUE_LEN, sizeof(dev_msg_t));
    s_cmd_q = xQueueCreate(CMD_QUEUE_LEN, sizeof(ui_cmd_t));
    configASSERT(s_msg_q && s_cmd_q);

    /* Same as bsp_display_start(), with a bigger LVGL stack. */
    bsp_display_cfg_t cfg = {
        .lvgl_port_cfg = ESP_LVGL_PORT_INIT_CONFIG(),
        .buffer_size = BSP_LCD_H_RES * CONFIG_BSP_LCD_DRAW_BUF_HEIGHT,
#if CONFIG_BSP_LCD_DRAW_BUF_DOUBLE
        .double_buffer = 1,
#else
        .double_buffer = 0,
#endif
        .flags = {
            .buff_dma = true,
            .buff_spiram = false,
            .sw_rotate = true,
        },
    };
    cfg.lvgl_port_cfg.task_stack = LVGL_STACK;
    lv_display_t *disp = bsp_display_start_with_config(&cfg);
    configASSERT(disp);
    bsp_display_backlight_on();

    app_state_init(&s_state);

    bsp_display_lock(0);
    bsp_display_rotate(disp, rotation());
    ESP_LOGI(TAG, "T1: display %ld x %ld after rotation",
             (long)lv_display_get_horizontal_resolution(disp),
             (long)lv_display_get_vertical_resolution(disp));
    ui_init(&s_state, &s_port);
    lv_timer_t *t = lv_timer_create(grab_lvgl_task, 0, NULL);
    lv_timer_set_repeat_count(t, 1);
    bsp_display_unlock();

#if CONFIG_T1_BACKEND_UART
    link_uart_start(s_cmd_q,emit,NULL,&s_mock_task);
#else
    xTaskCreate(mock_task, "t1_mock", MOCK_STACK, NULL, 3, &s_mock_task);
#endif
    xTaskCreate(stats_task, "t1_stats", 3072, NULL, 2, NULL);
}
