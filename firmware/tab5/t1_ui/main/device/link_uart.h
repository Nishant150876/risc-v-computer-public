#ifndef LINK_UART_H
#define LINK_UART_H
#include "link_device.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
bool link_uart_start(QueueHandle_t commands, link_emit_fn emit, void *ctx, TaskHandle_t *task);
#endif
