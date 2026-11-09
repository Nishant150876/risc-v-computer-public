idf_component_register(SRCS "t0_probe.c"
                       INCLUDE_DIRS "."
                       REQUIRES driver esp_driver_uart fatfs sdmmc)
