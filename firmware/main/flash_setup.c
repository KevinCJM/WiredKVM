#include "flash_setup.h"
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include "esp_partition.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define IMAGE_OFFSET 4096U
#define MAX_IMAGE_BYTES (12U * 1024U * 1024U - IMAGE_OFFSET)
static const esp_partition_t *s_partition;
static uint32_t s_bytes, s_crc;
static volatile bool s_ready;
static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;

static uint32_t read32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint32_t step(uint32_t value, const uint8_t *data, size_t size, const uint32_t table[256])
{
    while (size--) value = table[(value ^ *data++) & 255U] ^ (value >> 8);
    return value;
}
static void validate_task(void *unused)
{
    (void)unused;
    uint8_t header[24];
    uint8_t *buffer = NULL;
    uint32_t *table = NULL;
    const esp_partition_t *partition = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_FAT, "installer");
    if (!partition || partition->size < IMAGE_OFFSET ||
        esp_partition_read(partition, 0, header, sizeof(header)) != ESP_OK ||
        memcmp(header, "WKSETUP1", 8) || read32(header + 8) != 1) goto finished;
    uint32_t bytes = read32(header + 12), expected = read32(header + 16);
    if (!bytes || bytes % 512 || bytes > MAX_IMAGE_BYTES || bytes > partition->size - IMAGE_OFFSET) goto finished;
    buffer = malloc(4096); table = malloc(256 * sizeof(uint32_t));
    if (!buffer || !table) goto finished;
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t v = i;
        for (unsigned bit = 0; bit < 8; ++bit) v = (v >> 1) ^ ((v & 1U) ? 0xedb88320U : 0);
        table[i] = v;
    }
    if (~step(0xffffffffU, header, 20, table) != read32(header + 20)) goto finished;
    uint32_t crc = 0xffffffffU;
    for (uint32_t offset = 0; offset < bytes; ) {
        uint32_t count = bytes - offset > 4096 ? 4096 : bytes - offset;
        if (esp_partition_read(partition, IMAGE_OFFSET + offset, buffer, count) != ESP_OK) goto finished;
        crc = step(crc, buffer, count, table); offset += count;
        taskYIELD(); // USB/HID and the UART owner always get to run.
    }
    if (~crc != expected) goto finished;
    portENTER_CRITICAL(&s_lock);
    s_partition = partition; s_bytes = bytes; s_crc = expected; s_ready = true;
    portEXIT_CRITICAL(&s_lock);
finished:
    free(buffer); free(table); vTaskDelete(NULL);
}
void wk_flash_setup_init(void)
{
    portENTER_CRITICAL(&s_lock);
    s_ready = false; s_partition = NULL; s_bytes = s_crc = 0;
    portEXIT_CRITICAL(&s_lock);
    // An absent/corrupt image or allocation failure cannot stop HID startup.
    (void)xTaskCreate(validate_task, "wk_setup_check", 4096, NULL, 1, NULL);
}
bool wk_flash_setup_matches(uint32_t blocks, uint32_t crc)
{
    portENTER_CRITICAL(&s_lock);
    bool match = s_ready && blocks == s_bytes / 512 && crc == s_crc;
    portEXIT_CRITICAL(&s_lock);
    return match;
}
bool wk_flash_setup_read(uint32_t offset, void *buffer, uint32_t length)
{
    portENTER_CRITICAL(&s_lock);
    const esp_partition_t *partition = s_partition;
    bool valid = s_ready && buffer && length && offset <= s_bytes && length <= s_bytes - offset;
    portEXIT_CRITICAL(&s_lock);
    return valid && esp_partition_read(partition, IMAGE_OFFSET + offset, buffer, length) == ESP_OK;
}
