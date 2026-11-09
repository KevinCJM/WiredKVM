// Stress the USB lifecycle task against the single UART owner. No hardware.
#define CONFIG_WIREDKVM_CLIPBOARD_CHANNEL 1
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
static _Atomic int64_t test_time;
static int64_t esp_timer_get_time(void) { return atomic_load(&test_time); }
#include "../firmware/main/fn_key.h"
static void *usb_task(void *unused) {
    (void)unused;
    for (unsigned i = 0; i < 100000; ++i) wk_fn_reset();
    return NULL;
}
int main(void) {
    pthread_t thread; assert(pthread_create(&thread, NULL, usb_task, NULL) == 0);
    const uint8_t keys[6] = {0}; uint8_t bytes[64];
    for (unsigned i = 0; i < 100000; ++i) {
        atomic_store(&test_time, (int64_t)i * 100000);
        wk_fn_keyboard(16, keys); wk_fn_globe(true, 16, keys);
        if (wk_fn_peek(bytes)) wk_fn_sent();
        atomic_fetch_add(&test_time, 80000);
        wk_fn_globe(false, 0, keys);
        if (wk_fn_peek(bytes)) wk_fn_sent();
        assert(s_fn.count <= 4);
    }
    assert(pthread_join(thread, NULL) == 0);
    puts("FN_EPOCH_THREAD_STRESS_PASS 100000 resets / 100000 key cycles");
}
