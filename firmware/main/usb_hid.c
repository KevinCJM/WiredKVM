/*
 * Actual USB-OTG HID backend. Uses the supported esp_tinyusb 2.x component.
 * This file is built only in hardware mode; the emulator cannot enumerate USB.
 */
#include "hid_backend.h"
#include <stdatomic.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "fn_key.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "tinyusb.h"
#include "tinyusb_default_config.h"
#include "class/hid/hid_device.h"
#if CONFIG_WIREDKVM_EXCHANGE_STORAGE
#include "exchange_storage.h"
#include "class/msc/msc_device.h"
#endif
#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
#include "clipboard_channel.h"
#endif

#define WK_KEYBOARD_ID 1
#define WK_MOUSE_ID 2
#define WK_ABSOLUTE_MOUSE_ID 3
#define WK_GLOBE_ID 4
#define WK_GLOBE_USAGE 0x029d // Consumer AC Next Keyboard Layout Select (Apple Globe)
#define WK_RELATIVE_INTERFACE 0
#define WK_ABSOLUTE_INTERFACE 1
#if CONFIG_WIREDKVM_EXCHANGE_STORAGE
#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
#define WK_TOTAL_DESC_LEN (TUD_CONFIG_DESC_LEN + 3 * TUD_HID_DESC_LEN + TUD_MSC_DESC_LEN)
#define WK_INTERFACE_COUNT 4
_Static_assert(CFG_TUD_HID >= 3, "Clipboard channel requires three HID instances");
_Static_assert(CFG_TUD_HID_EP_BUFSIZE >= 64, "Clipboard reports require 64-byte HID buffers");
#else
#define WK_TOTAL_DESC_LEN (TUD_CONFIG_DESC_LEN + 2 * TUD_HID_DESC_LEN + TUD_MSC_DESC_LEN)
#define WK_INTERFACE_COUNT 3
#endif
extern const tusb_desc_device_t descriptor_dev_default;
static tusb_desc_device_t s_exchange_device;
#else
#define WK_TOTAL_DESC_LEN (TUD_CONFIG_DESC_LEN + 2 * TUD_HID_DESC_LEN)
#define WK_INTERFACE_COUNT 2
#endif

_Static_assert(CFG_TUD_HID >= 2, "WiredKVM requires two independent HID interfaces");

static const char *TAG = "WK_USB";
static _Atomic bool s_globe_down;

static const uint8_t s_report_desc[] = {
    TUD_HID_REPORT_DESC_KEYBOARD(HID_REPORT_ID(WK_KEYBOARD_ID)),
    TUD_HID_REPORT_DESC_MOUSE(HID_REPORT_ID(WK_MOUSE_ID)),
    TUD_HID_REPORT_DESC_CONSUMER(HID_REPORT_ID(WK_GLOBE_ID)),
};

// Apple HID parsers may assign a mixed interface's buttons to its relative
// pointer while absolute axes form a separate event. Keep them independent.
static const uint8_t s_absolute_report_desc[] = {
    TUD_HID_REPORT_DESC_ABSMOUSE(HID_REPORT_ID(WK_ABSOLUTE_MOUSE_ID)),
};

#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
static const uint8_t s_clipboard_report_desc[] = {
    0x06, 0x60, 0xff, // Usage Page (Vendor 0xff60)
    0x09, 0x61,       // Usage (0x61)
    0xa1, 0x01,       // Collection (Application)
    0x15, 0x00,       // Logical Minimum (0)
    0x26, 0xff, 0x00, // Logical Maximum (255)
    0x75, 0x08,       // Report Size (8 bits)
    0x95, 0x40,       // Report Count (64)
    0x09, 0x62, 0x81, 0x02, // Input (Data, Variable, Absolute)
    0x09, 0x63, 0x91, 0x02, // Output (Data, Variable, Absolute), SET_REPORT on EP0
    0xc0,             // End Collection; deliberately no Report ID item
};
#endif

static const char *s_usb_strings[] = {
    (const char[]){0x09, 0x04},
    "WiredKVM Prototype",
    "WiredKVM HID Keyboard and Mouse",
    "Prototype-DoNotShip", // Production must use a unique stable serial and licensed VID/PID.
    "WiredKVM HID",
    "WiredKVM Absolute Mouse",
#if CONFIG_WIREDKVM_EXCHANGE_STORAGE
    "WiredKVM Exchange Disk",
#endif
#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
    "WiredKVM Wired Clipboard",
#endif
};

