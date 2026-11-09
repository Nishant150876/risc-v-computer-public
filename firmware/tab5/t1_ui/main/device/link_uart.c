/* UART belongs to this worker. UI callbacks only enqueue commands. */
#include "link_uart.h"
#include "driver/uart.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "sdkconfig.h"
#include <string.h>
#include <stdio.h>

#if CONFIG_T1_BACKEND_UART
static const char *TAG="tab5_link";
static QueueHandle_t commands,events;
static link_emit_fn output;
static void *output_ctx;
static link_device_t device;
static uint8_t pending[DBL_MAX_WIRE];
static size_t pending_length,pending_offset;
static uint32_t now_ms(void) { return (uint32_t)(esp_timer_get_time()/1000); }
static bool enqueue(void *ctx,const uint8_t *wire,size_t n)
{
    (void)ctx;
    if(pending_length!=0 || n>sizeof pending) return false;
    memcpy(pending,wire,n); pending_length=n; pending_offset=0; return true;
}
static void emit(void *ctx,const dev_msg_t *message) { (void)ctx; output(output_ctx,message); }
static void link_error(const char *reason)
{
    if(device.phase==LD_COMMAND) device.uncertain=true;
    pending_length=pending_offset=0;
    device.phase=LD_ERROR; device.connected=false; device.rejected++;
    dev_msg_t m={.type=MSG_LINK,.t_ms=now_ms()}; m.u.link.state=LINK_ERROR;
    snprintf(m.u.link.reason,sizeof m.u.link.reason,"%s",reason); output(output_ctx,&m);
}
static void drain_tx(void)
{
    if(pending_length==0) return;
    int n=uart_tx_chars(UART_NUM_1,(const char *)pending+pending_offset,pending_length-pending_offset);
    if(n<0) { link_error("UART TX error; reconcile"); return; }
    pending_offset+=(size_t)n;
    if(pending_offset==pending_length) pending_offset=pending_length=0;
}
static void worker(void *ctx)
{
    (void)ctx;
    uint64_t session=(uint64_t)esp_random()<<32 | esp_random();
    link_device_init(&device,session,now_ms(),enqueue,emit,NULL);
    for(;;) {
        uart_event_t event;
        for(unsigned i=0;i<8 && xQueueReceive(events,&event,0)==pdTRUE;i++) {
            if(event.type==UART_FIFO_OVF || event.type==UART_BUFFER_FULL || event.type==UART_FRAME_ERR || event.type==UART_PARITY_ERR) {
                if(device.phase==LD_COMMAND) device.uncertain=true;
                uart_flush_input(UART_NUM_1); dbl_rx_init(&device.rx,DBL_INTERBYTE_TIMEOUT_MS);
                link_error("UART overflow/framing; reconnect");
            }
        }
        uint8_t bytes[128];
        for(unsigned i=0;i<4;i++) {
            int n=uart_read_bytes(UART_NUM_1,bytes,sizeof bytes,0);
            if(n<0) { link_error("UART RX error"); break; }
            if(n==0) break;
            link_device_feed(&device,bytes,(size_t)n,now_ms());
        }
        ui_cmd_t command;
        for(unsigned i=0;i<8 && xQueueReceive(commands,&command,0)==pdTRUE;i++)
            if(!link_device_command(&device,&command,now_ms())) ESP_LOGW(TAG,"command %u refused (busy/capability/reconcile)",(unsigned)command.type);
        drain_tx(); link_device_tick(&device,now_ms()); drain_tx();
        vTaskDelay(pdMS_TO_TICKS(5)>0 ? pdMS_TO_TICKS(5) : 1);
    }
}
bool link_uart_start(QueueHandle_t queue,link_emit_fn emit_message,void *ctx,TaskHandle_t *task)
{
    commands=queue; output=emit_message; output_ctx=ctx;
    if(CONFIG_T1_DEBUG_TX_GPIO<0 || CONFIG_T1_DEBUG_RX_GPIO<0 || CONFIG_T1_DEBUG_TX_GPIO==CONFIG_T1_DEBUG_RX_GPIO) {
        link_error("Debug pins unassigned; verify T0 first"); return false;
    }
    uart_config_t config={.baud_rate=115200,.data_bits=UART_DATA_8_BITS,.parity=UART_PARITY_DISABLE,
        .stop_bits=UART_STOP_BITS_1,.flow_ctrl=UART_HW_FLOWCTRL_DISABLE,.source_clk=UART_SCLK_DEFAULT};
    esp_err_t err=uart_driver_install(UART_NUM_1,2048,0,8,&events,0);
    if(err==ESP_OK) err=uart_param_config(UART_NUM_1,&config);
    if(err==ESP_OK) err=uart_set_pin(UART_NUM_1,CONFIG_T1_DEBUG_TX_GPIO,CONFIG_T1_DEBUG_RX_GPIO,UART_PIN_NO_CHANGE,UART_PIN_NO_CHANGE);
    if(err!=ESP_OK) { ESP_LOGE(TAG,"UART init: %s",esp_err_to_name(err)); link_error("UART setup failed"); return false; }
    if(xTaskCreate(worker,"tab5_link",6144,NULL,3,task)!=pdPASS) { link_error("Link worker allocation failed"); return false; }
    ESP_LOGI(TAG,"Dedicated debug UART1, 115200 8N1, TX%d RX%d; no MOCK fallback",CONFIG_T1_DEBUG_TX_GPIO,CONFIG_T1_DEBUG_RX_GPIO);
    return true;
}
#else
bool link_uart_start(QueueHandle_t queue,link_emit_fn emit_message,void *ctx,TaskHandle_t *task)
{
    (void)queue; (void)emit_message; (void)ctx; (void)task; return false;
}
#endif
