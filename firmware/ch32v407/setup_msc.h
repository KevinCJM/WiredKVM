#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define WK_SETUP_FLASH_BYTES (4u*1024u*1024u)
#define WK_SETUP_IMAGE_OFFSET 4096u
typedef bool (*wk_setup_read_fn)(void *,uint32_t,void *,size_t);
typedef struct {
    bool online, announced, suppressed, ejected, lease, hide_requested, prevent, stall_in;
    uint32_t attached, last_lease, sequence, tag, residue, remaining, offset;
    uint8_t phase, status, sense, asc;
    uint8_t buffer[512]; uint16_t length;
} wk_setup_port;
typedef struct {
    wk_setup_read_fn read; void *context;
    bool valid, validating;
    uint32_t image_bytes, expected_crc, crc, checked;
    wk_setup_port ports[2];
} wk_setup;
void wk_setup_init(wk_setup *,wk_setup_read_fn,void *);
void wk_setup_tick(wk_setup *,uint32_t now);
void wk_setup_connected(wk_setup *,unsigned,bool,uint32_t now);
bool wk_setup_control(wk_setup *,unsigned,const uint8_t *,size_t,uint32_t now);
bool wk_setup_ready(wk_setup *,unsigned,uint32_t now);
bool wk_setup_msc_out(wk_setup *,unsigned,const uint8_t *,size_t,uint32_t now);
const uint8_t *wk_setup_msc_in(wk_setup *,unsigned,size_t *);
void wk_setup_msc_done(wk_setup *,unsigned);
void wk_setup_msc_reset(wk_setup *,unsigned);
bool wk_setup_msc_wants_out(const wk_setup *,unsigned);
bool wk_setup_msc_take_stall(wk_setup *,unsigned);
