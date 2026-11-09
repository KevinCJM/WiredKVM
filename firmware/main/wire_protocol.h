#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define WK_LINE_CAPACITY 96
#define WK_MAX_FRAME_BYTES 95

typedef enum {
    WK_EVENT_MOVE, WK_EVENT_BUTTONS, WK_EVENT_KEYBOARD,
    WK_EVENT_WHEEL, WK_EVENT_RELEASE, WK_EVENT_PING,
    WK_EVENT_MODIFIERS, WK_EVENT_KEY_TRANSITION,
    WK_EVENT_CLIENT_STATUS, WK_EVENT_ABSOLUTE_MOVE,
    WK_EVENT_ABSOLUTE_CAPABILITY
} wk_kind_t;

typedef struct {
    uint16_t seq;
    wk_kind_t kind;
    int16_t a;
    int16_t b;
} wk_event_t;

typedef enum {
    WK_ERR_NONE, WK_ERR_OVERFLOW, WK_ERR_FORMAT, WK_ERR_CHECKSUM, WK_ERR_RANGE
} wk_error_t;

typedef struct {
    char line[WK_LINE_CAPACITY];
    size_t length;
    bool discarding;
} wk_parser_t;

/* Incremental input: 1 = event, 0 = incomplete, -1 = rejected frame. */
void wk_parser_init(wk_parser_t *parser);
int wk_parser_feed(wk_parser_t *parser, uint8_t byte, wk_event_t *out, wk_error_t *error);
uint8_t wk_crc8(const uint8_t *data, size_t length);
const char *wk_error_name(wk_error_t error);
const char *wk_kind_name(wk_kind_t kind);
