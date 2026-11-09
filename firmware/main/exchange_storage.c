/* One asynchronous MSC block operation at a time. TinyUSB callbacks never wait
 * for UART or controller storage. Writes complete only after controller fsync.
 * X1 lines: CRC32/IEEE of bytes before the final comma, eight hexadecimal digits.
 */
#include "exchange_storage.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "class/msc/msc_device.h"
#include "device/usbd_pvt.h"
#if CONFIG_WIREDKVM_FLASH_SETUP
#include "flash_setup.h"
#endif

#define BLOCK_BYTES 512U
#define IO_TIMEOUT_MS 3000
#define LEASE_MS 3000
#define STATUS_COUNT 8

typedef enum { ABSENT, PRESENT, EJECTED, OFFLINE, ERROR_STATE } media_state_t;
typedef struct {
    bool active, dispatched, ready, finishing;
    bool write;
    uint32_t generation, id, lba, offset, length;
    int64_t started;
    int32_t result;
    void *usb_buffer;
    uint8_t data[BLOCK_BYTES];
} operation_t;
typedef struct { uint32_t generation; const char *state; } status_t;
static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static media_state_t s_state;
static uint32_t s_generation, s_blocks, s_request_id, s_retired;
static bool s_usb_ready, s_prevent_removal, s_unit_attention, s_read_only;
static bool s_flash_media;
static uint32_t s_flash_read_bytes, s_flash_reported_bytes;
static int64_t s_flash_reported_at;
static int64_t s_lease;
static operation_t s_op;
static status_t s_status[STATUS_COUNT];
static unsigned s_status_head, s_status_size;
static char s_line[WK_EXCHANGE_LINE_CAPACITY];
static size_t s_line_size;
static bool s_line_start = true, s_line_exchange, s_line_overflow;

