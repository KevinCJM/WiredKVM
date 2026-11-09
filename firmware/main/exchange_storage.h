#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* USB exchange storage is backed by the controller, never by S3 flash.
 * X1,P,<generation>,<blocks> publishes ordinary read/write exchange media;
 * X1,I,<generation>,<blocks> publishes temporary read-only setup media.
 * Both use the existing CRC/status/lease contract and X1,O for withdrawal.
 * All entry points are task-context only; no UART or disk I/O occurs here. */
void wk_exchange_init(void);
bool wk_exchange_feed(uint8_t byte);
void wk_exchange_poll(void);
size_t wk_exchange_next_tx(char *line, size_t capacity);
void wk_exchange_usb_ready(bool ready);
void wk_exchange_usb_attached(void);
#define WK_EXCHANGE_LINE_CAPACITY 1152
