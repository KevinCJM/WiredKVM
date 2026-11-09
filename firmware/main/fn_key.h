#pragma once
// Optional Fn metadata for the installed companion. Never delays keyboard HID.
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#if CONFIG_WIREDKVM_CLIPBOARD_CHANNEL
#include <stdatomic.h>
// USB lifecycle callbacks run on TinyUSB's task. Only request a new epoch
// there; the UART owner alone mutates queue/count/press state.
static _Atomic uint32_t s_fn_requested_epoch = 1;
static struct {
    uint32_t epoch, press;
    int64_t began;
    bool active, eligible;
    uint8_t queue[4][64];
    unsigned count;
} s_fn;

static inline void wk_fn_reset(void)
{ atomic_fetch_add_explicit(&s_fn_requested_epoch, 1, memory_order_relaxed); }
static inline void wk_fn_sync(void)
{
    uint32_t epoch = atomic_load_explicit(&s_fn_requested_epoch, memory_order_relaxed);
    if (!epoch) epoch = 1;
    if (s_fn.epoch == epoch) return;
    s_fn.epoch = epoch; s_fn.press = 0;
    s_fn.active = s_fn.eligible = false; s_fn.count = 0;
}

static inline uint32_t wk_fn_crc(const uint8_t *data, unsigned length)
{
    uint32_t crc = 0xffffffffU;
    for (unsigned i = 0; i < length; ++i) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ ((crc & 1U) ? 0xedb88320U : 0);
    }
    return ~crc;
}
static inline void wk_fn_put(uint8_t *out, uint64_t value, unsigned count)
{ for (unsigned i = 0; i < count; ++i) out[i] = (uint8_t)(value >> (i * 8)); }
static inline void wk_fn_queue(unsigned phase, int64_t now)
{
    if (s_fn.count == 4) { s_fn.count = 0; s_fn.eligible = false; }
    uint8_t *out = s_fn.queue[s_fn.count++];
    memset(out, 0, 64); memcpy(out, "WKFN", 4);
    out[4] = 1; out[5] = (uint8_t)phase; out[6] = s_fn.eligible;
    wk_fn_put(out + 8, s_fn.epoch, 4); wk_fn_put(out + 12, s_fn.press, 4);
    wk_fn_put(out + 16, (uint64_t)now, 8);
    wk_fn_put(out + 24, phase == 2 ? (uint64_t)(now - s_fn.began) / 1000 : 0, 4);
    wk_fn_put(out + 60, wk_fn_crc(out, 60), 4);
}
static inline void wk_fn_cancel(void)
{
    wk_fn_sync();
    s_fn.eligible = false; s_fn.active = false; s_fn.count = 0;
    if (s_fn.press) wk_fn_queue(3, esp_timer_get_time());
}
static inline void wk_fn_keyboard(uint8_t modifiers, const uint8_t keys[6])
{
    wk_fn_sync();
    if (modifiers & 0x0f) s_fn.eligible = false;
    for (unsigned i = 0; i < 6; ++i) if (keys[i]) s_fn.eligible = false;
}
static inline void wk_fn_used(void) { wk_fn_sync(); if (s_fn.active) s_fn.eligible = false; }
static inline void wk_fn_globe(bool down, uint8_t modifiers, const uint8_t keys[6])
{
    wk_fn_sync();
    const int64_t now = esp_timer_get_time();
    if (down) {
        ++s_fn.press; if (!s_fn.press) { wk_fn_reset(); wk_fn_sync(); ++s_fn.press; }
        s_fn.active = true; s_fn.eligible = true; s_fn.began = now;
        wk_fn_keyboard(modifiers, keys); wk_fn_queue(1, now);
    } else if (s_fn.active) {
        wk_fn_queue(2, now); s_fn.active = false;
    }
}
static inline bool wk_fn_peek(uint8_t out[64])
{
    wk_fn_sync();
    if (!s_fn.count) return false;
    uint64_t at = 0;
    for (unsigned i = 0; i < 8; ++i) at |= (uint64_t)s_fn.queue[0][16 + i] << (i * 8);
    if ((uint64_t)esp_timer_get_time() - at > 500000) { wk_fn_cancel(); }
    memcpy(out, s_fn.queue[0], 64); return true;
}
static inline void wk_fn_sent(void)
{ wk_fn_sync(); if (s_fn.count) { --s_fn.count; memmove(s_fn.queue, s_fn.queue + 1, s_fn.count * 64); } }
#else
static inline void wk_fn_reset(void) {}
static inline void wk_fn_cancel(void) {}
static inline void wk_fn_keyboard(uint8_t m, const uint8_t k[6]) { (void)m; (void)k; }
static inline void wk_fn_used(void) {}
static inline void wk_fn_globe(bool d, uint8_t m, const uint8_t k[6]) { (void)d; (void)m; (void)k; }
#endif
