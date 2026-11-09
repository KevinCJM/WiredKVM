#include "clipboard_channel.h"
#include <string.h>
#include "freertos/FreeRTOS.h"

typedef struct {
    uint8_t data[WK_CLIPBOARD_QUEUE_DEPTH][WK_CLIPBOARD_REPORT_BYTES];
    unsigned head, count;
} packet_queue_t;
static portMUX_TYPE s_clipboard_lock = portMUX_INITIALIZER_UNLOCKED;
static packet_queue_t s_to_usb, s_to_uart;
static uint64_t s_clipboard_epoch;
/* Parser state is owned exclusively by the UART task. USB lifecycle callbacks
 * advance the epoch without touching this partial line across tasks. */
static char s_clipboard_line[WK_CLIPBOARD_LINE_CAPACITY];
static size_t s_clipboard_line_size;
static uint64_t s_clipboard_line_epoch;
static bool s_clipboard_line_start = true, s_clipboard_line_owned, s_clipboard_overflow;

static uint32_t clipboard_crc32(const uint8_t *bytes, size_t length)
{
    uint32_t crc = UINT32_MAX;
    for (size_t i = 0; i < length; ++i) {
        crc ^= bytes[i];
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ ((crc & 1U) ? UINT32_C(0xedb88320) : 0U);
    }
    return crc ^ UINT32_MAX;
}

static bool queue_push_locked(packet_queue_t *queue, const uint8_t *report)
{
    if (queue->count == WK_CLIPBOARD_QUEUE_DEPTH) return false;
    const unsigned tail = (queue->head + queue->count) % WK_CLIPBOARD_QUEUE_DEPTH;
    memcpy(queue->data[tail], report, WK_CLIPBOARD_REPORT_BYTES);
    ++queue->count;
    return true;
}

static bool queue_push(packet_queue_t *queue, const uint8_t *report)
{
    portENTER_CRITICAL(&s_clipboard_lock);
    const bool accepted = queue_push_locked(queue, report);
    portEXIT_CRITICAL(&s_clipboard_lock);
    return accepted;
}

static bool queue_pop(packet_queue_t *queue, uint8_t *report)
{
    bool available = false;
    portENTER_CRITICAL(&s_clipboard_lock);
    if (queue->count) {
        memcpy(report, queue->data[queue->head], WK_CLIPBOARD_REPORT_BYTES);
        queue->head = (queue->head + 1U) % WK_CLIPBOARD_QUEUE_DEPTH;
        --queue->count;
        available = true;
    }
    portEXIT_CRITICAL(&s_clipboard_lock);
    return available;
}

void wk_clipboard_clear(void)
{
    portENTER_CRITICAL(&s_clipboard_lock);
    s_to_usb.head = s_to_usb.count = 0;
    s_to_uart.head = s_to_uart.count = 0;
    ++s_clipboard_epoch;
    portEXIT_CRITICAL(&s_clipboard_lock);
}

void wk_clipboard_init(void)
{
    wk_clipboard_clear();
    s_clipboard_line_size = 0;
    s_clipboard_line_start = true;
    s_clipboard_line_owned = s_clipboard_overflow = false;
}

static int lower_hex(char value)
{
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    return -1;
}

static void accept_clipboard_line(void)
{
    /* C1,<128 lowercase hex>,<8 lowercase CRC32>; the CRC covers the raw
     * 64-byte report, not the serial text. A newline is handled by feed(). */
    if (s_clipboard_line_size != WK_CLIPBOARD_FRAME_BYTES - 1U ||
        memcmp(s_clipboard_line, "C1,", 3) || s_clipboard_line[131] != ',') return;
    uint8_t report[WK_CLIPBOARD_REPORT_BYTES];
    for (size_t i = 0; i < sizeof(report); ++i) {
        int high = lower_hex(s_clipboard_line[3 + i * 2]);
        int low = lower_hex(s_clipboard_line[4 + i * 2]);
        if (high < 0 || low < 0) return;
        report[i] = (uint8_t)((high << 4) | low);
    }
    uint32_t expected = 0;
    for (unsigned i = 132; i < 140; ++i) {
        int digit = lower_hex(s_clipboard_line[i]);
        if (digit < 0) return;
        expected = (expected << 4) | (uint32_t)digit;
    }
    if (clipboard_crc32(report, sizeof(report)) != expected) return;
    portENTER_CRITICAL(&s_clipboard_lock);
    if (s_clipboard_line_epoch == s_clipboard_epoch)
        (void)queue_push_locked(&s_to_usb, report);
    portEXIT_CRITICAL(&s_clipboard_lock);
}

bool wk_clipboard_feed(uint8_t byte)
{
    if (s_clipboard_line_start) {
        s_clipboard_line_start = false;
        s_clipboard_line_owned = byte == 'C';
        s_clipboard_line_size = 0;
        s_clipboard_overflow = false;
        if (s_clipboard_line_owned) {
            portENTER_CRITICAL(&s_clipboard_lock);
            s_clipboard_line_epoch = s_clipboard_epoch;
            portEXIT_CRITICAL(&s_clipboard_lock);
        }
    }
    const bool consumed = s_clipboard_line_owned;
    if (byte == '\n') {
        if (consumed && !s_clipboard_overflow) accept_clipboard_line();
        s_clipboard_line_start = true;
    } else if (consumed) {
        if (s_clipboard_line_size >= sizeof(s_clipboard_line) || byte < 32 || byte > 126)
            s_clipboard_overflow = true;
        else if (!s_clipboard_overflow) s_clipboard_line[s_clipboard_line_size++] = (char)byte;
    }
    return consumed;
}

bool wk_clipboard_usb_output(const uint8_t *report, size_t length)
{
    return report && length == WK_CLIPBOARD_REPORT_BYTES && queue_push(&s_to_uart, report);
}

bool wk_clipboard_next_usb(uint8_t report[WK_CLIPBOARD_REPORT_BYTES])
{
    return report && queue_pop(&s_to_usb, report);
}

size_t wk_clipboard_next_tx(char *line, size_t capacity)
{
    if (!line || capacity < WK_CLIPBOARD_FRAME_BYTES + 1U) return 0;
    uint8_t report[WK_CLIPBOARD_REPORT_BYTES];
    if (!queue_pop(&s_to_uart, report)) return 0;
    static const char digits[] = "0123456789abcdef";
    memcpy(line, "C1,", 3);
    for (size_t i = 0; i < sizeof(report); ++i) {
        line[3 + i * 2] = digits[report[i] >> 4];
        line[4 + i * 2] = digits[report[i] & 15];
    }
    line[131] = ',';
    uint32_t crc = clipboard_crc32(report, sizeof(report));
    for (unsigned i = 0; i < 8; ++i) line[132 + i] = digits[(crc >> (28U - i * 4U)) & 15];
    line[140] = '\n';
    line[141] = 0;
    return WK_CLIPBOARD_FRAME_BYTES;
}
