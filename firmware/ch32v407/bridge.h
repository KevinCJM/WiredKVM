#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "wire_protocol.h"

/* One polling thread owns this core. No allocation, waits, disk or USB calls.
 * Port 0 = controlling computer, port 1 = controlled computer.
 * Bulk buffers NEVER share queue capacity with HID/control. */
#define WK407_BULK_SLOTS 32
#define WK407_BULK_PACKET 512
#define WK407_CONTROL_SLOTS 32
#define WK407_HID_SLOTS 64
typedef struct { uint16_t size; uint8_t bytes[512]; } wk407_bulk_packet;
typedef struct { uint16_t size; uint8_t bytes[144]; } wk407_control_packet;
typedef struct { uint8_t size, endpoint; uint8_t bytes[16]; } wk407_hid_packet;
typedef struct { unsigned head, count; wk407_bulk_packet item[WK407_BULK_SLOTS]; } wk407_bulk_queue;
typedef struct { unsigned head, count; wk407_control_packet item[WK407_CONTROL_SLOTS]; } wk407_control_queue;
typedef struct { uint8_t id[16]; uint64_t generation; bool used; } wk407_transaction;
typedef struct {
    bool (*local_report)(void *,unsigned,const uint8_t *,size_t);
    void *local_context;
    uint64_t stream_session[2], stream_generation[2];
    wk407_transaction transactions[2][4];
    uint8_t cell[2][512]; uint16_t cell_size[2];
    uint64_t cancelled_bytes[2];
    wk407_control_queue urgent[2];
    wk407_bulk_queue bulk[2]; /* indexed by destination */
    wk407_control_queue reply, clipboard[2];
    struct { unsigned head, count; wk407_hid_packet item[WK407_HID_SLOTS]; } hid;
    bool online[2], absolute, seen, release_pending;
    bool fn_down, fn_eligible; uint32_t fn_press, fn_began;
    uint8_t buttons, modifiers, keys[6];
    uint16_t x, y;
    wk_event_t previous;
    uint32_t last_input_ms, epoch, hid_epoch, bulk_high_water, hid_high_water;
    uint64_t forwarded[2];
    uint32_t rejected, watchdog_releases;
    char line[160]; unsigned line_size; bool discarding;
} wk407_bridge;

void wk407_init(wk407_bridge *b);
void wk407_connected(wk407_bridge *b, unsigned port, bool connected, uint32_t now);
void wk407_tick(wk407_bridge *b, uint32_t now);
/* Caller bounds a control USB OUT to 64 bytes and calls this on the main loop. */
void wk407_control(wk407_bridge *b, const uint8_t *bytes, size_t size, uint32_t now);
bool wk407_clipboard(wk407_bridge *b, unsigned source, const uint8_t *bytes, size_t size);
bool wk407_bulk_accept(wk407_bridge *b, unsigned source, const void *bytes, size_t size);
bool wk407_bulk_space(const wk407_bridge *b, unsigned source);
const wk407_bulk_packet *wk407_bulk_peek(const wk407_bridge *b, unsigned destination);
void wk407_bulk_done(wk407_bridge *b, unsigned destination);
const wk407_hid_packet *wk407_hid_peek(const wk407_bridge *b);
void wk407_hid_done(wk407_bridge *b);
const wk407_control_packet *wk407_reply_peek(const wk407_bridge *b);
void wk407_reply_done(wk407_bridge *b);
const wk407_control_packet *wk407_clipboard_peek(const wk407_bridge *b, unsigned destination);
void wk407_clipboard_done(wk407_bridge *b, unsigned destination);

const wk407_control_packet *wk407_urgent_peek(const wk407_bridge *b, unsigned destination);
void wk407_urgent_done(wk407_bridge *b, unsigned destination);
