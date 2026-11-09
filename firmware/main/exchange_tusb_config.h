#pragma once
/* Enable only the upstream MSC class. The esp_tinyusb storage wrapper owns
 * strong local-FAT callbacks and must stay disabled for this UART-backed LUN. */
#include "sdkconfig.h"
#undef CONFIG_TINYUSB_MSC_ENABLED
#define CONFIG_TINYUSB_MSC_ENABLED 1
#undef CONFIG_TINYUSB_MSC_BUFSIZE
#define CONFIG_TINYUSB_MSC_BUFSIZE 512
#include "tusb_config.h"