static int64_t milliseconds(void) { return esp_timer_get_time() / 1000; }
static const char *state_name(media_state_t state)
{
    switch (state) {
    case PRESENT: return "PRESENT";
    case EJECTED: return "EJECTED";
    case OFFLINE: return "OFFLINE";
    case ERROR_STATE: return "ERROR";
    default: return "ABSENT";
    }
}
static void status_locked(uint32_t generation, const char *state)
{
    if (s_status_size == STATUS_COUNT) {
        s_status_head = (s_status_head + 1) % STATUS_COUNT;
        --s_status_size;
    }
    unsigned at = (s_status_head + s_status_size++) % STATUS_COUNT;
    s_status[at] = (status_t){generation, state};
}
static void retire_locked(media_state_t state)
{
    const bool changed = s_state != state || s_blocks != 0;
    if (s_generation) s_retired = s_generation;
    s_state = state;
    s_blocks = 0;
    s_prevent_removal = false;
    s_unit_attention = false;
    s_read_only = false;
    s_flash_media = false;
    if (s_op.active && !s_op.finishing) {
        s_op.result = TUD_MSC_RET_ERROR;
        s_op.ready = true;
    }
    if (changed) status_locked(s_generation, state_name(state));
}
void wk_exchange_init(void)
{
    portENTER_CRITICAL(&s_lock);
    s_state = ABSENT;
    s_generation = s_blocks = s_request_id = s_retired = 0;
    s_usb_ready = s_prevent_removal = s_unit_attention = false;
    s_read_only = false;
    s_flash_media = false;
    s_lease = 0;
    memset(&s_op, 0, sizeof(s_op));
    s_status_head = s_status_size = 0;
    s_line_size = 0;
    s_line_start = true;
    s_line_exchange = s_line_overflow = false;
    portEXIT_CRITICAL(&s_lock);
}
void wk_exchange_usb_ready(bool ready)
{
    portENTER_CRITICAL(&s_lock);
    if (s_usb_ready && !ready && (s_state == PRESENT || s_op.active)) retire_locked(OFFLINE);
    s_usb_ready = ready;
    portEXIT_CRITICAL(&s_lock);
}
void wk_exchange_usb_attached(void)
{
    /* A new SetConfiguration is a new USB epoch, even if no unplug callback
     * was observed. Old controller responses cannot revive its old medium. */
    portENTER_CRITICAL(&s_lock);
    if (s_state == PRESENT || s_op.active) retire_locked(OFFLINE);
    s_usb_ready = true;
    portEXIT_CRITICAL(&s_lock);
}
static uint32_t crc32(const uint8_t *bytes, size_t length)
{
    uint32_t crc = UINT32_MAX;
    while (length--) {
        crc ^= *bytes++;
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ ((crc & 1U) ? UINT32_C(0xedb88320) : 0);
    }
    return ~crc;
}
static int hex_digit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static bool number(const char *s, uint32_t *out)
{
    if (!s || !*s) return false;
    uint64_t n = 0;
    for (; *s; ++s) {
        if (*s < '0' || *s > '9') return false;
        n = n * 10U + (unsigned)(*s - '0');
        if (n > UINT32_MAX) return false;
    }
    *out = (uint32_t)n;
    return true;
}
static bool decode_hex(const char *s, uint8_t *out, size_t bytes)
{
    if (strlen(s) != 2 * bytes) return false;
    for (size_t i = 0; i < bytes; ++i) {
        int hi = hex_digit(s[2 * i]), lo = hex_digit(s[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return true;
}
static void handle_line(char *line)
{
    char *last = strrchr(line, ',');
    if (!last || strlen(last + 1) != 8) return;
    uint32_t expected = 0;
    for (unsigned i = 1; i <= 8; ++i) {
        int nibble = hex_digit(last[i]);
        if (nibble < 0) return;
        expected = (expected << 4) | (unsigned)nibble;
    }
    if (crc32((const uint8_t *)line, (size_t)(last - line)) != expected) return;
    *last = 0;
    char *fields[6] = {0};
    unsigned count = 0;
    for (char *at = line; at; ) {
        if (count == 6) return;
        fields[count++] = at;
        char *comma = strchr(at, ',');
        if (comma) *comma++ = 0;
        at = comma;
    }
    uint32_t generation;
    if (count < 3 || strcmp(fields[0], "X1") || strlen(fields[1]) != 1 ||
        !number(fields[2], &generation)) return;
    const char kind = fields[1][0];
    uint32_t value = 0;
    if ((kind == 'P' || kind == 'I' || kind == 'J' || kind == 'D' || kind == 'A' || kind == 'F') &&
        (count < 4 || !number(fields[3], &value))) return;
    uint32_t image_crc = 0;
    bool flash_matches = false;
    if (kind == 'J') {
        if (count != 5 || !number(fields[4], &image_crc)) return;
#if CONFIG_WIREDKVM_FLASH_SETUP
        flash_matches = wk_flash_setup_matches(value, image_crc);
#endif
    }
    portENTER_CRITICAL(&s_lock);
    if (kind == 'Q' && count == 3 && generation == 0) {
        status_locked(s_generation, state_name(s_state));
    } else if (kind == 'J' && !flash_matches) {
        status_locked(generation, "ERROR");
    } else if ((((kind == 'P' || kind == 'I') && count == 4) || (kind == 'J' && count == 5)) && generation && value) {
        // I publishes a temporary read-only setup image. P retains the
        // original read/write exchange contract; neither replaces live media.
        const bool read_only = kind != 'P';
        const bool flash_media = kind == 'J';
        if (s_state == PRESENT) {
            status_locked(generation, s_generation == generation && s_blocks == value &&
                          s_read_only == read_only && s_flash_media == flash_media ? "PRESENT" : "BUSY");
        } else if (s_op.active) {
            status_locked(generation, "BUSY");
        } else if (!s_usb_ready) {
            status_locked(generation, "OFFLINE");
        } else if (generation == s_retired) {
            status_locked(generation, "ERROR");
        } else {
            s_generation = generation;
            s_blocks = value;
            s_state = PRESENT;
            s_read_only = read_only;
            s_flash_media = flash_media;
            s_flash_read_bytes = s_flash_reported_bytes = 0;
            s_flash_reported_at = milliseconds();
            s_unit_attention = true;
            s_prevent_removal = false;
            s_lease = milliseconds();
            status_locked(generation, "PRESENT");
        }
    } else if (kind == 'H' && count == 3 && generation == s_generation && s_state == PRESENT) {
        s_lease = milliseconds();
    } else if (kind == 'O' && count == 3 && (!generation || generation == s_generation)) {
        const bool already_absent = s_state == ABSENT && !s_blocks;
        retire_locked(ABSENT);
        if (already_absent) status_locked(s_generation, "ABSENT");
    } else if (s_op.active && s_op.dispatched && !s_op.ready && !s_op.finishing &&
               generation == s_op.generation && value == s_op.id && s_state == PRESENT) {
        if (kind == 'D' && count == 5 && !s_op.write) {
            if (decode_hex(fields[4], s_op.data, s_op.length)) {
                s_op.result = (int32_t)s_op.length;
                s_op.ready = true;
            }
        } else if (kind == 'A' && count == 4 && s_op.write) {
            s_op.result = (int32_t)s_op.length;
            s_op.ready = true;
        } else if (kind == 'F' && count == 4) {
            retire_locked(ERROR_STATE);
        }
    }
    portEXIT_CRITICAL(&s_lock);
}
bool wk_exchange_feed(uint8_t byte)
{
    if (s_line_start) {
        s_line_start = false;
        s_line_exchange = byte == 'X';
        s_line_size = 0;
        s_line_overflow = false;
    }
    const bool consumed = s_line_exchange;
    if (byte == '\n') {
        if (consumed && !s_line_overflow) {
            s_line[s_line_size] = 0;
            handle_line(s_line);
        }
        s_line_start = true;
    } else if (consumed) {
        if (s_line_size + 1 >= sizeof(s_line) || byte < 32 || byte > 126) s_line_overflow = true;
        else if (!s_line_overflow) s_line[s_line_size++] = (char)byte;
    }
    return consumed;
}
size_t wk_exchange_next_tx(char *line, size_t capacity)
{
    if (capacity < WK_EXCHANGE_LINE_CAPACITY) return 0;
    int n = 0;
    portENTER_CRITICAL(&s_lock);
    if (s_status_size) {
        status_t event = s_status[s_status_head];
        s_status_head = (s_status_head + 1) % STATUS_COUNT;
        --s_status_size;
        n = snprintf(line, capacity, "X1,S,%" PRIu32 ",%s", event.generation, event.state);
    } else if (s_flash_media && s_state == PRESENT && s_flash_read_bytes != s_flash_reported_bytes &&
               milliseconds() - s_flash_reported_at >= 500) {
        // Aggregate byte counts only, at most twice/second. No disk contents
        // traverse UART; this allows throughput checks without target access.
        n = snprintf(line, capacity, "X1,T,%" PRIu32 ",%" PRIu32, s_generation, s_flash_read_bytes);
        s_flash_reported_bytes = s_flash_read_bytes;
        s_flash_reported_at = milliseconds();
    } else if (s_op.active && !s_op.dispatched && !s_op.ready && s_state == PRESENT) {
        n = snprintf(line, capacity, "X1,%c,%" PRIu32 ",%" PRIu32 ",%" PRIu32 ",%" PRIu32 ",",
                     s_op.write ? 'W' : 'R', s_op.generation, s_op.id, s_op.lba, s_op.offset);
        if (n > 0 && (size_t)n < capacity - 12) {
            if (s_op.write) {
                static const char digits[] = "0123456789abcdef";
                for (uint32_t i = 0; i < s_op.length; ++i) {
                    line[n++] = digits[s_op.data[i] >> 4];
                    line[n++] = digits[s_op.data[i] & 15];
                }
                line[n] = 0;
            } else n += snprintf(line + n, capacity - (size_t)n, "%" PRIu32, s_op.length);
            s_op.dispatched = true;
        }
    }
    portEXIT_CRITICAL(&s_lock);
    if (n <= 0 || (size_t)n + 11 >= capacity) return 0;
    uint32_t check = crc32((const uint8_t *)line, (size_t)n);
    int suffix = snprintf(line + n, capacity - (size_t)n, ",%08" PRIx32 "\n", check);
    return suffix == 10 ? (size_t)n + (size_t)suffix : 0;
}
static void finish_cleanup(void *token)
{
    const uint32_t id = (uint32_t)(uintptr_t)token;
    portENTER_CRITICAL(&s_lock);
    if (s_op.active && s_op.finishing && s_op.id == id) memset(&s_op, 0, sizeof(s_op));
    portEXIT_CRITICAL(&s_lock);
}
void wk_exchange_poll(void)
{
    uint32_t finish_id = 0;
    int32_t result = TUD_MSC_RET_ERROR;
    portENTER_CRITICAL(&s_lock);
    const int64_t now = milliseconds();
    if (s_state == PRESENT && now - s_lease >= LEASE_MS) retire_locked(OFFLINE);
    if (s_op.active && !s_op.ready && now - s_op.started >= IO_TIMEOUT_MS) retire_locked(ERROR_STATE);
    if (s_op.active && s_op.ready && !s_op.finishing) {
        s_op.finishing = true;
        finish_id = s_op.id;
        result = s_op.result;
        if (result > 0 && (!s_usb_ready || s_state != PRESENT || s_generation != s_op.generation))
            result = TUD_MSC_RET_ERROR;
        if (result > 0 && !s_op.write) memcpy(s_op.usb_buffer, s_op.data, s_op.length);
    }
    portEXIT_CRITICAL(&s_lock);
    if (finish_id) {
        /* Keep the finishing gate until TinyUSB's deferred completion has run.
         * If reset queues a new READ before it, that READ returns BUSY and its
         * pending_io is false; stale completion cannot finish the new request. */
        (void)tud_msc_async_io_done(result, false);
        usbd_defer_func(finish_cleanup, (void *)(uintptr_t)finish_id, false);
    }
}
static int32_t request_io(uint8_t lun, uint32_t lba, uint32_t offset,
                          void *buffer, uint32_t length, bool write)
{
    int32_t result = TUD_MSC_RET_ERROR;
    bool protected_media = false;
    portENTER_CRITICAL(&s_lock);
    if (lun == 0 && write && s_usb_ready && s_state == PRESENT && s_read_only)
        protected_media = true;
    else if (s_op.finishing) result = TUD_MSC_RET_BUSY;
    else if (lun == 0 && s_usb_ready && s_state == PRESENT && lba < s_blocks &&
             length > 0 && length <= BLOCK_BYTES && offset < BLOCK_BYTES &&
             length <= BLOCK_BYTES - offset && !s_op.active) {
        if (++s_request_id == 0) ++s_request_id;
        s_op = (operation_t){.active = true, .write = write,
            .generation = s_generation, .id = s_request_id, .lba = lba,
            .offset = offset, .length = length, .started = milliseconds(), .usb_buffer = buffer};
        if (write) memcpy(s_op.data, buffer, length);
        result = TUD_MSC_RET_ASYNC;
    }
    portEXIT_CRITICAL(&s_lock);
    if (protected_media) tud_msc_set_sense(lun, SCSI_SENSE_DATA_PROTECT, 0x27, 0);
    else if (result == TUD_MSC_RET_ERROR) tud_msc_set_sense(lun, SCSI_SENSE_NOT_READY, 0x3a, 0);
    return result;
}
uint8_t tud_msc_get_maxlun_cb(void) { return 1; } /* TinyUSB expects LUN count. */
void tud_msc_inquiry_cb(uint8_t lun, uint8_t vendor[8], uint8_t product[16], uint8_t revision[4])
{
    (void)lun;
    memcpy(vendor, "WIREDKVM", 8);
    memcpy(product, "Exchange Disk   ", 16);
    memcpy(revision, "0.3 ", 4);
}
bool tud_msc_test_unit_ready_cb(uint8_t lun)
{
    bool ready, attention;
    portENTER_CRITICAL(&s_lock);
    ready = lun == 0 && s_state == PRESENT && s_usb_ready;
    attention = ready && s_unit_attention;
    if (attention) s_unit_attention = false;
    portEXIT_CRITICAL(&s_lock);
    if (attention) { tud_msc_set_sense(lun, SCSI_SENSE_UNIT_ATTENTION, 0x28, 0); return false; }
    if (!ready) tud_msc_set_sense(lun, SCSI_SENSE_NOT_READY, 0x3a, 0);
    return ready;
}
void tud_msc_capacity_cb(uint8_t lun, uint32_t *blocks, uint16_t *block_size)
{
    portENTER_CRITICAL(&s_lock);
    *blocks = lun == 0 && s_state == PRESENT && s_usb_ready ? s_blocks : 0;
    *block_size = BLOCK_BYTES;
    portEXIT_CRITICAL(&s_lock);
}
bool tud_msc_is_writable_cb(uint8_t lun)
{
    portENTER_CRITICAL(&s_lock);
    // TinyUSB uses this for MODE SENSE's WP bit as well as WRITE admission.
    bool writable = lun == 0 && s_state == PRESENT && s_usb_ready && !s_read_only;
    portEXIT_CRITICAL(&s_lock);
    return writable;
}
bool tud_msc_prevent_allow_medium_removal_cb(uint8_t lun, uint8_t prohibit, uint8_t control)
{
    (void)control;
    if (lun != 0) return false;
    portENTER_CRITICAL(&s_lock);
    s_prevent_removal = prohibit != 0;
    portEXIT_CRITICAL(&s_lock);
    return true;
}
bool tud_msc_start_stop_cb(uint8_t lun, uint8_t power, bool start, bool load_eject)
{
    (void)power;
    if (lun != 0) return false;
    bool success = true;
    portENTER_CRITICAL(&s_lock);
    if (load_eject && !start) {
        if (s_op.active || s_prevent_removal) success = false;
        else if (s_state == PRESENT) retire_locked(EJECTED);
    } else if (load_eject && start) success = s_state == PRESENT;
    portEXIT_CRITICAL(&s_lock);
    if (!success) tud_msc_set_sense(lun, SCSI_SENSE_NOT_READY, 0x53, 2);
    return success;
}
int32_t tud_msc_read10_cb(uint8_t lun, uint32_t lba, uint32_t offset, void *buffer, uint32_t length)
{
#if CONFIG_WIREDKVM_FLASH_SETUP
    portENTER_CRITICAL(&s_lock);
    bool flash = s_flash_media;
    uint32_t generation = s_generation;
    bool allowed = flash && lun == 0 && s_usb_ready && s_state == PRESENT &&
                   lba < s_blocks && offset < BLOCK_BYTES && length && length <= BLOCK_BYTES - offset;
    portEXIT_CRITICAL(&s_lock);
    if (flash) {
        bool ok = allowed && wk_flash_setup_read(lba * BLOCK_BYTES + offset, buffer, length);
        portENTER_CRITICAL(&s_lock);
        ok = ok && s_flash_media && s_usb_ready && s_state == PRESENT && generation == s_generation;
        if (ok) s_flash_read_bytes += length;
        portEXIT_CRITICAL(&s_lock);
        if (!ok) tud_msc_set_sense(lun, SCSI_SENSE_NOT_READY, 0x3a, 0);
        return ok ? (int32_t)length : TUD_MSC_RET_ERROR;
    }
#endif
    return request_io(lun, lba, offset, buffer, length, false);
}
int32_t tud_msc_write10_cb(uint8_t lun, uint32_t lba, uint32_t offset, uint8_t *buffer, uint32_t length)
{ return request_io(lun, lba, offset, buffer, length, true); }
int32_t tud_msc_scsi_cb(uint8_t lun, const uint8_t command[16], void *buffer, uint16_t size)
{
    (void)buffer; (void)size;
    /* Every WRITE was durably acknowledged before its CSW. There is no extra
     * device write cache to flush for SYNCHRONIZE CACHE(10). */
    if (lun == 0 && command[0] == 0x35) {
        portENTER_CRITICAL(&s_lock);
        bool ready = s_state == PRESENT && s_usb_ready && !s_op.active;
        portEXIT_CRITICAL(&s_lock);
        if (ready) return 0;
        tud_msc_set_sense(lun, SCSI_SENSE_NOT_READY, 0x3a, 0);
    } else tud_msc_set_sense(lun, SCSI_SENSE_ILLEGAL_REQUEST, 0x20, 0);
    return TUD_MSC_RET_ERROR;
}
