// Synthetic partition and deferred validator; never touches a physical board.
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include "esp_partition.h"
#include "flash_setup.h"
static unsigned char *bytes;
static size_t size;
static esp_partition_t partition;
static bool fail_read, detach_on_read;
static void (*pending)(void *);
static unsigned reads, yields;
void wk_exchange_usb_ready(bool ready);
void fs_configure(const void *data, unsigned count)
{
    free(bytes); bytes = count ? malloc(count) : NULL; size = count;
    if (count) memcpy(bytes, data, count);
    partition.size = count; fail_read = detach_on_read = false; reads = yields = 0;
}
void fs_fail_read(bool value) { fail_read = value; }
void fs_detach_on_read(void) { detach_on_read = true; }
void fs_partition_size(unsigned value) { partition.size = value; }
unsigned fs_reads(void) { return reads; }
unsigned fs_yields(void) { return yields; }
const esp_partition_t *esp_partition_find_first(int type, int subtype, const char *label)
{
    return bytes && type == ESP_PARTITION_TYPE_DATA && subtype == ESP_PARTITION_SUBTYPE_DATA_FAT &&
        !strcmp(label, "installer") ? &partition : NULL;
}
int esp_partition_read(const esp_partition_t *part, size_t offset, void *out, size_t length)
{
    ++reads;
    if (detach_on_read) { detach_on_read = false; wk_exchange_usb_ready(false); }
    if (part != &partition || fail_read || offset > size || length > size - offset) return -1;
    memcpy(out, bytes + offset, length); return ESP_OK;
}
int xTaskCreate(void (*task)(void *), const char *name, unsigned stack,
                void *arg, unsigned priority, void *handle)
{
    (void)name; (void)stack; (void)arg; (void)priority; (void)handle;
    pending = task; return 1;
}
void vTaskDelete(void *task) { (void)task; }
void wk_test_task_yield(void) { ++yields; }
void fs_validate(void) { if (pending) { void (*task)(void *) = pending; pending = NULL; task(NULL); } }
