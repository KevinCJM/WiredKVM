#pragma once
#define ESP_LOGI(tag, ...) ((void)(tag))
#define ESP_LOGW(tag, ...) ((void)(tag))
#define ESP_LOGE(tag, ...) ((void)(tag))
#define ESP_OK 0
typedef int esp_err_t;
#define ESP_ERROR_CHECK(value) ((void)(value))
