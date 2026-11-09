// Execute the production parser/event state machine and USB backend without a
// serial device, TinyUSB task, input capture, or a real keyboard/mouse event.
#include <stdarg.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>
#define CONFIG_WIREDKVM_USB_HID 1
#define CONFIG_WIREDKVM_BOARD_COM_UART0 1
#define CONFIG_WIREDKVM_INSTALLER_STORAGE 0
#include "../../firmware/main/main.c"
#define TAG WK_USB_TAG
#include "../../firmware/main/usb_hid.c"
#undef TAG

static char uart_output[8192];
static char report_output[8192];
static int64_t clock_us;
static bool mounted = true;
static bool suspended;
static bool ready = true;
static bool interface_ready[CFG_TUD_HID] = {true, true};
static int last_usb_instance = -1;
static int ready_after_delay;
static int delays;
static char fail_kind;
static int fail_remaining;
static bool use_usb_keyboard;
static wk_parser_t parser;
static const uint8_t *uart_input;
static size_t uart_input_remaining;
static bool pump_active;
static jmp_buf pump_done;

static bool report(char kind, unsigned buttons, int a, int b, int wheel, int pan)
{
    if (fail_kind == kind && fail_remaining > 0) {
        --fail_remaining;
        return false;
    }
    size_t used = strlen(report_output);
    snprintf(report_output + used, sizeof(report_output) - used,
             "%c,%u,%d,%d,%d,%d\n", kind, buttons, a, b, wheel, pan);
    return true;
}

int64_t esp_timer_get_time(void) { return clock_us; }
void vTaskDelay(unsigned ticks)
{
    // A zero-tick delay must not magically advance time in this test.
    clock_us += (int64_t)ticks * 10000;
    ++delays;
    if (ready_after_delay > 0 && delays >= ready_after_delay) ready = true;
}
int uart_write_bytes(int port, const void *data, size_t size)
{
    (void)port;
    size_t used = strlen(uart_output);
    if (size >= sizeof(uart_output) - used) return -1;
    memcpy(uart_output + used, data, size);
    uart_output[used + size] = 0;
    return (int)size;
}
int uart_read_bytes(int port, void *data, size_t size, unsigned ticks)
{
    (void)port;
    if (!pump_active) return 0;
    if (!uart_input_remaining) longjmp(pump_done, 1);
    size_t count = uart_input_remaining < size ? uart_input_remaining : size;
    memcpy(data, uart_input, count);
    uart_input += count;
    uart_input_remaining -= count;
    // Model uart_read_bytes waiting for the rest of a short read. This makes
    // the old 128-byte blocking read visibly cost one 100 Hz tick per frame.
    if (count < size) clock_us += (int64_t)ticks * 10000;
    return (int)count;
}
int uart_param_config(int port, const uart_config_t *cfg)
{ (void)port; (void)cfg; return 0; }
int uart_set_pin(int port, int tx, int rx, int rts, int cts)
{ (void)port; (void)tx; (void)rx; (void)rts; (void)cts; return 0; }
int uart_driver_install(int port, int rx, int tx, int queue, void *handle, int flags)
{ (void)port; (void)rx; (void)tx; (void)queue; (void)handle; (void)flags; return 0; }

bool hid_backend_init(void) { return true; }
bool hid_backend_client_connected(void) { return wk_usb_connected(); }
bool hid_backend_mouse(uint8_t buttons, int8_t x, int8_t y, int8_t wheel, int8_t pan)
{ return report('M', buttons, x, y, wheel, pan); }
bool hid_backend_absolute_mouse(uint8_t buttons, uint16_t x, uint16_t y, int8_t wheel, int8_t pan)
{ return report('A', buttons, x, y, wheel, pan); }
bool hid_backend_keyboard(uint8_t modifiers, const uint8_t keys[6])
{ return use_usb_keyboard ? wk_usb_keyboard(modifiers, keys) :
         report('K', modifiers, keys[0], keys[1], keys[2], keys[3]); }
bool hid_backend_repeat(uint8_t key) { (void)key; return true; }
void hid_backend_release_marker(void) {}
void hid_backend_cancel_fn_tap(void) { if (use_usb_keyboard) wk_usb_cancel_fn_tap(); }

