// The production USB descriptors, callbacks, channel and UART main loop run
// against mocks; no device, input capture or physical USB interface is opened.
#define CONFIG_WIREDKVM_EXCHANGE_STORAGE 1
#define CONFIG_WIREDKVM_CLIPBOARD_CHANNEL 1
#define CONFIG_TINYUSB_SUSPEND_CALLBACK 1
#define WK_TEST_REAL_TINYUSB 1
#define portMUX_TYPE int
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(lock) ((void)(lock))
#define portEXIT_CRITICAL(lock) ((void)(lock))
#include "wk_firmware_fixture.c"
#include "../../firmware/main/exchange_storage.c"
#include "../../firmware/main/clipboard_channel.c"

const tusb_desc_device_t descriptor_dev_default = {.idVendor = 0x303a, .idProduct = 0x400c};
static uint8_t usb_report[64];
static unsigned usb_reports, usb_id, usb_instance, usb_length;
static bool usb_accept = true;
static size_t uart_free_space = 2048;
static unsigned inject_outputs;

// MSC is linked for real X1 demultiplexing, but these tests do not perform MSC
// I/O. Existing exchange tests exercise its deferred storage callbacks.
void usbd_defer_func(osal_task_func_t fn, void *arg, bool in_isr)
{ (void)fn; (void)arg; (void)in_isr; }
bool tud_msc_async_io_done(int32_t bytes, bool in_isr)
{ (void)bytes; (void)in_isr; return true; }
bool tud_msc_set_sense(uint8_t lun, uint8_t key, uint8_t asc, uint8_t ascq)
{ (void)lun; (void)key; (void)asc; (void)ascq; return true; }

bool tud_hid_n_report(uint8_t instance, uint8_t id, const void *report, uint16_t length)
{
    usb_instance = instance; usb_id = id; usb_length = length; ++usb_reports;
    if (length == sizeof(usb_report)) memcpy(usb_report, report, length);
    return usb_accept;
}
int uart_get_tx_buffer_free_size(int port, size_t *size)
{
    (void)port;
    *size = uart_free_space;
    // Insert USB callbacks during app_main, after its startup reset, to verify
    // low-priority UART scheduling with the production single UART owner.
    uint8_t report[64] = {0};
    for (unsigned i = 0; i < inject_outputs; ++i) {
        report[0] = (uint8_t)i;
        tud_hid_set_report_cb(2, 0, HID_REPORT_TYPE_OUTPUT, report, sizeof(report));
    }
    inject_outputs = 0;
    return ESP_OK;
}
void fc_reset(void)
{
    wk_fixture_reset(); wk_exchange_init(); wk_exchange_usb_attached(); wk_clipboard_init();
    usb_reports = usb_id = usb_instance = usb_length = 0;
    memset(usb_report, 0, sizeof(usb_report));
    usb_accept = true; uart_free_space = 2048; inject_outputs = 0;
}
void fc_feed(const uint8_t *bytes, unsigned size)
{
    for (unsigned i = 0; i < size; ++i)
        if (!wk_clipboard_feed(bytes[i]) && !wk_exchange_feed(bytes[i]))
            wk_fixture_feed(bytes + i, 1);
}
const char *fc_tx(unsigned capacity)
{
    static char line[WK_CLIPBOARD_LINE_CAPACITY];
    if (capacity > sizeof(line)) capacity = sizeof(line);
    size_t count = wk_clipboard_next_tx(line, capacity); line[count] = 0; return line;
}
const char *fc_exchange_tx(void)
{
    static char line[WK_EXCHANGE_LINE_CAPACITY];
    size_t count = wk_exchange_next_tx(line, sizeof(line)); line[count] = 0; return line;
}
bool fc_pop(uint8_t *report) { return wk_clipboard_next_usb(report); }
const uint8_t *fc_usb_report(void) { return usb_report; }
unsigned fc_usb_reports(void) { return usb_reports; }
unsigned fc_usb_instance(void) { return usb_instance; }
unsigned fc_usb_id(void) { return usb_id; }
unsigned fc_usb_length(void) { return usb_length; }
void fc_advance(unsigned ms) { clock_us += (int64_t)ms * 1000; }
void fc_accept(bool accept) { usb_accept = accept; }
unsigned fc_descriptor_length(void) { return sizeof(s_clipboard_report_desc); }
unsigned fc_pid(void) { wk_usb_init(); return s_exchange_device.idProduct; }
void fc_detach(void)
{
    tinyusb_event_t event = {.id = TINYUSB_EVENT_DETACHED};
    exchange_usb_event(&event, NULL);
}
void fc_attach(void)
{
    tinyusb_event_t event = {.id = TINYUSB_EVENT_ATTACHED};
    exchange_usb_event(&event, NULL);
}
void fc_suspend(void)
{
    tinyusb_event_t event = {.id = TINYUSB_EVENT_SUSPENDED};
    exchange_usb_event(&event, NULL);
}
void fc_schedule(unsigned outputs, unsigned free_space)
{ inject_outputs = outputs; uart_free_space = free_space; }
