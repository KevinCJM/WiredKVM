#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_log.h"
#if WK_TEST_REAL_TINYUSB
#include "device/usbd.h"
#endif
typedef struct {
    struct {
        const uint8_t *full_speed_config;
        const char **string;
        unsigned string_count;
    } descriptor;
} tinyusb_config_t;
esp_err_t tinyusb_driver_install(const tinyusb_config_t *cfg);