esp_err_t tinyusb_driver_install(const tinyusb_config_t *cfg) { (void)cfg; return ESP_OK; }
bool tud_mounted(void) { return mounted; }
bool tud_suspended(void) { return suspended; }
#if !WK_TEST_REAL_TINYUSB
bool tud_ready(void) { return tud_mounted() && !tud_suspended(); }
#endif
bool tud_hid_n_ready(uint8_t instance)
{ return instance < CFG_TUD_HID && tud_ready() && ready && interface_ready[instance]; }
#if !WK_TEST_REAL_TINYUSB
bool tud_hid_ready(void) { return tud_hid_n_ready(0); }
bool tud_hid_mouse_report(uint8_t id, uint8_t buttons, int8_t x, int8_t y, int8_t wheel, int8_t pan)
{ last_usb_instance = 0; return id == WK_MOUSE_ID && report('m', buttons, x, y, wheel, pan); }
bool tud_hid_abs_mouse_report(uint8_t id, uint8_t buttons, int16_t x, int16_t y, int8_t wheel, int8_t pan)
{ return tud_hid_n_abs_mouse_report(0, id, buttons, x, y, wheel, pan); }
#else
bool tud_hid_n_mouse_report(uint8_t instance, uint8_t id, uint8_t buttons, int8_t x, int8_t y, int8_t wheel, int8_t pan)
{ last_usb_instance = instance; return instance == 0 && id == WK_MOUSE_ID && report('m', buttons, x, y, wheel, pan); }
bool tud_hid_n_keyboard_report(uint8_t instance, uint8_t id, uint8_t modifiers, const uint8_t keys[6])
{ last_usb_instance = instance; return instance == 0 && id == WK_KEYBOARD_ID && report('k', modifiers, keys[0], keys[1], keys[2], keys[3]); }
#endif
bool tud_hid_n_abs_mouse_report(uint8_t instance, uint8_t id, uint8_t buttons, int16_t x, int16_t y, int8_t wheel, int8_t pan)
{ last_usb_instance = instance; return instance == 1 && id == WK_ABSOLUTE_MOUSE_ID && report('a', buttons, x, y, wheel, pan); }
#if !WK_TEST_REAL_TINYUSB
bool tud_hid_keyboard_report(uint8_t id, uint8_t modifiers, const uint8_t keys[6])
{ last_usb_instance = 0; return id == WK_KEYBOARD_ID && report('k', modifiers, keys[0], keys[1], keys[2], keys[3]); }
#endif
#if !CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
bool tud_hid_n_report(uint8_t instance, uint8_t id, const void *data, uint16_t length)
{
    const uint8_t *bytes = data;
    last_usb_instance = instance;
    return instance == 0 && id == WK_GLOBE_ID && length == 2 &&
           report('g', bytes[0] | bytes[1] << 8, 0, 0, 0, 0);
}
#endif

void wk_fixture_reset(void)
{
    s_buttons = s_mods = 0;
    s_keyboard_maybe_held = s_globe_down = use_usb_keyboard = false;
    wk_fn_reset();
    memset(s_keys, 0, sizeof(s_keys));
    s_absolute_mouse = false;
    s_absolute_x = s_absolute_y = 0;
    s_seen_seq = false;
    s_last_seq = 0;
    s_last_kind = WK_EVENT_PING;
    s_last_a = s_last_b = 0;
    s_last_rx_ms = clock_us = 0;
    uart_output[0] = report_output[0] = 0;
    mounted = ready = true;
    for (unsigned i = 0; i < CFG_TUD_HID; ++i) interface_ready[i] = true;
    last_usb_instance = -1;
    suspended = false;
    ready_after_delay = delays = 0;
    fail_kind = 0;
    fail_remaining = 0;
    pump_active = false;
    wk_parser_init(&parser);
}
void wk_fixture_feed(const uint8_t *bytes, unsigned length)
{
    for (unsigned i = 0; i < length; ++i) {
        wk_event_t event;
        wk_error_t error;
        int result = wk_parser_feed(&parser, bytes[i], &event, &error);
        if (result == 1) apply_event(&event);
        else if (result < 0) {
            char message[64];
            int size = snprintf(message, sizeof(message), "ERR,%s\n", wk_error_name(error));
            uart_write_bytes(WK_UART, message, (size_t)size);
        }
    }
}
const char *wk_fixture_uart(void) { return uart_output; }
const char *wk_fixture_reports(void) { return report_output; }
void wk_fixture_clear_output(void) { uart_output[0] = report_output[0] = 0; }
void wk_fixture_fail(char kind, int count) { fail_kind = kind; fail_remaining = count; }
void wk_fixture_use_usb_keyboard(bool enabled) { use_usb_keyboard = enabled; }
void wk_fixture_usb(bool is_mounted, bool is_ready, int delay_count)
{ mounted = is_mounted; ready = is_ready; ready_after_delay = delay_count; delays = 0; }
void wk_fixture_suspend(bool is_suspended) { suspended = is_suspended; }
void wk_fixture_interface_ready(unsigned instance, bool is_ready)
{ if (instance < CFG_TUD_HID) interface_ready[instance] = is_ready; }
int wk_fixture_last_usb_instance(void) { return last_usb_instance; }
const uint8_t *wk_fixture_config_descriptor(void) { return s_config_desc; }
unsigned wk_fixture_config_descriptor_length(void) { return sizeof(s_config_desc); }
unsigned wk_fixture_report_descriptor_length(unsigned instance)
{
    if (instance == 0) return sizeof(s_report_desc);
    if (instance == 1) return sizeof(s_absolute_report_desc);
    return 0;
}
int wk_fixture_delays(void) { return delays; }
bool wk_fixture_watchdog_release(void) { return release_all(true); }
int64_t wk_fixture_pump(const uint8_t *bytes, unsigned length)
{
    uart_input = bytes;
    uart_input_remaining = length;
    pump_active = true;
    int64_t started = clock_us;
    if (setjmp(pump_done) == 0) app_main();
    pump_active = false;
    return clock_us - started;
}
