#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef int hid_report_type_t;
#define TUD_OPT_HIGH_SPEED 0
#define CFG_TUD_HID 2
#define TUD_CONFIG_DESC_LEN 9
#define TUD_HID_DESC_LEN 25
// Descriptor expansion is covered by the real ESP-IDF build. These minimal
// definitions let this fixture execute the production USB sending/wait code.
#define HID_REPORT_ID(id) id
#define TUD_HID_REPORT_DESC_KEYBOARD(id) id
#define TUD_HID_REPORT_DESC_MOUSE(id) id
#define TUD_HID_REPORT_DESC_CONSUMER(id) id
#define TUD_HID_REPORT_DESC_ABSMOUSE(id) id
#define WK_MOCK_U16(v) ((v) & 255), (((v) >> 8) & 255)
#define TUD_CONFIG_DESCRIPTOR(config, count, string, length, attr, power) \
    9, 2, WK_MOCK_U16(length), count, config, string, (0x80 | attr), ((power) / 2)
#define TUD_HID_DESCRIPTOR(interface, string, protocol, length, endpoint, size, interval) \
    9, 4, interface, 0, 1, 3, 0, protocol, string, \
    9, 0x21, 0x11, 0x01, 0, 1, 0x22, WK_MOCK_U16(length), \
    7, 5, endpoint, 3, WK_MOCK_U16(size), interval
bool tud_mounted(void);
bool tud_suspended(void);
bool tud_ready(void);
bool tud_hid_ready(void);
bool tud_hid_n_ready(uint8_t instance);
bool tud_hid_mouse_report(uint8_t id, uint8_t buttons, int8_t dx, int8_t dy, int8_t wheel, int8_t pan);
bool tud_hid_abs_mouse_report(uint8_t id, uint8_t buttons, int16_t x, int16_t y, int8_t wheel, int8_t pan);
bool tud_hid_n_abs_mouse_report(uint8_t instance, uint8_t id, uint8_t buttons, int16_t x, int16_t y, int8_t wheel, int8_t pan);
bool tud_hid_keyboard_report(uint8_t id, uint8_t modifiers, const uint8_t keys[6]);
bool tud_hid_n_report(uint8_t instance, uint8_t id, const void *report, uint16_t length);
