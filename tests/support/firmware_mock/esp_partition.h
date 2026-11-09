#pragma once
#include <stdint.h>
#include <stddef.h>
#define ESP_OK 0
#define ESP_PARTITION_TYPE_DATA 1
#define ESP_PARTITION_SUBTYPE_DATA_FAT 0x81
typedef struct { uint32_t size; } esp_partition_t;
const esp_partition_t *esp_partition_find_first(int type, int subtype, const char *label);
int esp_partition_read(const esp_partition_t *part, size_t offset, void *out, size_t length);
