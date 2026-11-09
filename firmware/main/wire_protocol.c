#include "wire_protocol.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

uint8_t wk_crc8(const uint8_t *data, size_t length)
{
    uint8_t crc = 0;
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8; ++bit) {
            crc = (uint8_t)((crc & 0x80u) ? ((crc << 1u) ^ 0x07u) : (crc << 1u));
        }
    }
    return crc;
}

void wk_parser_init(wk_parser_t *parser)
{
    memset(parser, 0, sizeof(*parser));
}

const char *wk_error_name(wk_error_t e)
{
    switch (e) {
    case WK_ERR_OVERFLOW: return "overflow";
    case WK_ERR_FORMAT: return "format";
    case WK_ERR_CHECKSUM: return "checksum";
    case WK_ERR_RANGE: return "range";
    case WK_ERR_NONE: return "none";
    }
    return "unknown";
}

const char *wk_kind_name(wk_kind_t e)
{
    switch (e) {
    case WK_EVENT_MOVE: return "M";
    case WK_EVENT_BUTTONS: return "B";
    case WK_EVENT_KEYBOARD: return "K";
    case WK_EVENT_WHEEL: return "W";
    case WK_EVENT_RELEASE: return "R";
    case WK_EVENT_PING: return "P";
    case WK_EVENT_MODIFIERS: return "C";
    case WK_EVENT_KEY_TRANSITION: return "T";
    case WK_EVENT_CLIENT_STATUS: return "S";
    case WK_EVENT_ABSOLUTE_MOVE: return "A";
    case WK_EVENT_ABSOLUTE_CAPABILITY: return "Q";
    }
    return "?";
}

static bool decimal(const char *text, long minimum, long maximum, long *output)
{
    if (!text || !*text || isspace((unsigned char)*text)) return false;
    errno = 0;
    char *end = NULL;
    long v = strtol(text, &end, 10);
    if (errno || end == text || *end != '\0' || v < minimum || v > maximum)
        return false;
    *output = v;
    return true;
}

static int hex_nibble(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static wk_error_t parse_line(char *line, wk_event_t *event)
{
    char *last_comma = strrchr(line, ',');
    if (!last_comma || strlen(last_comma + 1) != 2) return WK_ERR_FORMAT;
    int high = hex_nibble(last_comma[1]);
    int low = hex_nibble(last_comma[2]);
    if (high < 0 || low < 0) return WK_ERR_FORMAT;
    uint8_t expected = (uint8_t)((high << 4) | low);
    if (wk_crc8((const uint8_t *)line, (size_t)(last_comma - line)) != expected)
        return WK_ERR_CHECKSUM;
    *last_comma = '\0';

    // WK1,seq,TYPE,a,b,CRC8; exactly five fields before the checksum.
    char *fields[5];
    char *cursor = line;
    for (int i = 0; i < 5; ++i) {
        fields[i] = cursor;
        if (!*cursor) return WK_ERR_FORMAT;
        char *comma = strchr(cursor, ',');
        if (i == 4) {
            if (comma) return WK_ERR_FORMAT;
        } else {
            if (!comma) return WK_ERR_FORMAT;
            *comma = '\0';
            cursor = comma + 1;
        }
    }
    if (strcmp(fields[0], "WK1") != 0) return WK_ERR_FORMAT;
    long seq, a, b;
    if (!decimal(fields[1], 0, 65535, &seq)) return WK_ERR_RANGE;
    if (!decimal(fields[3], INT16_MIN, INT16_MAX, &a) ||
        !decimal(fields[4], INT16_MIN, INT16_MAX, &b))
        return WK_ERR_RANGE;

    wk_kind_t kind;
    if (!strcmp(fields[2], "M")) {
        kind = WK_EVENT_MOVE;
        if (a < -127 || a > 127 || b < -127 || b > 127) return WK_ERR_RANGE;
    } else if (!strcmp(fields[2], "A")) {
        kind = WK_EVENT_ABSOLUTE_MOVE;
        if (a < 0 || b < 0) return WK_ERR_RANGE; // int16 parsing already caps at 32767.
    } else if (!strcmp(fields[2], "B")) {
        kind = WK_EVENT_BUTTONS;
        if (a < 0 || a > 31 || b) return WK_ERR_RANGE;
    } else if (!strcmp(fields[2], "K")) {
        kind = WK_EVENT_KEYBOARD;
        if (a < 0 || a > 31 || b < 0 || b > 255) return WK_ERR_RANGE;
    } else if (!strcmp(fields[2], "C")) {
        kind = WK_EVENT_MODIFIERS;
        if (a < 0 || a > 31 || b) return WK_ERR_RANGE;
    } else if (!strcmp(fields[2], "T")) {
        kind = WK_EVENT_KEY_TRANSITION;
        // a = USB keyboard usage; b = 0 up, 1 down, 2 autorepeat.
        // USB modifier usage 0xE0..0xE7 belongs to C, not T.
        if (a < 4 || a > 223 || b < 0 || b > 2) return WK_ERR_RANGE;
    } else if (!strcmp(fields[2], "W")) {
        kind = WK_EVENT_WHEEL;
        if (a < -127 || a > 127 || b < -127 || b > 127) return WK_ERR_RANGE;
    } else if (!strcmp(fields[2], "S")) {
        kind = WK_EVENT_CLIENT_STATUS;
        if (a || b) return WK_ERR_RANGE;
    } else if (!strcmp(fields[2], "Q")) {
        kind = WK_EVENT_ABSOLUTE_CAPABILITY;
        if (a || b) return WK_ERR_RANGE;
    } else if (!strcmp(fields[2], "R") || !strcmp(fields[2], "P")) {
        kind = fields[2][0] == 'R' ? WK_EVENT_RELEASE : WK_EVENT_PING;
        if (a || b) return WK_ERR_RANGE;
    } else {
        return WK_ERR_FORMAT;
    }

    *event = (wk_event_t){.seq = (uint16_t)seq, .kind = kind,
                          .a = (int16_t)a, .b = (int16_t)b};
    return WK_ERR_NONE;
}

int wk_parser_feed(wk_parser_t *parser, uint8_t byte, wk_event_t *out, wk_error_t *error)
{
    if (byte == '\r') return 0;
    if (byte != '\n') {
        if (parser->discarding) return 0;
        if (byte < 0x20 || byte > 0x7e || parser->length >= WK_MAX_FRAME_BYTES) {
            parser->discarding = true;
            return 0;
        }
        parser->line[parser->length++] = (char)byte;
        return 0;
    }
    if (parser->discarding) {
        wk_parser_init(parser);
        *error = WK_ERR_OVERFLOW;
        return -1;
    }
    if (parser->length == 0) return 0;
    parser->line[parser->length] = '\0';
    *error = parse_line(parser->line, out);
    wk_parser_init(parser);
    return *error == WK_ERR_NONE ? 1 : -1;
}
