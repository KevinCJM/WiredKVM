#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Opaque application packets. Sequence numbers, acknowledgements and retries
 * belong to the two endpoint applications, never to the HID input pipeline. */
#define WK_CLIPBOARD_REPORT_BYTES 64U
#define WK_CLIPBOARD_QUEUE_DEPTH 8U
#define WK_CLIPBOARD_FRAME_BYTES 141U
#define WK_CLIPBOARD_LINE_CAPACITY 512U
#define WK_CLIPBOARD_HID_INSTANCE 2U

void wk_clipboard_init(void);
void wk_clipboard_clear(void);
/* Main UART task only. Consumes C-prefixed lines, including malformed ones. */
bool wk_clipboard_feed(uint8_t byte);
/* Task-context callbacks; bounded copies only, no UART/USB I/O or waits. */
bool wk_clipboard_usb_output(const uint8_t *report, size_t length);
bool wk_clipboard_next_usb(uint8_t report[WK_CLIPBOARD_REPORT_BYTES]);
size_t wk_clipboard_next_tx(char *line, size_t capacity);
/* USB backend: attempt at most one interrupt input report, without waiting. */
void wk_usb_clipboard_poll(void);