static const uint8_t s_config_desc[] = {
    TUD_CONFIG_DESCRIPTOR(1, WK_INTERFACE_COUNT, 0, WK_TOTAL_DESC_LEN, 0, 100),
    TUD_HID_DESCRIPTOR(WK_RELATIVE_INTERFACE, 4, false, sizeof(s_report_desc), 0x81, 16, 1),
    TUD_HID_DESCRIPTOR(WK_ABSOLUTE_INTERFACE, 5, false, sizeof(s_absolute_report_desc), 0x82, 16, 1),
#if CONFIG_WIREDKVM_EXCHANGE_STORAGE
    TUD_MSC_DESCRIPTOR(2, 6, 0x03, 0x83, 64),
#endif
#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
    TUD_HID_DESCRIPTOR(3, 7, false, sizeof(s_clipboard_report_desc), 0x84, 64, 1),
#endif
};

#if CONFIG_WIREDKVM_EXCHANGE_STORAGE
static void exchange_usb_event(tinyusb_event_t *event, void *arg)
{
    (void)arg;
    if (event->id == TINYUSB_EVENT_ATTACHED) {
        s_globe_down = false; // A new USB configuration starts with no held keys.
        wk_fn_reset();
        wk_exchange_usb_attached();
#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
        // SetConfiguration can establish a new USB epoch without a preceding
        // detach event; do not carry queued reports into the new host session.
        wk_clipboard_clear();
#endif
    }
    else if (event->id == TINYUSB_EVENT_DETACHED) {
        s_globe_down = false;
        wk_fn_reset();
        wk_exchange_usb_ready(false);
#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
        wk_clipboard_clear();
#endif
    }
#ifdef CONFIG_TINYUSB_SUSPEND_CALLBACK
    else if (event->id == TINYUSB_EVENT_SUSPENDED) {
        wk_fn_reset();
        wk_exchange_usb_ready(false);
#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
        // Catch even suspend/resume cycles shorter than a UART loop iteration.
        wk_clipboard_clear();
#endif
    }
#endif
#ifdef CONFIG_TINYUSB_RESUME_CALLBACK
    else if (event->id == TINYUSB_EVENT_RESUMED) wk_exchange_usb_ready(true);
#endif
}
#endif

uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance)
{
    if (instance == WK_RELATIVE_INTERFACE) return s_report_desc;
    if (instance == WK_ABSOLUTE_INTERFACE) return s_absolute_report_desc;
#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
    if (instance == WK_CLIPBOARD_HID_INSTANCE) return s_clipboard_report_desc;
#endif
    return NULL;
}

uint16_t tud_hid_get_report_cb(uint8_t instance, uint8_t report_id,
                               hid_report_type_t report_type, uint8_t *buffer, uint16_t reqlen)
{
    (void)instance; (void)report_id; (void)report_type; (void)buffer; (void)reqlen;
    return 0;
}

void tud_hid_set_report_cb(uint8_t instance, uint8_t report_id,
                           hid_report_type_t report_type,
                           const uint8_t *buffer, uint16_t bufsize)
{
#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
    if (instance == WK_CLIPBOARD_HID_INSTANCE && report_id == 0 &&
        report_type == HID_REPORT_TYPE_OUTPUT && tud_ready())
        (void)wk_clipboard_usb_output(buffer, bufsize);
#else
    (void)instance; (void)report_id; (void)report_type; (void)buffer; (void)bufsize;
#endif
}

#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
void wk_usb_clipboard_poll(void)
{
    if (!tud_ready()) {
        wk_clipboard_clear();
        return;
    }
    if (!tud_hid_n_ready(WK_CLIPBOARD_HID_INSTANCE)) return;
    uint8_t report[WK_CLIPBOARD_REPORT_BYTES];
    if (wk_fn_peek(report)) {
        if (tud_hid_n_report(WK_CLIPBOARD_HID_INSTANCE, 0, report, sizeof(report))) wk_fn_sent();
        return;
    }
    if (wk_clipboard_next_usb(report))
        (void)tud_hid_n_report(WK_CLIPBOARD_HID_INSTANCE, 0, report, sizeof(report));
    // Failed/retired transfers are recovered by application ACK/retry. Never
    // wait here or hold a queue lock while calling the USB stack.
}
#endif

bool wk_usb_init(void)
{
    tinyusb_config_t cfg = TINYUSB_DEFAULT_CONFIG();
#if CONFIG_WIREDKVM_EXCHANGE_STORAGE
    s_exchange_device = descriptor_dev_default;
    // Separate the experimental composite identity from the proven HID profile.
    s_exchange_device.idProduct ^= 0x1000U;
#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
    s_exchange_device.idProduct ^= 0x2000U; // New composite identity avoids descriptor caches.
#endif
    cfg.descriptor.device = &s_exchange_device;
    cfg.event_cb = exchange_usb_event;
#endif
    cfg.descriptor.full_speed_config = s_config_desc;
    cfg.descriptor.string = s_usb_strings;
    cfg.descriptor.string_count = sizeof(s_usb_strings) / sizeof(s_usb_strings[0]);
#if TUD_OPT_HIGH_SPEED
    cfg.descriptor.high_speed_config = s_config_desc;
#endif
    esp_err_t err = tinyusb_driver_install(&cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "TinyUSB installation failed: %s", esp_err_to_name(err));
        return false;
    }
    ESP_LOGI(TAG, "USB HID stack started; awaiting USB host enumeration");
    return true;
}

bool wk_usb_connected(void)
{
    // COM can keep this board powered after native USB is unplugged. Without
    // VBUS sensing, TinyUSB may retain "mounted" and only report bus suspend
    // after SOF stops. Require a configured, non-suspended host (tud_ready).
    // Endpoint busy is separate: tud_hid_ready() may be false mid-report.
    return tud_ready();
}

static bool wait_ready(uint8_t instance)
{
    // pdMS_TO_TICKS(1) is zero at the board's 100 Hz tick rate. Use a real
    // tick and a wall-clock bound; unplugged clients never enter the wait.
    const int64_t deadline = esp_timer_get_time() + 20000;
    while (tud_ready()) {
        if (tud_hid_n_ready(instance)) return true;
        if (esp_timer_get_time() >= deadline) break;
        vTaskDelay(1);
    }
    return false;
}

bool wk_usb_mouse(uint8_t buttons, int8_t dx, int8_t dy, int8_t wheel, int8_t pan)
{
    if (buttons || wheel || pan) wk_fn_used();
    if (!wait_ready(WK_RELATIVE_INTERFACE)) return false;
    return tud_hid_mouse_report(WK_MOUSE_ID, buttons, dx, dy, wheel, pan);
}

bool wk_usb_keyboard(uint8_t modifiers, const uint8_t keys[6])
{
    wk_fn_keyboard(modifiers, keys);
    if (!tud_ready()) s_globe_down = false;
    if (!wait_ready(WK_RELATIVE_INTERFACE) ||
        !tud_hid_keyboard_report(WK_KEYBOARD_ID, modifiers & 0x0f, keys)) return false;
    // Keep the standard keyboard report unchanged. Fn/Globe is a separate
    // Consumer usage, not a keyboard modifier and not an Apple VID/PID clone.
    const bool globe_down = (modifiers & 0x10) != 0;
    if (globe_down != s_globe_down) {
        const uint16_t usage = globe_down ? WK_GLOBE_USAGE : 0;
        const uint8_t report[2] = {(uint8_t)usage, (uint8_t)(usage >> 8)};
        if (!wait_ready(WK_RELATIVE_INTERFACE) ||
            !tud_hid_n_report(WK_RELATIVE_INTERFACE, WK_GLOBE_ID, report, sizeof(report)))
            return false;
        s_globe_down = globe_down;
        wk_fn_globe(globe_down, modifiers, keys);
    }
    return true;
}

bool wk_usb_absolute_mouse(uint8_t buttons, uint16_t x, uint16_t y, int8_t wheel, int8_t pan)
{
    if (buttons || wheel || pan) wk_fn_used();
    if (x > 32767 || y > 32767 || !wait_ready(WK_ABSOLUTE_INTERFACE)) return false;
    return tud_hid_n_abs_mouse_report(WK_ABSOLUTE_INTERFACE, WK_ABSOLUTE_MOUSE_ID,
                                     buttons, (int16_t)x, (int16_t)y, wheel, pan);
}

void wk_usb_cancel_fn_tap(void) { wk_fn_cancel(); }
